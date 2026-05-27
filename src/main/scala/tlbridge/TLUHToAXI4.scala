package tlbridge

import chisel3._
import chisel3.util._

/** TileLink-UH (slave) → AXI4 (master) bridge — multi-outstanding.
  *
  *  Supported A-channel opcodes: Get, PutFullData, PutPartialData, Hint,
  *  ArithmeticData, LogicalData.
  *
  *  Mapping:
  *    Get             → AR + R                → D = AccessAckData
  *    PutFullData     → AW + W                → D = AccessAck
  *    PutPartialData  → AW + W                → D = AccessAck      (TL mask  → AXI WSTRB)
  *    Hint            → (none)                → D = HintAck
  *    ArithmeticData  → AR(lock) + R + AW(lock) + W → D = AccessAckData (old)
  *    LogicalData     → AR(lock) + R + AW(lock) + W → D = AccessAckData (old)
  *
  *  Four parallel engines (read, write, hint, atomic RMW) share the TL-A
  *  channel via opcode-based routing and share the TL-D channel via a
  *  fixed-priority arbiter (W > R > A > H > E) with a read-burst lock so an
  *  AccessAckData burst is never interrupted mid-flight.  Each engine has
  *  a single outstanding slot — sufficient to overlap reads with writes
  *  and hints (AXI's AR/R and AW/W/B are independent channels).
  *
  *  AXI bursts are always INCR; AxSIZE is fixed at log2(beatBytes), with
  *  WSTRB (writes) handling sub-bus byte enables.  TL `source` is forwarded
  *  unchanged as the AXI ID for the respective transaction.  Atomics use
  *  AxLOCK=1 and limit `a.size <= log2(beatBytes)` (single beat only); the
  *  bridge returns the OLD value to TL per the TileLink-UH atomic contract.
  */
class TLUHToAXI4(val p: BridgeParams = BridgeParams()) extends Module {
  val io = IO(new Bundle {
    val tl  = new TLSlaveIO(p)
    val axi = new AxiMasterIO(p)
  })

  // ----------------------------------------------------------------------
  // A-channel opcode decode (shared by all routing logic below)
  // ----------------------------------------------------------------------
  val isGet  = io.tl.a.bits.opcode === TLOpcode.Get
  val isPut  = (io.tl.a.bits.opcode === TLOpcode.PutFullData) ||
               (io.tl.a.bits.opcode === TLOpcode.PutPartialData)
  val isHint = io.tl.a.bits.opcode === TLOpcode.Hint
  val isAtomic = (io.tl.a.bits.opcode === TLOpcode.ArithmeticData) ||
                 (io.tl.a.bits.opcode === TLOpcode.LogicalData)
  val isSupported = isGet || isPut || isHint || isAtomic
  val sizeLegal = Mux(isAtomic, io.tl.a.bits.size <= p.beatSizeLg.U,
                                io.tl.a.bits.size <= p.sizeBits.U)
  val isLocalError = !isSupported || !sizeLegal

  val opHasData = isPut || isAtomic

  // beats = max(1, (1 << a_size) / beatBytes)
  val aBeats = Mux(io.tl.a.bits.size <= p.beatSizeLg.U, 1.U,
                   1.U << (io.tl.a.bits.size - p.beatSizeLg.U))

  def alignAddr(addr: UInt): UInt =
    if (p.beatSizeLg == 0) addr
    else Cat(addr(p.addrBits - 1, p.beatSizeLg), 0.U(p.beatSizeLg.W))

  // ======================================================================
  // READ ENGINE
  // ======================================================================
  val sRIdle :: sRAR :: sRResp :: Nil = Enum(3)
  val rState   = RegInit(sRIdle)
  val rSource  = RegInit(0.U(p.sourceBits.W))
  val rSize    = RegInit(0.U(p.sizeBits.W))
  val rAddr    = RegInit(0.U(p.addrBits.W))
  val rBeats   = RegInit(0.U((p.sizeBits + 1).W))

  val rCanAcceptA = (rState === sRIdle)

  // ======================================================================
  // WRITE ENGINE
  // ======================================================================
  val sWIdle :: sWAW :: sWData :: sWResp :: Nil = Enum(4)
  val wState   = RegInit(sWIdle)
  val wSource  = RegInit(0.U(p.sourceBits.W))
  val wSize    = RegInit(0.U(p.sizeBits.W))
  val wAddr    = RegInit(0.U(p.addrBits.W))
  val wBeats   = RegInit(0.U((p.sizeBits + 1).W))

  val wPeekFirst = (wState === sWIdle)            // peek-don't-fire on first Put A
  val wAcceptBeat = (wState === sWData)           // accept Put data beats

