package tlbridge

import chisel3._
import chisel3.util._

/** TileLink-C to CHI Issue-E bridge (RN-F role).
  *
  *  Stage 6 implementation: read + release + snoop + uncached/atomic.
  *
  *  Four independent engines run in parallel:
  *    - acquire:  TL-A AcquireBlock / AcquirePerm to CHI Read / MakeUnique
  *    - release:  TL-C Release / ReleaseData to CHI Evict / WriteBack /
  *                WriteClean
  *    - snoop:    CHI Snp to TL-B Probe to TL-C ProbeAck / ProbeAckData
  *                then back as CHI SnpResp / SnpRespData
  *    - uncached: TL-A Get / Put / Hint / Arithmetic / Logical to CHI
  *                ReadOnce / WriteUnique* / CleanShared|CleanInvalid /
  *                AtomicLoad*|AtomicSwap, with the matching write-data
  *                (NonCopyBackWrData) and read-return (CompData) flows.
  *
  *  Shared CHI channels are arbitrated:
  *    txreq:  acquire > release > uncached    (snoop does not use REQ)
  *    txrsp:  acquire (CompAck) > snoop (SnpResp)
  *    txdat:  release (CopyBackWrData) > uncached (NonCopyBackWrData) >
  *            snoop (SnpRespData)
  *    rxrsp:  routed by txnID partition (Comp / CompDBIDResp / DBIDResp)
  *    rxdat:  routed by txnID to acquire (Grant data) or uncached
  *            (Get / Atomic read-return data)
  *  The TL side:
  *    A: acquire (Acquire*) or uncached (Get/Put/Hint/Atomic), by opcode
  *    B: snoop engine only
  *    C: routed by opcode (ProbeAck families to snoop, Release families
  *       to release)
  *    D: acquire (Grant/GrantData) > release (ReleaseAck) > uncached
  *       (AccessAck/AccessAckData/HintAck)
  *    E: acquire engine only
  *
  *  TxnID partitioning (bits [7:6]):
  *    acquire  txnID = {2'b00, source}
  *    release  txnID = {2'b10, source}
  *    uncached txnID = {2'b01, source}
  *    snoop    txnID = whatever the HN chose (RN-side echo only)
  *
  *  Stage 5/6 limits:
  *    - probe / release race is not collapsed in the bridge.  The TL
  *      master is expected to respond to a Probe even if it just issued
  *      a Release for the same line.  See doc/CHI_PLAN.md section 5.
  *    - SnpOnce treated as a normal toB probe.
  *    - no-change ProbeAck params (TtoT / BtoB / NtoN) reported as SC.
  *    - prefetch hints map to no-data CMOs (PrefetchRead→CleanShared,
  *      PrefetchWrite→CleanInvalid) and return HintAck.
  *    - TL atomics map to CHI AtomicLoad* / AtomicSwap (always return the
  *      pre-op value); AND maps to AtomicClr with the operand inverted.
  *    - atomics are single-beat (a.size ≤ beat); error/denied is only
  *      propagated for Get/Atomic read-return, not for Put/Hint.
  */
class TLCToCHI(val chip: CHIBridgeParams = CHIBridgeParams()) extends Module {
  val tlp: BridgeParams = BridgeParams(
    addrBits   = chip.addrBits,
    dataBits   = chip.dataBits,
    sourceBits = chip.sourceBits,
    idBits     = chip.sourceBits,
    sizeBits   = chip.sizeBits,
  )

  val io = IO(new Bundle {
    val tl  = new TLUCSlaveIO(tlp)
    val chi = new CHIMasterIO(chip)
  })

  // =====================================================================
  // ACQUIRE ENGINE — NtoB, NtoT, BtoT, AcquirePerm
  // =====================================================================
  val sAcqIdle :: sAcqREQ :: sAcqDAT :: sAcqRSP :: sAcqAck :: sAcqCompAck :: Nil = Enum(6)
  val acqState     = RegInit(sAcqIdle)
  val acqSource    = RegInit(0.U(chip.sourceBits.W))
  val acqSize      = RegInit(0.U(chip.sizeBits.W))
  val acqAddr      = RegInit(0.U(chip.addrBits.W))
  val acqBeats     = RegInit(0.U((chip.sizeBits + 1).W))
  val acqOp        = RegInit(0.U(chip.reqOpcodeBits.W))
  val acqNeedsData = RegInit(false.B)

