package tlbridge

import chisel3._
import chisel3.util._

/** TileLink-C to CHI Issue-E bridge (RN-F role).
  *
  *  Stage 5 implementation: read path + release path + snoop path.
  *
  *  Three independent engines run in parallel:
  *    - acquire: TL-A AcquireBlock / AcquirePerm to CHI Read / MakeUnique
  *    - release: TL-C Release / ReleaseData to CHI Evict / WriteBack /
  *               WriteClean
  *    - snoop:   CHI Snp to TL-B Probe to TL-C ProbeAck / ProbeAckData
  *               then back as CHI SnpResp / SnpRespData
  *
  *  Shared CHI channels are arbitrated:
  *    txreq:  acquire greater than release      (snoop does not use REQ)
  *    txrsp:  acquire (CompAck) greater than snoop (SnpResp)
  *    txdat:  release (CopyBackWrData) greater than snoop (SnpRespData)
  *    rxrsp:  routed by txnID MSB: 0 to acquire, 1 to release
  *  The TL side:
  *    A: acquire engine only
  *    B: snoop engine only
  *    C: routed by opcode (ProbeAck families to snoop, Release families
  *       to release)
  *    D: acquire (Grant / GrantData) greater than release (ReleaseAck)
  *    E: acquire engine only
  *
  *  TxnID partitioning:
  *    acquire txnID = {1'b0, source}
  *    release txnID = {1'b1, source}
  *    snoop txnID   = whatever the HN chose (RN-side echo only)
  *
  *  Stage 5 limits:
  *    - probe / release race is not collapsed in the bridge.  The TL
  *      master is expected to respond to a Probe even if it just issued
  *      a Release for the same line.  See doc/CHI_PLAN.md section 5.
  *    - SnpOnce treated as a normal toB probe.
  *    - no-change ProbeAck params (TtoT / BtoB / NtoN) reported as SC.
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

  io.tl.a.ready := (acqState === sAcqIdle) && (isAcqBlock || isAcqPerm)

  when(io.tl.a.fire) {
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
  // CHI txreq — arbitrated, acquire priority
  // =====================================================================
  val acqWantsREQ = (acqState === sAcqREQ)
  val relWantsREQ = (relState === sRelREQ)

  io.chi.txreq.valid := acqWantsREQ || relWantsREQ
  io.chi.txreq.bits  := 0.U.asTypeOf(new CHIReq(chip))
  when(acqWantsREQ) {
    io.chi.txreq.bits.opcode     := acqOp
    io.chi.txreq.bits.addr       := acqAddr
    io.chi.txreq.bits.txnID      := acqTxnID
    io.chi.txreq.bits.size       := acqSize(2,0)
    io.chi.txreq.bits.expCompAck := true.B
    io.chi.txreq.bits.snpAttr    := true.B
  }.otherwise {
    io.chi.txreq.bits.opcode     := relOp
    io.chi.txreq.bits.addr       := relAddr
    io.chi.txreq.bits.txnID      := relTxnID
    io.chi.txreq.bits.size       := relSize(2,0)
    io.chi.txreq.bits.expCompAck := false.B
    io.chi.txreq.bits.snpAttr    := true.B
  }

  when(io.chi.txreq.fire) {
    when(acqWantsREQ) {
      acqState := Mux(acqNeedsData, sAcqDAT, sAcqRSP)
    }.otherwise {
      relState := sRelRsp
    }
  }

  // =====================================================================
  // CHI rxdat → TL D (acquire data path only)
  // =====================================================================
  val datMatch = io.chi.rxdat.valid && (io.chi.rxdat.bits.txnID === acqTxnID)
  io.chi.rxdat.ready := (acqState === sAcqDAT) && io.tl.d.ready

  // =====================================================================
  // CHI rxrsp — routed by txnID MSB
  // =====================================================================
  val rxrspIsRel  = io.chi.rxrsp.bits.txnID(chip.txnIDBits - 1)
  val rxrspForAcq = io.chi.rxrsp.valid && !rxrspIsRel && (io.chi.rxrsp.bits.txnID === acqTxnID)
  val rxrspForRel = io.chi.rxrsp.valid &&  rxrspIsRel && (io.chi.rxrsp.bits.txnID === relTxnID)

  val acqWantsRsp = (acqState === sAcqRSP) && rxrspForAcq
  val relWantsRsp = (relState === sRelRsp) && rxrspForRel
  io.chi.rxrsp.ready := (acqWantsRsp && io.tl.d.ready) || relWantsRsp

  val respToT = Mux(acqState === sAcqDAT,
                    io.chi.rxdat.bits.resp === CHIResp.UC || io.chi.rxdat.bits.resp === CHIResp.UD,
                    io.chi.rxrsp.bits.resp === CHIResp.UC || io.chi.rxrsp.bits.resp === CHIResp.UD)

  // =====================================================================
  // TL D-channel — acquire (GrantData/Grant) OR release (ReleaseAck)
  // =====================================================================
  val acqWantsD = ((acqState === sAcqDAT) && datMatch) ||
                  ((acqState === sAcqRSP) && rxrspForAcq)
  val relWantsD = (relState === sRelAck)

  io.tl.d.valid := acqWantsD || relWantsD
  io.tl.d.bits  := 0.U.asTypeOf(new TLDChannel(tlp))
  io.tl.d.bits.opcode := Mux(acqWantsD,
                              Mux(acqNeedsData, TLOpcode.GrantData, TLOpcode.Grant),
                              TLOpcode.ReleaseAck)
  io.tl.d.bits.source := Mux(acqWantsD, acqSource, relSource)
  io.tl.d.bits.size   := Mux(acqWantsD, acqSize,   relSize)
  io.tl.d.bits.param  := Mux(acqWantsD, Mux(respToT, TLParam.toT, TLParam.toB), 0.U)
  io.tl.d.bits.data   := io.chi.rxdat.bits.data
  io.tl.d.bits.denied := Mux(acqWantsD,
                              Mux(acqState === sAcqDAT,
                                  io.chi.rxdat.bits.respErr(1),
                                  io.chi.rxrsp.bits.respErr(1)),
                              false.B)
  io.tl.d.bits.corrupt := Mux(acqWantsD && acqState === sAcqDAT,
                               io.chi.rxdat.bits.respErr(1), false.B)

  when(io.tl.d.fire) {
    when(acqWantsD) {
      when(acqState === sAcqDAT) {
        acqBeats := acqBeats - 1.U
        when(acqBeats === 1.U) { acqState := sAcqAck }
      }.otherwise {
        acqState := sAcqAck
      }
    }.elsewhen(relWantsD) {
      relState := sRelIdle
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
  // CHI txdat — release (CopyBackWrData) > snoop (SnpRespData)
  // =====================================================================
  val relWantsTXDAT = (relState === sRelDAT) && io.tl.c.valid && cIsReleaseData
  val snpWantsTXDAT = (snpState === sSnpDataFwd) && io.tl.c.valid && cIsProbeAckData

  // dataID counts up from 0 across the beats of a single transaction.
  // We use (totalBeats - remaining) so beat 0 → 0, beat 1 → 1, ...
  val relDataID = (chip.beatsPerLine.U - relBeats)(chip.dataIDBits - 1, 0)
  val snpDataID = (chip.beatsPerLine.U - snpBeats)(chip.dataIDBits - 1, 0)

  io.chi.txdat.valid := relWantsTXDAT || snpWantsTXDAT
  io.chi.txdat.bits  := 0.U.asTypeOf(new CHIDat(chip))
  when(relWantsTXDAT) {
    io.chi.txdat.bits.opcode := CHIOpcode.CopyBackWrData
    io.chi.txdat.bits.txnID  := relDBID
    io.chi.txdat.bits.data   := io.tl.c.bits.data
    io.chi.txdat.bits.be     := Fill(chip.strbBits, 1.U(1.W))
    io.chi.txdat.bits.resp   := Mux(relOp === CHIOpcode.WriteCleanFull, CHIResp.SC, CHIResp.I)
    io.chi.txdat.bits.dataID := relDataID
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

  // =====================================================================
  // TL C-channel — multi-way ready term, opcode-disambiguated
  // =====================================================================
  val snpC_AckFire = (snpState === sSnpWaitC) && cIsProbeAck         // single-beat
  val snpC_DataFwd = (snpState === sSnpDataFwd) && cIsProbeAckData &&
                     io.chi.txdat.ready && !relWantsTXDAT

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
