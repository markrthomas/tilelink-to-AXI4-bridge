package tlbridge

import chisel3._
import chisel3.util._

/** TileLink-UC (= TL-C wire shape, no coherence) → AXI4 bridge.
  *
  *  The bridge speaks the full TL-C channel set (A + B + C + D + E) but
  *  the AXI4 downstream cannot participate in a coherence protocol, so
  *  there is nothing to probe.  Probes are never issued (TL-B is tied
  *  off); the bridge always grants Tip (`T`) on Acquire — there are no
  *  other sharers to invalidate — and accepts voluntary `Release` /
  *  `ReleaseData` on TL-C, forwarding dirty writebacks to AXI4.
  *
  *  Supported A-channel opcodes:
  *    Get, PutFullData, PutPartialData, Hint, ArithmeticData,
  *    LogicalData (carry-over from the TL-UH bridge), plus
  *    AcquireBlock, AcquirePerm (TL-C cached opcodes).
  *
  *  C-channel opcodes consumed:
  *    Release       — voluntary permission shrink without data
  *    ReleaseData   — voluntary writeback with data
  *  (ProbeAck / ProbeAckData are never expected because the bridge
  *   never issues a Probe.  If they arrive anyway the bridge consumes
  *   them and emits no response — the master is misbehaving.)
  *
  *  Mapping (new vs. TLUHToAXI4):
  *    AcquireBlock     → AR + R          → D = GrantData(toT)
  *    AcquirePerm      → (none, no data) → D = Grant(toT)
  *    Release          → (none)          → D = ReleaseAck
  *    ReleaseData      → AW + W + B      → D = ReleaseAck
  *
  *  The bridge runs six parallel engines: read, write, hint, atomic
  *  (carry-over) plus acquire and release.  Each has a single
  *  outstanding slot.  The TL-D arbiter has priority
  *    W > R > Atom > Acq > Rel > Hint > Err
  *  with a sticky lock for any multi-beat AccessAckData / GrantData
  *  burst so the burst never gets interrupted by a sibling engine's
  *  single-beat response.  AcquireBlock and Get can both be in flight
  *  simultaneously using distinct TL `source` IDs — the AXI side
  *  demultiplexes R by ID, identical to the existing read↔atomic split.
  */
class TLUCToAXI4(val p: BridgeParams = BridgeParams()) extends Module {
  val io = IO(new Bundle {
    val tl  = new TLUCSlaveIO(p)
    val axi = new AxiMasterIO(p)
  })

  // ----------------------------------------------------------------------
  // A-channel opcode decode
  // ----------------------------------------------------------------------
  val isGet      = io.tl.a.bits.opcode === TLOpcode.Get
  val isPut      = (io.tl.a.bits.opcode === TLOpcode.PutFullData) ||
                   (io.tl.a.bits.opcode === TLOpcode.PutPartialData)
  val isHint     = io.tl.a.bits.opcode === TLOpcode.Hint
  val isAtomic   = (io.tl.a.bits.opcode === TLOpcode.ArithmeticData) ||
                   (io.tl.a.bits.opcode === TLOpcode.LogicalData)
  val isAcqBlock = io.tl.a.bits.opcode === TLOpcode.AcquireBlock
  val isAcqPerm  = io.tl.a.bits.opcode === TLOpcode.AcquirePerm
  val isAcquire  = isAcqBlock || isAcqPerm
  val isSupported = isGet || isPut || isHint || isAtomic || isAcquire
  val sizeLegal = Mux(isAtomic, io.tl.a.bits.size <= p.beatSizeLg.U,
                                io.tl.a.bits.size <= p.sizeBits.U)
  val isLocalError = !isSupported || !sizeLegal
  val opHasData = isPut || isAtomic   // AcquireBlock requests data, doesn't carry it

  // beats = max(1, (1 << a_size) / beatBytes)
  val aBeats = Mux(io.tl.a.bits.size <= p.beatSizeLg.U, 1.U,
                   1.U << (io.tl.a.bits.size - p.beatSizeLg.U))