  val isAcqBlock = io.tl.a.bits.opcode === TLOpcode.AcquireBlock
  val isAcqPerm  = io.tl.a.bits.opcode === TLOpcode.AcquirePerm
  val isNtoB     = io.tl.a.bits.param  === TLParam.NtoB
  val isNtoT     = io.tl.a.bits.param  === TLParam.NtoT

  val aBeats = Mux(io.tl.a.bits.size <= chip.beatBytesLg.U, 1.U,
                   1.U << (io.tl.a.bits.size - chip.beatBytesLg.U))

  // ---- Uncached / atomic engine A-decode (Get/Put/Hint/Atomic) -------
  val aIsGet     = io.tl.a.bits.opcode === TLOpcode.Get
  val aIsPutFull = io.tl.a.bits.opcode === TLOpcode.PutFullData
  val aIsPutPart = io.tl.a.bits.opcode === TLOpcode.PutPartialData
  val aIsPut     = aIsPutFull || aIsPutPart
  val aIsHint    = io.tl.a.bits.opcode === TLOpcode.Hint
  val aIsArith   = io.tl.a.bits.opcode === TLOpcode.ArithmeticData
  val aIsLogical = io.tl.a.bits.opcode === TLOpcode.LogicalData
  val aIsAtomic  = aIsArith || aIsLogical
  val aIsUncached = aIsGet || aIsPut || aIsHint || aIsAtomic

  // Uncached engine state (declared early so io.tl.a.ready can see it).
  // One slot handles Get/Put/Hint/Atomic; the FSM body lives below but
  // the registers and A-side acceptance sit next to the acquire A-side.
  val sUIdle :: sUACollect :: sUREQ :: sUWRsp :: sUWData :: sUResp :: sUDResp :: Nil = Enum(7)
  val uState  = RegInit(sUIdle)
  val uSource = RegInit(0.U(chip.sourceBits.W))
  val uSize   = RegInit(0.U(chip.sizeBits.W))
  val uAddr   = RegInit(0.U(chip.addrBits.W))
  val uOp     = RegInit(0.U(chip.reqOpcodeBits.W))
  val uWData  = RegInit(false.B)          // sends NonCopyBackWrData (Put, Atomic)
  val uRData  = RegInit(false.B)          // returns AccessAckData    (Get, Atomic)
  val uNBeats = RegInit(0.U((chip.sizeBits + 1).W))
  val uBeat   = RegInit(0.U((chip.sizeBits + 1).W))
  val uDBID   = RegInit(0.U(chip.dbIDBits.W))
  val uDataBuf = Reg(Vec(chip.beatsPerLine, UInt(chip.dataBits.W)))
  val uMaskBuf = Reg(Vec(chip.beatsPerLine, UInt(chip.strbBits.W)))
  // Narrow line-buffer index (uBeat is sized for counting, ≤ beatsPerLine).
  val uBeatIdx = uBeat(log2Ceil(chip.beatsPerLine) - 1, 0)

  // TxnID partition: acquire {00,src}, release {10,src}, uncached {01,src}.
  val uncTxnID = uSource.pad(chip.txnIDBits) | (1.U << (chip.txnIDBits - 2).U)

  // Derived response shape (combinational from latched {uWData,uRData}).
  //   Get   = !wdata, rdata   -> AccessAckData
  //   Put   =  wdata, !rdata  -> AccessAck
  //   Atomic=  wdata,  rdata  -> AccessAckData (returns the pre-op value)
  //   Hint  = !wdata, !rdata  -> HintAck
  val uIsHint = !uWData && !uRData
  val uDOp    = Mux(uRData, TLOpcode.AccessAckData,
                    Mux(uIsHint, TLOpcode.HintAck, TLOpcode.AccessAck))