  // ======================================================================
  // HINT SLOT (1-deep)
  // ======================================================================
  val hPending = RegInit(false.B)
  val hSource  = RegInit(0.U(p.sourceBits.W))
  val hSize    = RegInit(0.U(p.sizeBits.W))

  val hCanAcceptA = !hPending

  // ======================================================================
  // ATOMIC ENGINE (RMW)
  // ----------------------------------------------------------------------
  // Handles ArithmeticData and LogicalData via AXI exclusive access.
  // Sequence: AR (lock=1) -> R -> ALU -> AW (lock=1) -> W -> B -> D.
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
  // Error tracking: RRESP/BRESP collected across the RMW sequence.
  // AXI4 maps OKAY=00 (or EXOKAY=01 if the slave honors exclusive access);
  // anything with bit[1] set is SLVERR/DECERR — propagate as TL `denied`.
  // For exclusive writes, we don't differentiate OKAY vs EXOKAY here: many
  // AXI4 slaves return OKAY for exclusive writes (they don't model the
  // exclusive monitor) and the bridge is single-master, so we treat OKAY
  // as success.
  val aRespErr = RegInit(false.B)
  val aRCorrupt = RegInit(false.B)

  val aCanAcceptA = (aState === sAIdle)

  // ----------------------------------------------------------------------
  // ATOMIC ALU
  // ----------------------------------------------------------------------
  val op1 = aOldData
  val op2 = aData
  val op1s = op1.asSInt
  val op2s = op2.asSInt
  val aluOut = WireDefault(0.U(p.dataBits.W))

  when(aOpcode === TLOpcode.ArithmeticData) {
    switch(aParam) {
      is(0.U) { aluOut := Mux(op1s < op2s, op1, op2) } // MIN
      is(1.U) { aluOut := Mux(op1s > op2s, op1, op2) } // MAX
      is(2.U) { aluOut := Mux(op1 < op2, op1, op2) }   // MINU
      is(3.U) { aluOut := Mux(op1 > op2, op1, op2) }   // MAXU
      is(4.U) { aluOut := op1 + op2 }                  // ADD
    }
  }.otherwise { // LogicalData
    switch(aParam) {
      is(0.U) { aluOut := op1 ^ op2 }                  // XOR
      is(1.U) { aluOut := op1 | op2 }                  // OR
      is(2.U) { aluOut := op1 & op2 }                  // AND
      is(3.U) { aluOut := op2 }                        // SWAP
    }
  }

  // ======================================================================
  // LOCAL ERROR SLOT (1-deep)
  // ----------------------------------------------------------------------
  // Unsupported opcodes or out-of-envelope sizes are consumed locally and
  // answered with a denied AccessAck instead of permanently holding A.ready
  // low.  The bridge still documents these as integration errors; this slot
  // prevents a single bad request from wedging the bus during bring-up.
  // Handles both single-beat and multi-beat (burst) illegal requests.
  // ======================================================================
  val sEIdle :: sEData :: sEResp :: Nil = Enum(3)
  val eState   = RegInit(sEIdle)
  val eSource  = RegInit(0.U(p.sourceBits.W))
  val eSize    = RegInit(0.U(p.sizeBits.W))
  val eBeats   = RegInit(0.U((p.sizeBits + 1).W))

  val eCanAcceptA = (eState === sEIdle)
  val eAcceptBeat = (eState === sEData)