  def alignAddr(addr: UInt): UInt =
    if (p.beatSizeLg == 0) addr
    else Cat(addr(p.addrBits - 1, p.beatSizeLg), 0.U(p.beatSizeLg.W))

  // ----------------------------------------------------------------------
  // C-channel opcode decode
  // ----------------------------------------------------------------------
  val isRelease     = io.tl.c.bits.opcode === TLOpcode.Release
  val isReleaseData = io.tl.c.bits.opcode === TLOpcode.ReleaseData
  val isReleaseAny  = isRelease || isReleaseData
  val cBeats = Mux(io.tl.c.bits.size <= p.beatSizeLg.U, 1.U,
                   1.U << (io.tl.c.bits.size - p.beatSizeLg.U))

  // ======================================================================
  // READ ENGINE (Get)
  // ======================================================================
  val sRIdle :: sRAR :: sRResp :: Nil = Enum(3)
  val rState   = RegInit(sRIdle)
  val rSource  = RegInit(0.U(p.sourceBits.W))
  val rSize    = RegInit(0.U(p.sizeBits.W))
  val rAddr    = RegInit(0.U(p.addrBits.W))
  val rBeats   = RegInit(0.U((p.sizeBits + 1).W))

  val rCanAcceptA = (rState === sRIdle)

  // ======================================================================
  // WRITE ENGINE (Put*)
  // ======================================================================
  val sWIdle :: sWAW :: sWData :: sWResp :: Nil = Enum(4)
  val wState   = RegInit(sWIdle)
  val wSource  = RegInit(0.U(p.sourceBits.W))
  val wSize    = RegInit(0.U(p.sizeBits.W))
  val wAddr    = RegInit(0.U(p.addrBits.W))
  val wBeats   = RegInit(0.U((p.sizeBits + 1).W))

  val wPeekFirst = (wState === sWIdle)
  val wAcceptBeat = (wState === sWData)

  // ======================================================================
  // HINT SLOT
  // ======================================================================
  val hPending = RegInit(false.B)
  val hSource  = RegInit(0.U(p.sourceBits.W))
  val hSize    = RegInit(0.U(p.sizeBits.W))

  val hCanAcceptA = !hPending

  // ======================================================================
  // ATOMIC ENGINE (RMW)
  // ======================================================================
  val sAIdle :: sAAR :: sARead :: sAAW :: sAWrite :: sABresp :: sAResp :: Nil = Enum(7)
  val aState   = RegInit(sAIdle)
  val aSource  = RegInit(0.U(p.sourceBits.W))
  val aSize    = RegInit(0.U(p.sizeBits.W))
  val aAddr    = RegInit(0.U(p.addrBits.W))
  val aData    = RegInit(0.U(p.dataBits.W))
  val aMask    = RegInit(0.U(p.strbBits.W))
  val aOpcode  = RegInit(0.U(3.W))
  val aParam   = RegInit(0.U(3.W))
  val aOldData = RegInit(0.U(p.dataBits.W))
  val aRespErr = RegInit(false.B)
  val aRCorrupt = RegInit(false.B)

  val aCanAcceptA = (aState === sAIdle)

  // ALU
  val op1 = aOldData
  val op2 = aData
  val op1s = op1.asSInt
  val op2s = op2.asSInt
  val aluOut = WireDefault(0.U(p.dataBits.W))

  when(aOpcode === TLOpcode.ArithmeticData) {
    switch(aParam) {
      is(0.U) { aluOut := Mux(op1s < op2s, op1, op2) }
      is(1.U) { aluOut := Mux(op1s > op2s, op1, op2) }
      is(2.U) { aluOut := Mux(op1 < op2, op1, op2) }
      is(3.U) { aluOut := Mux(op1 > op2, op1, op2) }
      is(4.U) { aluOut := op1 + op2 }
    }
  }.otherwise {
    switch(aParam) {
      is(0.U) { aluOut := op1 ^ op2 }
      is(1.U) { aluOut := op1 | op2 }
      is(2.U) { aluOut := op1 & op2 }
      is(3.U) { aluOut := op2 }
    }
  }