  // CHI REQ opcode + per-op shape computed at accept time.  TileLink
  // atomics always return the pre-op value, so they map to CHI AtomicLoad
  // forms (and AtomicSwap).  AND has no direct CHI form: it maps to Clr
  // with the operand inverted on the wire (Clr computes old & ~txdata).
  val atArith = MuxLookup(io.tl.a.bits.param, CHIOpcode.AtomicLoadAdd)(Seq(
    0.U -> CHIOpcode.AtomicLoadSmin,   // MIN  (signed)
    1.U -> CHIOpcode.AtomicLoadSmax,   // MAX  (signed)
    2.U -> CHIOpcode.AtomicLoadUmin,   // MINU (unsigned)
    3.U -> CHIOpcode.AtomicLoadUmax,   // MAXU (unsigned)
    4.U -> CHIOpcode.AtomicLoadAdd,    // ADD
  ))
  val atLogical = MuxLookup(io.tl.a.bits.param, CHIOpcode.AtomicLoadSet)(Seq(
    0.U -> CHIOpcode.AtomicLoadEor,    // XOR
    1.U -> CHIOpcode.AtomicLoadSet,    // OR
    2.U -> CHIOpcode.AtomicLoadClr,    // AND (operand inverted on the wire)
    3.U -> CHIOpcode.AtomicSwap,       // SWAP
  ))
  val aAndInvert = aIsLogical && (io.tl.a.bits.param === 2.U)
  val aUncOp = MuxCase(CHIOpcode.ReadOnce, Seq(
    aIsGet     -> CHIOpcode.ReadOnce,
    aIsPutFull -> CHIOpcode.WriteUniqueFull,
    aIsPutPart -> CHIOpcode.WriteUniquePtl,
    // Prefetch hints map to no-data CMOs that return only Comp:
    //   PrefetchRead (0) -> CleanShared, PrefetchWrite (1) -> CleanInvalid.
    aIsHint    -> Mux(io.tl.a.bits.param === 0.U, CHIOpcode.CleanShared, CHIOpcode.CleanInvalid),
    aIsArith   -> atArith,
    aIsLogical -> atLogical,
  ))

  // ---- TL-A acceptance: acquire (idle) OR uncached (idle / collect) --
  val acqAcceptA = (acqState === sAcqIdle) && (isAcqBlock || isAcqPerm)
  val uAcceptA   = (uState === sUIdle) && aIsUncached
  io.tl.a.ready := acqAcceptA || uAcceptA || (uState === sUACollect)

  // Acquire engine A-side (guarded on the Acquire opcodes — TL-A is now
  // shared with the uncached engine).
  when(io.tl.a.fire && (isAcqBlock || isAcqPerm)) {
    acqSource := io.tl.a.bits.source
    acqSize   := io.tl.a.bits.size
    acqAddr   := io.tl.a.bits.address
    acqBeats  := aBeats
    acqState  := sAcqREQ
    when(isAcqPerm) {
      acqOp := CHIOpcode.MakeUnique
      acqNeedsData := false.B
    }.elsewhen(isNtoB) {
      acqOp := CHIOpcode.ReadShared
      acqNeedsData := true.B
    }.elsewhen(isNtoT) {
      acqOp := CHIOpcode.ReadUnique
      acqNeedsData := true.B
    }.otherwise {
      // AcquireBlock(BtoT) — permission upgrade, no data
      acqOp := CHIOpcode.MakeUnique
      acqNeedsData := false.B
    }
  }

  // Uncached engine A-side: accept beat 0 in sUIdle, collect Put's rest.
  when(io.tl.a.fire && uAcceptA) {
    uSource := io.tl.a.bits.source
    uSize   := io.tl.a.bits.size
    uAddr   := io.tl.a.bits.address
    uOp     := aUncOp
    uWData  := aIsPut || aIsAtomic
    uRData  := aIsGet || aIsAtomic
    uNBeats := aBeats
    // Buffer beat 0 (operand / write data); invert for AND->Clr.
    uDataBuf(0) := Mux(aAndInvert, ~io.tl.a.bits.data, io.tl.a.bits.data)
    uMaskBuf(0) := io.tl.a.bits.mask
    uBeat   := 1.U
    when((aIsPut || aIsAtomic) && (aBeats > 1.U)) {
      uState := sUACollect
    }.otherwise {
      uState := sUREQ
      uBeat  := 0.U      // reset for the upcoming data / response phase
    }
  }
  // Collect remaining Put write-data beats into the line buffer.
  when(io.tl.a.fire && (uState === sUACollect)) {
    uDataBuf(uBeatIdx) := io.tl.a.bits.data
    uMaskBuf(uBeatIdx) := io.tl.a.bits.mask
    uBeat := uBeat + 1.U
    when(uBeat === (uNBeats - 1.U)) {
      uState := sUREQ
      uBeat  := 0.U
    }
  }

  val acqTxnID = acqSource.pad(chip.txnIDBits)