  // ======================================================================
  // A-CHANNEL ROUTING
  // ----------------------------------------------------------------------
  // a.ready firing rules, by opcode:
  //   Get  : ready when read engine idle               (single-beat fire)
  //   Hint : ready when hint slot free                 (single-beat fire)
  //   Put  : NOT ready in sWIdle (peek only); ready in sWData when W ready
  //          AND the atomic engine isn't currently driving W (else the Put
  //          beat would be consumed from TL while AXI sees atomic's data).
  //   Err  : ready in sEData (drain burst) or sEIdle (single-beat fire)
  // ======================================================================
  val aDrivingW = (aState === sAWrite)
  io.tl.a.ready := MuxCase(false.B, Seq(
    (isLocalError && eAcceptBeat)              -> true.B,
    (isLocalError && eCanAcceptA && !opHasData) -> true.B,
    (isGet  && sizeLegal && rCanAcceptA)       -> true.B,
    (isHint && sizeLegal && hCanAcceptA)       -> true.B,
    (isPut  && sizeLegal && wAcceptBeat && io.axi.w.ready && !aDrivingW) -> true.B,
    (isAtomic && sizeLegal && aCanAcceptA)     -> true.B,
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
    // peek — don't fire A, just capture context for the upcoming burst
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

  // ---- Local error slot A-side ----
  when(eState === sEIdle && io.tl.a.valid && isLocalError) {
    eSource := io.tl.a.bits.source
    eSize   := io.tl.a.bits.size
    when(opHasData) {
      // peek and transition to drain burst
      eBeats := aBeats
      eState := sEData
    }.otherwise {
      // single-beat fire
      eState := sEResp
    }
  }

  when(eState === sEData && io.tl.a.fire && isLocalError) {
    eBeats := eBeats - 1.U
    when(eBeats === 1.U) { eState := sEResp }
  }

  // ======================================================================
  // AXI-SIDE OUTPUTS (ARBITRATED)
  // ======================================================================
  val arR = Wire(new AxiAddr(p))
  arR       := 0.U.asTypeOf(new AxiAddr(p))
  arR.id    := rSource.pad(p.idBits)
  arR.addr  := alignAddr(rAddr)
  arR.len   := (rBeats - 1.U).pad(p.lenBits)
  arR.size  := p.beatSizeLg.U
  arR.burst := AxiBurst.INCR
  arR.prot  := 1.U

  val arA = Wire(new AxiAddr(p))
  arA        := 0.U.asTypeOf(new AxiAddr(p))
  arA.id     := aSource.pad(p.idBits)
  arA.addr   := alignAddr(aAddr)
  arA.len    := 0.U
  arA.size   := p.beatSizeLg.U
  arA.burst  := AxiBurst.INCR
  arA.lock   := 1.U // Exclusive
  arA.prot   := 1.U

  io.axi.ar.valid := (rState === sRAR) || (aState === sAAR)
  io.axi.ar.bits  := Mux(aState === sAAR, arA, arR)

  when(io.axi.ar.fire) {
    when(aState === sAAR) { aState := sARead }
    .otherwise            { rState := sRResp }
  }

  val awW = Wire(new AxiAddr(p))
  awW       := 0.U.asTypeOf(new AxiAddr(p))
  awW.id    := wSource.pad(p.idBits)
  awW.addr  := alignAddr(wAddr)
  awW.len   := (wBeats - 1.U).pad(p.lenBits)
  awW.size  := p.beatSizeLg.U
  awW.burst := AxiBurst.INCR
  awW.prot  := 1.U

  val awA = Wire(new AxiAddr(p))
  awA        := 0.U.asTypeOf(new AxiAddr(p))
  awA.id     := aSource.pad(p.idBits)
  awA.addr   := alignAddr(aAddr)
  awA.len    := 0.U
  awA.size   := p.beatSizeLg.U
  awA.burst  := AxiBurst.INCR
  awA.lock   := 1.U // Exclusive
  awA.prot   := 1.U

  io.axi.aw.valid := (wState === sWAW) || (aState === sAAW)
  io.axi.aw.bits  := Mux(aState === sAAW, awA, awW)

  when(io.axi.aw.fire) {
    when(aState === sAAW) { aState := sAWrite }
    .otherwise            { wState := sWData }
  }

  val wW = Wire(new AxiW(p))
  wW      := 0.U.asTypeOf(new AxiW(p))
  wW.data := io.tl.a.bits.data
  wW.strb := io.tl.a.bits.mask
  wW.last := (wBeats === 1.U)

  val wA = Wire(new AxiW(p))
  wA      := 0.U.asTypeOf(new AxiW(p))
  wA.data := aluOut
  wA.strb := aMask
  wA.last := true.B

  io.axi.w.valid := ((wState === sWData) && io.tl.a.valid && isPut) || (aState === sAWrite)
  io.axi.w.bits  := Mux(aState === sAWrite, wA, wW)

  when(io.axi.w.fire) {
    when(aState === sAWrite) {
      aState := sABresp
    }.otherwise {
      wBeats := wBeats - 1.U
      when(wBeats === 1.U) { wState := sWResp }
    }
  }

  val wLast = (wBeats === 1.U)

  // ======================================================================
  // D-CHANNEL ARBITER
  // ----------------------------------------------------------------------
  // Five response sources may be valid simultaneously:
  //   W : AXI B-channel valid AND write engine in sWResp
  //   R : AXI R-channel valid AND read engine in sRResp
  //   A : aState === sAResp (atomic result ready)
  //   H : hPending
  //   E : ePending (local unsupported/illegal request response)
  //
  // Fixed priority W > R > A > H > E, with a sticky lock for multi-beat
  // read bursts (once we start an AccessAckData burst we must drain it
  // before selecting another source).
  // ======================================================================
  val dSelNone :: dSelW :: dSelR :: dSelH :: dSelE :: dSelA :: Nil = Enum(6)

  val wBValid = io.axi.b.valid && (io.axi.b.bits.id === wSource.pad(p.idBits))
  val rRValid = io.axi.r.valid && (io.axi.r.bits.id === rSource.pad(p.idBits))
  val aRValid = io.axi.r.valid && (io.axi.r.bits.id === aSource.pad(p.idBits))
  val aBValid = io.axi.b.valid && (io.axi.b.bits.id === aSource.pad(p.idBits))

  val wRespReady = (wState === sWResp) && wBValid
  val rRespReady = (rState === sRResp) && rRValid
  val eRespReady = (eState === sEResp)
  val aRespReady = (aState === sAResp)

  val rBurstLock = RegInit(false.B) // 1 between first non-last R fire and last R fire

  val dSel = WireDefault(dSelNone)
  when(rBurstLock) {
    dSel := dSelR
  }.elsewhen(wRespReady) {
    dSel := dSelW
  }.elsewhen(rRespReady) {
    dSel := dSelR
  }.elsewhen(aRespReady) {
    dSel := dSelA
  }.elsewhen(hPending) {
    dSel := dSelH
  }.elsewhen(eRespReady) {
    dSel := dSelE
  }

  // ---- D-channel defaults ----
  io.tl.d.valid := false.B
  io.tl.d.bits  := 0.U.asTypeOf(new TLDChannel(p))

  // ID-routed internal AXI handshakes
  io.axi.b.ready := (aState === sABresp && aBValid)
  io.axi.r.ready := (aState === sARead && aRValid)

  when(aState === sARead && io.axi.r.fire) {
    aOldData  := io.axi.r.bits.data
    // RRESP[1]=1 indicates SLVERR/DECERR — propagate as TL denied+corrupt.
    aRespErr  := io.axi.r.bits.resp(1)
    aRCorrupt := io.axi.r.bits.resp(1)
    // Skip the write half if the read errored — there's nothing meaningful
    // to write back, and proceeding would surface a misleading second error.
    when(io.axi.r.bits.resp(1)) { aState := sAResp }
    .otherwise                  { aState := sAAW   }
  }
  when(aState === sABresp && io.axi.b.fire) {
    // BRESP[1]=1 (SLVERR/DECERR) → denied. EXOKAY (01) is treated as success.
    when(io.axi.b.bits.resp(1)) { aRespErr := true.B }
    aState := sAResp
  }

  switch(dSel) {
    is(dSelW) {
      io.axi.b.ready       := io.tl.d.ready
      // dSelW is selected only when wBValid (= b.valid && id matches),
      // so b.valid is implied here — no explicit gating needed.
      io.tl.d.valid        := true.B
      io.tl.d.bits.opcode  := TLOpcode.AccessAck
      io.tl.d.bits.param   := 0.U
      io.tl.d.bits.size    := wSize
      io.tl.d.bits.source  := wSource
      io.tl.d.bits.sink    := 0.U
      io.tl.d.bits.denied  := (io.axi.b.bits.resp =/= 0.U)
      io.tl.d.bits.corrupt := false.B
      io.tl.d.bits.data    := 0.U
      when(io.tl.d.fire) { wState := sWIdle }
    }
    is(dSelR) {
      io.axi.r.ready       := io.tl.d.ready
      // Gate D.valid on the backing AXI R beat — otherwise a sticky
      // rBurstLock with no fresh R from the slave would publish stale
      // r.bits.data on D (TL protocol violation).
      io.tl.d.valid        := io.axi.r.valid
      io.tl.d.bits.opcode  := TLOpcode.AccessAckData
      io.tl.d.bits.param   := 0.U
      io.tl.d.bits.size    := rSize
      io.tl.d.bits.source  := rSource
      io.tl.d.bits.sink    := 0.U
      // RRESP bit 1 distinguishes SLVERR=10 / DECERR=11 from OKAY/EXOKAY.
      io.tl.d.bits.denied  := (io.axi.r.bits.resp =/= 0.U)
      io.tl.d.bits.corrupt := io.axi.r.bits.resp(1)
      io.tl.d.bits.data    := io.axi.r.bits.data
      when(io.axi.r.fire) {
        rBurstLock := !io.axi.r.bits.last
        when(io.axi.r.bits.last) { rState := sRIdle }
      }
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
      // Return AccessAck for most errors; if we knew it was a Get we'd use AccessAckData
      // but for illegal/unsupported it's safer to just signal denial.
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
}