  // ======================================================================
  // LOCAL ERROR SLOT
  // ----------------------------------------------------------------------
  // In TL-UC the only opcodes that reach this slot are reserved/illegal
  // (TL spec has none above 7) or oversized requests.  AcquireBlock and
  // AcquirePerm are now SUPPORTED, so the error slot is rarely hit.
  // ======================================================================
  val sEIdle :: sEData :: sEResp :: Nil = Enum(3)
  val eState   = RegInit(sEIdle)
  val eSource  = RegInit(0.U(p.sourceBits.W))
  val eSize    = RegInit(0.U(p.sizeBits.W))
  val eBeats   = RegInit(0.U((p.sizeBits + 1).W))

  val eCanAcceptA = (eState === sEIdle)
  val eAcceptBeat = (eState === sEData)

  // ======================================================================
  // ACQUIRE ENGINE (AcquireBlock + AcquirePerm)
  // ----------------------------------------------------------------------
  // AcquireBlock: AR + R → GrantData(toT) (multi-beat for cache-line reads)
  // AcquirePerm:  (no AXI) → Grant(toT)  (no data, just permission)
  // Both end with GrantAck on TL-E to release the engine slot.
  // ======================================================================
  val sAcqIdle :: sAcqAR :: sAcqResp :: sAcqAck :: Nil = Enum(4)
  val acqState   = RegInit(sAcqIdle)
  val acqSource  = RegInit(0.U(p.sourceBits.W))
  val acqSize    = RegInit(0.U(p.sizeBits.W))
  val acqAddr    = RegInit(0.U(p.addrBits.W))
  val acqHasData = RegInit(false.B)   // true for AcquireBlock, false for AcquirePerm
  val acqBeats   = RegInit(0.U((p.sizeBits + 1).W))

  val acqCanAcceptA = (acqState === sAcqIdle)
  // Sink ID for one-deep slot.  D.sink is 1 bit; tie to 0 here so any
  // GrantAck the master sends back is unambiguous.
  val ACQ_SINK = 0.U(1.W)

  // ======================================================================
  // RELEASE ENGINE (Release + ReleaseData on TL-C)
  // ----------------------------------------------------------------------
  // Release       : single C beat, no AXI → ReleaseAck on D
  // ReleaseData   : peek first C beat to capture context (analogous to
  //                 wPeekFirst), drain C beats while driving AXI W,
  //                 wait for B, emit ReleaseAck on D.
  // ======================================================================
  val sRelIdle :: sRelAW :: sRelData :: sRelBresp :: sRelAck :: Nil = Enum(5)
  val relState   = RegInit(sRelIdle)
  val relSource  = RegInit(0.U(p.sourceBits.W))
  val relSize    = RegInit(0.U(p.sizeBits.W))
  val relAddr    = RegInit(0.U(p.addrBits.W))
  val relBeats   = RegInit(0.U((p.sizeBits + 1).W))
  val relRespErr = RegInit(false.B)

  val relCanAcceptC = (relState === sRelIdle)
  val relPeekData   = (relState === sRelIdle)       // peek-don't-fire for ReleaseData
  val relAcceptBeat = (relState === sRelData)        // accept ReleaseData beats

  // ======================================================================
  // A-CHANNEL ROUTING
  // ======================================================================
  val aDrivingW   = (aState === sAWrite)
  val relDrivingW = (relState === sRelData)
  val relDrivingAW = (relState === sRelAW)
  val aDrivingAW  = (aState === sAAW)

  io.tl.a.ready := MuxCase(false.B, Seq(
    (isLocalError && eAcceptBeat)                                                            -> true.B,
    (isLocalError && eCanAcceptA && !opHasData)                                              -> true.B,
    (isGet      && sizeLegal && rCanAcceptA)                                                 -> true.B,
    (isHint     && sizeLegal && hCanAcceptA)                                                 -> true.B,
    (isPut      && sizeLegal && wAcceptBeat && io.axi.w.ready && !aDrivingW && !relDrivingW) -> true.B,
    (isAtomic   && sizeLegal && aCanAcceptA)                                                 -> true.B,
    (isAcquire  && sizeLegal && acqCanAcceptA)                                               -> true.B,
  ))