  // =====================================================================
  // RELEASE ENGINE — Evict / WriteBackFull / WriteCleanFull
  // =====================================================================
  val sRelIdle :: sRelREQ :: sRelRsp :: sRelDAT :: sRelAck :: Nil = Enum(5)
  val relState   = RegInit(sRelIdle)
  val relSource  = RegInit(0.U(chip.sourceBits.W))
  val relSize    = RegInit(0.U(chip.sizeBits.W))
  val relAddr    = RegInit(0.U(chip.addrBits.W))
  val relBeats   = RegInit(0.U((chip.sizeBits + 1).W))
  val relOp      = RegInit(0.U(chip.reqOpcodeBits.W))
  val relHasData = RegInit(false.B)
  val relDBID    = RegInit(0.U(chip.dbIDBits.W))

  val cIsProbeAck     = io.tl.c.bits.opcode === TLOpcode.ProbeAck
  val cIsProbeAckData = io.tl.c.bits.opcode === TLOpcode.ProbeAckData
  val cIsProbeResp    = cIsProbeAck || cIsProbeAckData
  val cIsRelease      = io.tl.c.bits.opcode === TLOpcode.Release
  val cIsReleaseData  = io.tl.c.bits.opcode === TLOpcode.ReleaseData
  val cIsReleaseAny   = cIsRelease || cIsReleaseData
  val cIsTtoB         = io.tl.c.bits.param === TLParam.TtoB
  val cIsTtoN         = io.tl.c.bits.param === TLParam.TtoN
  val cIsBtoN         = io.tl.c.bits.param === TLParam.BtoN

  val cBeats = Mux(io.tl.c.bits.size <= chip.beatBytesLg.U, 1.U,
                   1.U << (io.tl.c.bits.size - chip.beatBytesLg.U))

  // Latch the snapshot off C-bits while c.valid is high in idle and the
  // opcode is a Release variant.  Release (no data) is acknowledged in
  // the same cycle by the c.ready term below; ReleaseData beat 0 stays
  // asserted until sRelDAT.
  when(io.tl.c.valid && (relState === sRelIdle) && cIsReleaseAny) {
    relSource := io.tl.c.bits.source
    relSize   := io.tl.c.bits.size
    relAddr   := io.tl.c.bits.address
    relBeats  := cBeats
    relHasData := cIsReleaseData
    when(cIsReleaseData) {
      relOp := Mux(cIsTtoB, CHIOpcode.WriteCleanFull, CHIOpcode.WriteBackFull)
    }.otherwise {
      relOp := CHIOpcode.Evict
    }
    relState := sRelREQ
  }

  val relTxnID = relSource.pad(chip.txnIDBits) | (1.U << (chip.txnIDBits - 1).U)

  // =====================================================================
  // SNOOP ENGINE — CHI Snp* → TL-B Probe → TL-C ProbeAck/ProbeAckData
  //                                     → CHI SnpResp / SnpRespData
  // =====================================================================
  val sSnpIdle :: sSnpProbe :: sSnpWaitC :: sSnpDataFwd :: sSnpRsp :: Nil = Enum(5)
  val snpState  = RegInit(sSnpIdle)
  val snpOp     = RegInit(0.U(chip.snpOpcodeBits.W))
  val snpAddr   = RegInit(0.U(chip.addrBits.W))        // full address (line + 3'b000)
  val snpSrcID  = RegInit(0.U(chip.nodeIDBits.W))      // HN node — we send back via tgtID
  val snpTxnID  = RegInit(0.U(chip.txnIDBits.W))
  val snpRespCode = RegInit(0.U(chip.respBits.W))      // CHI resp[2:0] including passDirty
  val snpHasData  = RegInit(false.B)                   // true if ProbeAckData → SnpRespData
  val snpBeats  = RegInit(0.U((chip.sizeBits + 1).W))  // beats remaining in SnpRespData

  // Opcode classification — toN-flavored snoops require full invalidation.
  val isSnpInvalidate = (io.chi.rxsnp.bits.opcode === CHIOpcode.SnpUnique) ||
                       (io.chi.rxsnp.bits.opcode === CHIOpcode.SnpCleanInvalid) ||
                       (io.chi.rxsnp.bits.opcode === CHIOpcode.SnpMakeInvalid)

  // rxsnp acceptance — only in idle, only after the current snoop completes.
  io.chi.rxsnp.ready := (snpState === sSnpIdle)
  when(io.chi.rxsnp.fire) {
    snpOp    := io.chi.rxsnp.bits.opcode
    snpAddr  := Cat(io.chi.rxsnp.bits.addr, 0.U(3.W))
    snpSrcID := io.chi.rxsnp.bits.srcID
    snpTxnID := io.chi.rxsnp.bits.txnID
    snpState := sSnpProbe
  }

  // -- TL-B Probe issue ------------------------------------------------
  val probeIsInvalidate = (snpOp === CHIOpcode.SnpUnique) ||
                          (snpOp === CHIOpcode.SnpCleanInvalid) ||
                          (snpOp === CHIOpcode.SnpMakeInvalid)

  io.tl.b.valid := (snpState === sSnpProbe)
  io.tl.b.bits  := 0.U.asTypeOf(new TLBChannel(tlp))
  io.tl.b.bits.opcode  := TLOpcode.Probe
  io.tl.b.bits.param   := Mux(probeIsInvalidate, TLParam.toN, TLParam.toB)
  io.tl.b.bits.size    := log2Ceil(chip.lineBytes).U
  io.tl.b.bits.source  := 0.U  // single TL master assumed; multi-master is out of scope
  io.tl.b.bits.address := snpAddr
  io.tl.b.bits.mask    := Fill(chip.strbBits, 1.U(1.W))

  when(io.tl.b.fire) {
    snpState := sSnpWaitC
  }

  // -- TL-C ProbeAck / ProbeAckData intake -----------------------------
  // C beats are routed by opcode:
  //   ProbeAck      → snoop engine, single beat, fired in sSnpWaitC
  //                   (snapshot + handshake same cycle).
  //   ProbeAckData  → snoop engine, multi-beat.  Beat 0 is *peeked* at
  //                   in sSnpWaitC (snapshot only, no fire), then beat 0
  //                   plus the remaining beats fire in sSnpDataFwd
  //                   together with the txdat handshake.
  //   Release       → release engine, single beat, fired in sRelIdle.
  //   ReleaseData   → release engine, multi-beat, fired in sRelDAT.
  val relAcceptCIdle  = (relState === sRelIdle) && cIsRelease
  val relAcceptCData  = (relState === sRelDAT)  && cIsReleaseData

  // Compute snoop response code from the param the master returns.
  //   ProbeAck:
  //     TtoB/TtoT/BtoB -> SC (clean retained)
  //     *N             -> I  (line invalidated)
  //   ProbeAckData:
  //     TtoB -> SC + PassDirty (0x5)
  //     TtoN -> I  + PassDirty (0x4)
  val cParamForResp = io.tl.c.bits.param
  val respIfAck = MuxLookup(cParamForResp, CHIResp.SC)(Seq(
    TLParam.TtoB -> CHIResp.SC,
    TLParam.TtoN -> CHIResp.I,
    TLParam.BtoN -> CHIResp.I,
    TLParam.TtoT -> CHIResp.SC,
    TLParam.BtoB -> CHIResp.SC,
    TLParam.NtoN -> CHIResp.I,
  ))
  val respIfAckData = Mux(cIsTtoB, "h5".U(3.W), "h4".U(3.W))

  // Peek at C while in sSnpWaitC: snapshot {resp, beats} and transition.
  // For ProbeAck this co-occurs with c.fire (snpC_AckFire below).  For
  // ProbeAckData the peek is fire-less; beat 0 stays on the wire until
  // sSnpDataFwd consumes it.
  val snpPeekC = (snpState === sSnpWaitC) && io.tl.c.valid && cIsProbeResp
  when(snpPeekC) {
    snpRespCode := Mux(cIsProbeAckData, respIfAckData, respIfAck)
    when(cIsProbeAckData) {
      snpHasData := true.B
      snpBeats   := cBeats
      snpState   := sSnpDataFwd
    }.otherwise {
      snpHasData := false.B
      snpState   := sSnpRsp
    }
  }

  // =====================================================================
  // CHI txreq — arbitrated, priority acquire > release > uncached
  // =====================================================================
  val acqWantsREQ = (acqState === sAcqREQ)
  val relWantsREQ = (relState === sRelREQ)
  val uWantsREQ   = (uState   === sUREQ)