  // ---- Read engine A-side ----
  when(rState === sRIdle && io.tl.a.valid && isGet && sizeLegal && rCanAcceptA) {
    rSource := io.tl.a.bits.source
    rSize   := io.tl.a.bits.size
    rAddr   := io.tl.a.bits.address
    rBeats  := aBeats
    rState  := sRAR
  }

  // ---- Write engine A-side ----
  when(wState === sWIdle && io.tl.a.valid && isPut && sizeLegal && wPeekFirst) {
    wSource := io.tl.a.bits.source
    wSize   := io.tl.a.bits.size
    wAddr   := io.tl.a.bits.address
    wBeats  := aBeats
    wState  := sWAW
  }

  // ---- Hint slot A-side ----
  when(io.tl.a.valid && isHint && sizeLegal && hCanAcceptA) {
    hSource  := io.tl.a.bits.source
    hSize    := io.tl.a.bits.size
    hPending := true.B
  }

  // ---- Atomic engine A-side ----
  when(io.tl.a.fire && isAtomic && sizeLegal && aCanAcceptA) {
    aSource  := io.tl.a.bits.source
    aSize    := io.tl.a.bits.size
    aAddr    := io.tl.a.bits.address
    aData    := io.tl.a.bits.data
    aMask    := io.tl.a.bits.mask
    aOpcode  := io.tl.a.bits.opcode
    aParam   := io.tl.a.bits.param
    aRespErr := false.B
    aRCorrupt := false.B
    aState   := sAAR
  }

  // ---- Acquire engine A-side ----
  when(io.tl.a.fire && isAcquire && sizeLegal && acqCanAcceptA) {
    acqSource  := io.tl.a.bits.source
    acqSize    := io.tl.a.bits.size
    acqAddr    := io.tl.a.bits.address
    acqHasData := isAcqBlock
    acqBeats   := Mux(isAcqBlock, aBeats, 0.U)
    acqState   := Mux(isAcqBlock, sAcqAR, sAcqResp)
  }

  // ---- Local error slot A-side ----
  when(eState === sEIdle && io.tl.a.valid && isLocalError) {
    eSource := io.tl.a.bits.source
    eSize   := io.tl.a.bits.size
    when(opHasData) {
      eBeats := aBeats
      eState := sEData
    }.otherwise {
      eState := sEResp
    }
  }

  when(eState === sEData && io.tl.a.fire && isLocalError) {
    eBeats := eBeats - 1.U
    when(eBeats === 1.U) { eState := sEResp }
  }

  // ======================================================================
  // C-CHANNEL ROUTING (Release / ReleaseData)
  // ----------------------------------------------------------------------
  // Release       : single beat → C.fire immediately, transition to sRelAck.
  // ReleaseData   : peek-don't-fire first beat (capture context, drive AW),
  //                 then accept beats in sRelData while AXI W is ready.
  // ======================================================================
  io.tl.c.ready := MuxCase(false.B, Seq(
    (relState === sRelIdle && isRelease)                                                                       -> true.B,
    (relAcceptBeat && isReleaseData && io.axi.w.ready && !aDrivingW && !wAcceptBeat)                           -> true.B,
  ))

  when(relState === sRelIdle && io.tl.c.valid && isReleaseAny) {
    relSource := io.tl.c.bits.source
    relSize   := io.tl.c.bits.size
    relAddr   := io.tl.c.bits.address
    relRespErr := false.B
    when(isReleaseData) {
      relBeats := cBeats
      relState := sRelAW           // peek-don't-fire: we did NOT consume C beat 0
    }.otherwise {
      // Release single-beat fires C and transitions to sRelAck.
      relState := sRelAck
    }
  }

  // ======================================================================
  // B-CHANNEL — tied off.  The bridge never issues a Probe.
  // ======================================================================
  io.tl.b.valid := false.B
  io.tl.b.bits  := 0.U.asTypeOf(new TLBChannel(p))