  io.chi.txreq.valid := acqWantsREQ || relWantsREQ || uWantsREQ
  io.chi.txreq.bits  := 0.U.asTypeOf(new CHIReq(chip))
  when(acqWantsREQ) {
    io.chi.txreq.bits.opcode     := acqOp
    io.chi.txreq.bits.addr       := acqAddr
    io.chi.txreq.bits.txnID      := acqTxnID
    io.chi.txreq.bits.size       := acqSize(2,0)
    io.chi.txreq.bits.expCompAck := true.B
    io.chi.txreq.bits.snpAttr    := true.B
  }.elsewhen(relWantsREQ) {
    io.chi.txreq.bits.opcode     := relOp
    io.chi.txreq.bits.addr       := relAddr
    io.chi.txreq.bits.txnID      := relTxnID
    io.chi.txreq.bits.size       := relSize(2,0)
    io.chi.txreq.bits.expCompAck := false.B
    io.chi.txreq.bits.snpAttr    := true.B
  }.otherwise {
    io.chi.txreq.bits.opcode     := uOp
    io.chi.txreq.bits.addr       := uAddr
    io.chi.txreq.bits.txnID      := uncTxnID
    io.chi.txreq.bits.size       := uSize(2,0)
    io.chi.txreq.bits.expCompAck := false.B
    io.chi.txreq.bits.snpAttr    := false.B   // uncached / atomic = non-snoop
  }

  when(io.chi.txreq.fire) {
    when(acqWantsREQ) {
      acqState := Mux(acqNeedsData, sAcqDAT, sAcqRSP)
    }.elsewhen(relWantsREQ) {
      relState := sRelRsp
    }.otherwise {
      // Put / Atomic need a DBID before sending write data; Get / Hint
      // wait directly on the response (CompData / Comp).
      uState := Mux(uWData, sUWRsp, sUResp)
    }
  }

  // =====================================================================
  // CHI rxdat → TL D — routed by txnID to acquire (Grant data) or
  // uncached (Get / Atomic read-return data).
  // =====================================================================
  val datForAcq = io.chi.rxdat.valid && (io.chi.rxdat.bits.txnID === acqTxnID)
  val datForUnc = io.chi.rxdat.valid && (io.chi.rxdat.bits.txnID === uncTxnID)
  val datMatch  = datForAcq
  io.chi.rxdat.ready := (datForAcq && (acqState === sAcqDAT) && io.tl.d.ready) ||
                        (datForUnc && (uState === sUResp) && uRData && io.tl.d.ready)

  // =====================================================================
  // CHI rxrsp — routed by txnID partition (bits[7:6]: 00 acq, 10 rel,
  // 01 uncached).  The three txnIDs are disjoint so a full-width compare
  // is unambiguous.
  // =====================================================================
  val rxrspForAcq = io.chi.rxrsp.valid && (io.chi.rxrsp.bits.txnID === acqTxnID)
  val rxrspForRel = io.chi.rxrsp.valid && (io.chi.rxrsp.bits.txnID === relTxnID)
  val rxrspForUnc = io.chi.rxrsp.valid && (io.chi.rxrsp.bits.txnID === uncTxnID)

  val acqWantsRsp = (acqState === sAcqRSP) && rxrspForAcq
  val relWantsRsp = (relState === sRelRsp) && rxrspForRel
  // Uncached consumes rxrsp for the DBID (Put/Atomic, sUWRsp) and for the
  // Hint completion Comp (sUResp with no read data).
  val uWantsRsp   = (((uState === sUWRsp)) ||
                     ((uState === sUResp) && uIsHint)) && rxrspForUnc
  io.chi.rxrsp.ready := (acqWantsRsp && io.tl.d.ready) || relWantsRsp || uWantsRsp

  val respToT = Mux(acqState === sAcqDAT,
                    io.chi.rxdat.bits.resp === CHIResp.UC || io.chi.rxdat.bits.resp === CHIResp.UD,
                    io.chi.rxrsp.bits.resp === CHIResp.UC || io.chi.rxrsp.bits.resp === CHIResp.UD)

  // =====================================================================
  // TL D-channel — priority acquire (Grant/GrantData) > release
  // (ReleaseAck) > uncached (AccessAck/AccessAckData/HintAck)
  // =====================================================================
  val acqWantsD = ((acqState === sAcqDAT) && datMatch) ||
                  ((acqState === sAcqRSP) && rxrspForAcq)
  val relWantsD = (relState === sRelAck)
  val uWantsD   = ((uState === sUResp) && uRData && datForUnc) ||
                  (uState === sUDResp)

  val dSelAcq = acqWantsD
  val dSelRel = relWantsD && !acqWantsD
  val dSelUnc = uWantsD   && !acqWantsD && !relWantsD