  // ======================================================================
  // E-CHANNEL — accept GrantAck whenever the acquire engine is waiting for it.
  // ======================================================================
  io.tl.e.ready := (acqState === sAcqAck)
  when(io.tl.e.fire) {
    acqState := sAcqIdle
  }

  // ======================================================================
  // AXI-SIDE OUTPUTS — ARBITRATED ACROSS ENGINES
  // ----------------------------------------------------------------------
  // AR sources: Read, Acquire(Block), Atomic
  // AW sources: Write, Release(Data), Atomic
  // W  sources: Write, Release(Data), Atomic
  // B  consumed by: Write, Release, Atomic
  // R  consumed by: Read, Acquire, Atomic
  // ----------------------------------------------------------------------
  // Disambiguation: each engine forwards its TL source as the AXI ID,
  // and the bridge gates response acceptance on ID match.  A
  // well-behaved master must use distinct sources for concurrent
  // transactions on the same AXI channel — that's the existing
  // cross-engine source uniqueness rule.
  // ======================================================================

  // ---- AR ----
  val arR   = Wire(new AxiAddr(p))
  arR       := 0.U.asTypeOf(new AxiAddr(p))
  arR.id    := rSource.pad(p.idBits)
  arR.addr  := alignAddr(rAddr)
  arR.len   := (rBeats - 1.U).pad(p.lenBits)
  arR.size  := p.beatSizeLg.U
  arR.burst := AxiBurst.INCR
  arR.prot  := 1.U

  val arAcq = Wire(new AxiAddr(p))
  arAcq        := 0.U.asTypeOf(new AxiAddr(p))
  arAcq.id     := acqSource.pad(p.idBits)
  arAcq.addr   := alignAddr(acqAddr)
  arAcq.len    := (acqBeats - 1.U).pad(p.lenBits)
  arAcq.size   := p.beatSizeLg.U
  arAcq.burst  := AxiBurst.INCR
  arAcq.prot   := 1.U

  val arA = Wire(new AxiAddr(p))
  arA        := 0.U.asTypeOf(new AxiAddr(p))
  arA.id     := aSource.pad(p.idBits)
  arA.addr   := alignAddr(aAddr)
  arA.len    := 0.U
  arA.size   := p.beatSizeLg.U
  arA.burst  := AxiBurst.INCR
  arA.lock   := 1.U
  arA.prot   := 1.U

  // AR arbiter: priority Atomic > Read > Acquire.  Each is single-shot
  // (one AR per transaction), so contention is short-lived.
  io.axi.ar.valid := (rState === sRAR) || (aState === sAAR) || (acqState === sAcqAR)
  io.axi.ar.bits  := Mux(aState === sAAR, arA,
                       Mux(rState === sRAR, arR, arAcq))

  when(io.axi.ar.fire) {
    when(aState === sAAR)         { aState   := sARead }
    .elsewhen(rState === sRAR)    { rState   := sRResp }
    .elsewhen(acqState === sAcqAR){ acqState := sAcqResp }
  }

  // ---- AW ----
  val awW = Wire(new AxiAddr(p))
  awW       := 0.U.asTypeOf(new AxiAddr(p))
  awW.id    := wSource.pad(p.idBits)
  awW.addr  := alignAddr(wAddr)
  awW.len   := (wBeats - 1.U).pad(p.lenBits)
  awW.size  := p.beatSizeLg.U
  awW.burst := AxiBurst.INCR
  awW.prot  := 1.U

  val awRel = Wire(new AxiAddr(p))
  awRel       := 0.U.asTypeOf(new AxiAddr(p))
  awRel.id    := relSource.pad(p.idBits)
  awRel.addr  := alignAddr(relAddr)
  awRel.len   := (relBeats - 1.U).pad(p.lenBits)
  awRel.size  := p.beatSizeLg.U
  awRel.burst := AxiBurst.INCR
  awRel.prot  := 1.U

  val awA = Wire(new AxiAddr(p))
  awA        := 0.U.asTypeOf(new AxiAddr(p))
  awA.id     := aSource.pad(p.idBits)
  awA.addr   := alignAddr(aAddr)
  awA.len    := 0.U
  awA.size   := p.beatSizeLg.U
  awA.burst  := AxiBurst.INCR
  awA.lock   := 1.U
  awA.prot   := 1.U

  io.axi.aw.valid := (wState === sWAW) || (aState === sAAW) || (relState === sRelAW)
  io.axi.aw.bits  := Mux(aState === sAAW, awA,
                       Mux(wState === sWAW, awW, awRel))

  when(io.axi.aw.fire) {
    when(aState === sAAW)             { aState   := sAWrite }
    .elsewhen(wState === sWAW)        { wState   := sWData }
    .elsewhen(relState === sRelAW)    { relState := sRelData }
  }

  // ---- W ----
  val wW = Wire(new AxiW(p))
  wW      := 0.U.asTypeOf(new AxiW(p))
  wW.data := io.tl.a.bits.data
  wW.strb := io.tl.a.bits.mask
  wW.last := (wBeats === 1.U)

  val wRel = Wire(new AxiW(p))
  wRel      := 0.U.asTypeOf(new AxiW(p))
  // ReleaseData beats carry full-line data; strb is all-ones because the
  // master is writing back what it had cached.
  wRel.data := io.tl.c.bits.data
  wRel.strb := ((1.U << p.strbBits) - 1.U)
  wRel.last := (relBeats === 1.U)

  val wA = Wire(new AxiW(p))
  wA      := 0.U.asTypeOf(new AxiW(p))
  wA.data := aluOut
  wA.strb := aMask
  wA.last := true.B

  // W is driven by the engine in its data state.  At most one engine
  // sources W at a time — see the a.ready and c.ready gates above.
  io.axi.w.valid := ((wState === sWData) && io.tl.a.valid && isPut) ||
                    ((relState === sRelData) && io.tl.c.valid && isReleaseData) ||
                    (aState === sAWrite)
  io.axi.w.bits  := Mux(aState === sAWrite, wA,
                      Mux(relState === sRelData, wRel, wW))

  when(io.axi.w.fire) {
    when(aState === sAWrite) {
      aState := sABresp
    }.elsewhen(relState === sRelData) {
      relBeats := relBeats - 1.U
      when(relBeats === 1.U) { relState := sRelBresp }
    }.otherwise {
      wBeats := wBeats - 1.U
      when(wBeats === 1.U) { wState := sWResp }
    }
  }

  // ======================================================================
  // D-CHANNEL ARBITER
  // ----------------------------------------------------------------------
  // Selects between:
  //   W   : write engine in sWResp with B available
  //   R   : read engine in sRResp with R available
  //   Atom: atomic engine in sAResp
  //   Acq : acquire engine in sAcqResp (Grant or GrantData)
  //   Rel : release engine in sRelAck
  //   H   : hint pending
  //   E   : error pending
  // Burst lock covers any multi-beat AccessAckData / GrantData burst.
  // ======================================================================
  val dSelNone :: dSelW :: dSelR :: dSelH :: dSelE :: dSelA :: dSelAcq :: dSelRel :: Nil = Enum(8)

  val wBValid   = io.axi.b.valid && (io.axi.b.bits.id === wSource.pad(p.idBits))
  val rRValid   = io.axi.r.valid && (io.axi.r.bits.id === rSource.pad(p.idBits))
  val acqRValid = io.axi.r.valid && (io.axi.r.bits.id === acqSource.pad(p.idBits))
  val aRValid   = io.axi.r.valid && (io.axi.r.bits.id === aSource.pad(p.idBits))
  val aBValid   = io.axi.b.valid && (io.axi.b.bits.id === aSource.pad(p.idBits))
  val relBValid = io.axi.b.valid && (io.axi.b.bits.id === relSource.pad(p.idBits))