  io.tl.d.valid := acqWantsD || relWantsD || uWantsD
  io.tl.d.bits  := 0.U.asTypeOf(new TLDChannel(tlp))
  io.tl.d.bits.opcode := MuxCase(TLOpcode.ReleaseAck, Seq(
    dSelAcq -> Mux(acqNeedsData, TLOpcode.GrantData, TLOpcode.Grant),
    dSelRel -> TLOpcode.ReleaseAck,
    dSelUnc -> uDOp,
  ))
  io.tl.d.bits.source := MuxCase(relSource, Seq(
    dSelAcq -> acqSource, dSelRel -> relSource, dSelUnc -> uSource))
  io.tl.d.bits.size   := MuxCase(relSize, Seq(
    dSelAcq -> acqSize, dSelRel -> relSize, dSelUnc -> uSize))
  io.tl.d.bits.param  := Mux(dSelAcq, Mux(respToT, TLParam.toT, TLParam.toB), 0.U)
  io.tl.d.bits.data   := io.chi.rxdat.bits.data
  io.tl.d.bits.denied := MuxCase(false.B, Seq(
    dSelAcq -> Mux(acqState === sAcqDAT, io.chi.rxdat.bits.respErr(1),
                                         io.chi.rxrsp.bits.respErr(1)),
    dSelUnc -> Mux(uState === sUResp, io.chi.rxdat.bits.respErr(1), false.B),
  ))
  io.tl.d.bits.corrupt := MuxCase(false.B, Seq(
    dSelAcq -> ((acqState === sAcqDAT) && io.chi.rxdat.bits.respErr(1)),
    dSelUnc -> ((uState === sUResp)    && io.chi.rxdat.bits.respErr(1)),
  ))

  when(io.tl.d.fire) {
    when(dSelAcq) {
      when(acqState === sAcqDAT) {
        acqBeats := acqBeats - 1.U
        when(acqBeats === 1.U) { acqState := sAcqAck }
      }.otherwise {
        acqState := sAcqAck
      }
    }.elsewhen(dSelRel) {
      relState := sRelIdle
    }.elsewhen(dSelUnc) {
      when(uState === sUResp) {     // AccessAckData beat (Get / Atomic)
        uBeat := uBeat + 1.U
        when(uBeat === (uNBeats - 1.U)) { uState := sUIdle }
      }.otherwise {                 // sUDResp: AccessAck / HintAck
        uState := sUIdle
      }
    }
  }

  // ---- rxrsp fire effects for release engine ----
  when(io.chi.rxrsp.fire && relWantsRsp) {
    relDBID := io.chi.rxrsp.bits.dbID
    when(relHasData) {
      relState := sRelDAT
    }.otherwise {
      relState := sRelAck
    }
  }

  // ---- rxrsp fire effects for uncached engine ----
  //   sUWRsp: DBIDResp (atomic) or CompDBIDResp (put) — latch dbID, then
  //           stream NonCopyBackWrData.
  //   sUResp + Hint: Comp — advance to the HintAck response.
  when(io.chi.rxrsp.fire && rxrspForUnc) {
    when(uState === sUWRsp) {
      uDBID  := io.chi.rxrsp.bits.dbID
      uState := sUWData
    }.elsewhen(uState === sUResp) {
      uState := sUDResp
    }
  }

  // =====================================================================
  // TL E (GrantAck) — acquire engine
  // =====================================================================
  io.tl.e.ready := (acqState === sAcqAck)
  when(io.tl.e.fire) {
    acqState := sAcqCompAck
  }

  // =====================================================================
  // CHI txrsp — acquire (CompAck) > snoop (SnpResp).
  // =====================================================================
  val acqWantsTXRSP = (acqState === sAcqCompAck)
  val snpWantsTXRSP = (snpState === sSnpRsp)

  io.chi.txrsp.valid := acqWantsTXRSP || snpWantsTXRSP
  io.chi.txrsp.bits  := 0.U.asTypeOf(new CHIRsp(chip))
  when(acqWantsTXRSP) {
    io.chi.txrsp.bits.opcode := CHIOpcode.CompAck
    io.chi.txrsp.bits.txnID  := acqTxnID
  }.otherwise {
    io.chi.txrsp.bits.opcode := CHIOpcode.SnpResp
    io.chi.txrsp.bits.txnID  := snpTxnID
    io.chi.txrsp.bits.tgtID  := snpSrcID
    io.chi.txrsp.bits.resp   := snpRespCode
  }

  when(io.chi.txrsp.fire) {
    when(acqWantsTXRSP) {
      acqState := sAcqIdle
    }.elsewhen(snpWantsTXRSP) {
      snpState := sSnpIdle
    }
  }