  val wRespReady   = (wState === sWResp) && wBValid
  val rRespReady   = (rState === sRResp) && rRValid
  val aRespReady   = (aState === sAResp)
  val acqRespReady = (acqState === sAcqResp) &&
                     Mux(acqHasData, acqRValid, true.B)
  val relRespReady = (relState === sRelAck)
  val eRespReady   = (eState === sEResp)

  // dataBurstLock covers both AccessAckData (read) and GrantData (acquire)
  // multi-beat responses.  Only one such burst is in flight at a time:
  // either read↔acquire collide on R-ID (forbidden by source uniqueness),
  // or they don't — so a single shared lock is sufficient.
  val rBurstLock   = RegInit(false.B)
  val acqBurstLock = RegInit(false.B)

  val dSel = WireDefault(dSelNone)
  when(rBurstLock) {
    dSel := dSelR
  }.elsewhen(acqBurstLock) {
    dSel := dSelAcq
  }.elsewhen(wRespReady) {
    dSel := dSelW
  }.elsewhen(rRespReady) {
    dSel := dSelR
  }.elsewhen(aRespReady) {
    dSel := dSelA
  }.elsewhen(acqRespReady) {
    dSel := dSelAcq
  }.elsewhen(relRespReady) {
    dSel := dSelRel
  }.elsewhen(hPending) {
    dSel := dSelH
  }.elsewhen(eRespReady) {
    dSel := dSelE
  }

  // ---- D defaults ----
  io.tl.d.valid := false.B
  io.tl.d.bits  := 0.U.asTypeOf(new TLDChannel(p))

  // ---- AXI B/R ready defaults; engine-internal handshakes ----
  // Atomic engine consumes B/R when in its internal states.
  io.axi.b.ready := (aState === sABresp && aBValid)
  io.axi.r.ready := (aState === sARead && aRValid)

  when(aState === sARead && io.axi.r.fire) {
    aOldData  := io.axi.r.bits.data
    aRespErr  := io.axi.r.bits.resp(1)
    aRCorrupt := io.axi.r.bits.resp(1)
    when(io.axi.r.bits.resp(1)) { aState := sAResp }
    .otherwise                  { aState := sAAW   }
  }
  when(aState === sABresp && io.axi.b.fire) {
    when(io.axi.b.bits.resp(1)) { aRespErr := true.B }
    aState := sAResp
  }

  switch(dSel) {
    is(dSelW) {
      io.axi.b.ready       := io.tl.d.ready
      io.tl.d.valid        := true.B
      io.tl.d.bits.opcode  := TLOpcode.AccessAck
      io.tl.d.bits.param   := 0.U
      io.tl.d.bits.size    := wSize
      io.tl.d.bits.source  := wSource
      io.tl.d.bits.sink    := 0.U
      io.tl.d.bits.denied  := io.axi.b.bits.resp(1)
      io.tl.d.bits.corrupt := false.B
      io.tl.d.bits.data    := 0.U
      when(io.tl.d.fire) { wState := sWIdle }
    }
    is(dSelR) {
      io.axi.r.ready       := io.tl.d.ready
      io.tl.d.valid        := io.axi.r.valid
      io.tl.d.bits.opcode  := TLOpcode.AccessAckData
      io.tl.d.bits.param   := 0.U
      io.tl.d.bits.size    := rSize
      io.tl.d.bits.source  := rSource
      io.tl.d.bits.sink    := 0.U
      io.tl.d.bits.denied  := io.axi.r.bits.resp(1)
      io.tl.d.bits.corrupt := io.axi.r.bits.resp(1)
      io.tl.d.bits.data    := io.axi.r.bits.data
      when(io.axi.r.fire) {
        rBurstLock := !io.axi.r.bits.last
        when(io.axi.r.bits.last) { rState := sRIdle }
      }
    }
    is(dSelAcq) {
      when(acqHasData) {
        // GrantData burst — forward R beats as GrantData beats.
        io.axi.r.ready       := io.tl.d.ready
        io.tl.d.valid        := io.axi.r.valid
        io.tl.d.bits.opcode  := TLOpcode.GrantData
        io.tl.d.bits.param   := TLParam.toT
        io.tl.d.bits.size    := acqSize
        io.tl.d.bits.source  := acqSource
        io.tl.d.bits.sink    := ACQ_SINK
        io.tl.d.bits.denied  := io.axi.r.bits.resp(1)
        io.tl.d.bits.corrupt := io.axi.r.bits.resp(1)
        io.tl.d.bits.data    := io.axi.r.bits.data
        when(io.axi.r.fire) {
          acqBurstLock := !io.axi.r.bits.last
          when(io.axi.r.bits.last) { acqState := sAcqAck }
        }
      }.otherwise {
        // AcquirePerm — emit Grant directly, no data.
        io.tl.d.valid        := true.B
        io.tl.d.bits.opcode  := TLOpcode.Grant
        io.tl.d.bits.param   := TLParam.toT
        io.tl.d.bits.size    := acqSize
        io.tl.d.bits.source  := acqSource
        io.tl.d.bits.sink    := ACQ_SINK
        io.tl.d.bits.denied  := false.B
        io.tl.d.bits.corrupt := false.B
        io.tl.d.bits.data    := 0.U
        when(io.tl.d.fire) { acqState := sAcqAck }
      }
    }
    is(dSelRel) {
      io.tl.d.valid        := true.B
      io.tl.d.bits.opcode  := TLOpcode.ReleaseAck
      io.tl.d.bits.param   := 0.U
      io.tl.d.bits.size    := relSize
      io.tl.d.bits.source  := relSource
      io.tl.d.bits.sink    := 0.U
      io.tl.d.bits.denied  := relRespErr
      io.tl.d.bits.corrupt := false.B
      io.tl.d.bits.data    := 0.U
      when(io.tl.d.fire) { relState := sRelIdle }
    }
    is(dSelH) {
      io.tl.d.valid        := true.B
      io.tl.d.bits.opcode  := TLOpcode.HintAck
      io.tl.d.bits.param   := 0.U
      io.tl.d.bits.size    := hSize
      io.tl.d.bits.source  := hSource
      io.tl.d.bits.sink    := 0.U
      io.tl.d.bits.denied  := false.B
      io.tl.d.bits.corrupt := false.B
      io.tl.d.bits.data    := 0.U
      when(io.tl.d.fire) { hPending := false.B }
    }
    is(dSelA) {
      io.tl.d.valid        := true.B
      io.tl.d.bits.opcode  := TLOpcode.AccessAckData
      io.tl.d.bits.param   := 0.U
      io.tl.d.bits.size    := aSize
      io.tl.d.bits.source  := aSource
      io.tl.d.bits.sink    := 0.U
      io.tl.d.bits.denied  := aRespErr
      io.tl.d.bits.corrupt := aRCorrupt
      io.tl.d.bits.data    := aOldData
      when(io.tl.d.fire) { aState := sAIdle }
    }
    is(dSelE) {
      io.tl.d.valid        := true.B
      io.tl.d.bits.opcode  := TLOpcode.AccessAck
      io.tl.d.bits.param   := 0.U
      io.tl.d.bits.size    := eSize
      io.tl.d.bits.source  := eSource
      io.tl.d.bits.sink    := 0.U
      io.tl.d.bits.denied  := true.B
      io.tl.d.bits.corrupt := false.B
      io.tl.d.bits.data    := 0.U
      when(io.tl.d.fire) { eState := sEIdle }
    }
  }

  // ======================================================================
  // RELEASE engine — B handling.  When the bridge is in sRelBresp AND
  // the incoming B beat carries the release source, consume it and
  // transition.  Gate the override on relBValid so we don't clobber the
  // write engine's b.ready (via dSelW) when the B beat is for the
  // write engine — only one engine can own a given B beat at a time
  // because B.id is unique, but Chisel last-connect would otherwise
  // override b.ready regardless.
  // ======================================================================
  when(relState === sRelBresp && relBValid) {
    io.axi.b.ready := true.B
    when(io.axi.b.fire) {
      when(io.axi.b.bits.resp(1)) { relRespErr := true.B }
      relState := sRelAck
    }
  }
}