  // =====================================================================
  // CHI txdat — priority release (CopyBackWrData) > uncached
  // (NonCopyBackWrData) > snoop (SnpRespData)
  // =====================================================================
  val relWantsTXDAT = (relState === sRelDAT) && io.tl.c.valid && cIsReleaseData
  val uWantsTXDAT   = (uState === sUWData)   // streams from the line buffer
  val snpWantsTXDAT = (snpState === sSnpDataFwd) && io.tl.c.valid && cIsProbeAckData

  // dataID counts up from 0 across the beats of a single transaction.
  // We use (totalBeats - remaining) so beat 0 → 0, beat 1 → 1, ...
  val relDataID = (chip.beatsPerLine.U - relBeats)(chip.dataIDBits - 1, 0)
  val snpDataID = (chip.beatsPerLine.U - snpBeats)(chip.dataIDBits - 1, 0)
  val uDataID   = uBeat(chip.dataIDBits - 1, 0)

  io.chi.txdat.valid := relWantsTXDAT || uWantsTXDAT || snpWantsTXDAT
  io.chi.txdat.bits  := 0.U.asTypeOf(new CHIDat(chip))
  when(relWantsTXDAT) {
    io.chi.txdat.bits.opcode := CHIOpcode.CopyBackWrData
    io.chi.txdat.bits.txnID  := relDBID
    io.chi.txdat.bits.data   := io.tl.c.bits.data
    io.chi.txdat.bits.be     := Fill(chip.strbBits, 1.U(1.W))
    io.chi.txdat.bits.resp   := Mux(relOp === CHIOpcode.WriteCleanFull, CHIResp.SC, CHIResp.I)
    io.chi.txdat.bits.dataID := relDataID
  }.elsewhen(uWantsTXDAT) {
    io.chi.txdat.bits.opcode := CHIOpcode.NonCopyBackWrData
    io.chi.txdat.bits.txnID  := uDBID
    io.chi.txdat.bits.data   := uDataBuf(uBeatIdx)
    io.chi.txdat.bits.be     := uMaskBuf(uBeatIdx)
    io.chi.txdat.bits.resp   := CHIResp.I
    io.chi.txdat.bits.dataID := uDataID
  }.otherwise {
    io.chi.txdat.bits.opcode  := CHIOpcode.SnpRespData
    io.chi.txdat.bits.txnID   := snpTxnID
    io.chi.txdat.bits.tgtID   := snpSrcID
    io.chi.txdat.bits.homeNID := snpSrcID
    io.chi.txdat.bits.data    := io.tl.c.bits.data
    io.chi.txdat.bits.be      := Fill(chip.strbBits, 1.U(1.W))
    io.chi.txdat.bits.resp    := snpRespCode
    io.chi.txdat.bits.dataID  := snpDataID
  }

  // Uncached NonCopyBackWrData advances on txdat.fire (release has
  // priority on the shared channel, so only count our own beats).
  when(io.chi.txdat.fire && uWantsTXDAT && !relWantsTXDAT) {
    uBeat := uBeat + 1.U
    when(uBeat === (uNBeats - 1.U)) {
      uBeat  := 0.U
      uState := Mux(uRData, sUResp, sUDResp)  // Atomic→CompData; Put→AccessAck
    }
  }

  // =====================================================================
  // TL C-channel — multi-way ready term, opcode-disambiguated
  // =====================================================================
  val snpC_AckFire = (snpState === sSnpWaitC) && cIsProbeAck         // single-beat
  val snpC_DataFwd = (snpState === sSnpDataFwd) && cIsProbeAckData &&
                     io.chi.txdat.ready && !relWantsTXDAT && !uWantsTXDAT

  io.tl.c.ready := relAcceptCIdle ||
                   (relAcceptCData && io.chi.txdat.ready) ||
                   snpC_AckFire ||
                   snpC_DataFwd

  // Effects of TL-C fire — disambiguated by current state + opcode.
  when(io.tl.c.fire && relState === sRelDAT && cIsReleaseData) {
    relBeats := relBeats - 1.U
    when(relBeats === 1.U) { relState := sRelAck }
  }
  when(io.tl.c.fire && snpState === sSnpDataFwd && cIsProbeAckData) {
    snpBeats := snpBeats - 1.U
    when(snpBeats === 1.U) { snpState := sSnpIdle }
  }
}
