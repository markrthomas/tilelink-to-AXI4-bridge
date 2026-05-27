package tlbridge

import chisel3._
import chisel3.util._

/** TileLink-UH (slave) → AXI4 (master) bridge — multi-outstanding.
  *
  *  Supported A-channel opcodes: Get, PutFullData, PutPartialData, Hint
  *  (atomics ArithmeticData / LogicalData are not implemented).
  *
  *  Mapping:
  *    Get             → AR + R   → D = AccessAckData
  *    PutFullData     → AW + W   → D = AccessAck
  *    PutPartialData  → AW + W   → D = AccessAck      (TL mask  → AXI WSTRB)
  *    Hint            → (none)   → D = HintAck
  *
  *  Two parallel engines (one read, one write) plus a 1-deep hint slot share
  *  the TL-A channel via opcode-based routing and share the TL-D channel via
  *  a fixed-priority arbiter (W > R > H) with a read-burst lock so an
  *  AccessAckData burst is never interrupted mid-flight.  At most one read
  *  and one write can be in flight simultaneously — sufficient to overlap
  *  reads with writes (AXI's AR/R and AW/W/B are independent channels).
  *
  *  AXI bursts are always INCR; AxSIZE is fixed at log2(beatBytes), with
  *  WSTRB (writes) handling sub-bus byte enables.  TL `source` is forwarded
  *  unchanged as the AXI ID for the respective transaction.
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

  // beats = max(1, (1 << a_size) / beatBytes)
  val aBytes = (1.U << io.tl.a.bits.size).asUInt
  val aBeats = Mux(aBytes <= p.beatBytes.U, 1.U, (aBytes >> p.beatSizeLg.U).asUInt)

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
  // A-CHANNEL ROUTING
  // ----------------------------------------------------------------------
  // a.ready firing rules, by opcode:
  //   Get  : ready when read engine idle               (single-beat fire)
  //   Hint : ready when hint slot free                 (single-beat fire)
  //   Put  : NOT ready in sWIdle (peek only); ready in sWData when W ready
  // ======================================================================
  io.tl.a.ready := MuxCase(false.B, Seq(
    (isGet  && rCanAcceptA)                    -> true.B,
    (isHint && hCanAcceptA)                    -> true.B,
    (isPut  && wAcceptBeat && io.axi.w.ready)  -> true.B,
  ))

  // ---- Read engine A-side ----
  when(rState === sRIdle && io.tl.a.valid && isGet && rCanAcceptA) {
    rSource := io.tl.a.bits.source
    rSize   := io.tl.a.bits.size
    rAddr   := io.tl.a.bits.address
    rBeats  := aBeats
    rState  := sRAR
  }

  // ---- Write engine A-side ----
  when(wState === sWIdle && io.tl.a.valid && isPut && wPeekFirst) {
    // peek — don't fire A, just capture context for the upcoming burst
    wSource := io.tl.a.bits.source
    wSize   := io.tl.a.bits.size
    wAddr   := io.tl.a.bits.address
    wBeats  := aBeats
    wState  := sWAW
  }

  // ---- Hint slot A-side ----
  when(io.tl.a.valid && isHint && hCanAcceptA) {
    hSource  := io.tl.a.bits.source
    hSize    := io.tl.a.bits.size
    hPending := true.B
  }

  // ======================================================================
  // AXI-SIDE OUTPUTS
  // ======================================================================
  io.axi.ar.valid      := (rState === sRAR)
  io.axi.ar.bits       := 0.U.asTypeOf(new AxiAddr(p))
  io.axi.ar.bits.id    := rSource
  io.axi.ar.bits.addr  := alignAddr(rAddr)
  io.axi.ar.bits.len   := (rBeats - 1.U).pad(p.lenBits)
  io.axi.ar.bits.size  := p.beatSizeLg.U
  io.axi.ar.bits.burst := AxiBurst.INCR

  when(rState === sRAR && io.axi.ar.fire) { rState := sRResp }

  io.axi.aw.valid      := (wState === sWAW)
  io.axi.aw.bits       := 0.U.asTypeOf(new AxiAddr(p))
  io.axi.aw.bits.id    := wSource
  io.axi.aw.bits.addr  := alignAddr(wAddr)
  io.axi.aw.bits.len   := (wBeats - 1.U).pad(p.lenBits)
  io.axi.aw.bits.size  := p.beatSizeLg.U
  io.axi.aw.bits.burst := AxiBurst.INCR

  when(wState === sWAW && io.axi.aw.fire) { wState := sWData }

  val wLast = (wBeats === 1.U)
  io.axi.w.valid     := (wState === sWData) && io.tl.a.valid && isPut
  io.axi.w.bits      := 0.U.asTypeOf(new AxiW(p))
  io.axi.w.bits.data := io.tl.a.bits.data
  io.axi.w.bits.strb := io.tl.a.bits.mask
  io.axi.w.bits.last := wLast

  when(wState === sWData && io.axi.w.fire) {
    wBeats := wBeats - 1.U
    when(wLast) { wState := sWResp }
  }

  // ======================================================================
  // D-CHANNEL ARBITER
  // ----------------------------------------------------------------------
  // Three response sources may be valid simultaneously:
  //   W : AXI B-channel valid AND write engine in sWResp
  //   R : AXI R-channel valid AND read engine in sRResp
  //   H : hPending
  //
  // Fixed priority W > R > H, with a sticky lock for multi-beat read
  // bursts (once we start an AccessAckData burst we must drain it before
  // selecting another source).
  // ======================================================================
  val dSelNone :: dSelW :: dSelR :: dSelH :: Nil = Enum(4)

  val wRespReady = (wState === sWResp) && io.axi.b.valid
  val rRespReady = (rState === sRResp) && io.axi.r.valid

  val rBurstLock = RegInit(false.B) // 1 between first non-last R fire and last R fire

  val dSel = WireDefault(dSelNone)
  when(rBurstLock) {
    dSel := dSelR
  }.elsewhen(wRespReady) {
    dSel := dSelW
  }.elsewhen(rRespReady) {
    dSel := dSelR
  }.elsewhen(hPending) {
    dSel := dSelH
  }

  // ---- D-channel defaults ----
  io.tl.d.valid := false.B
  io.tl.d.bits  := 0.U.asTypeOf(new TLDChannel(p))

  io.axi.b.ready := false.B
  io.axi.r.ready := false.B

  switch(dSel) {
    is(dSelW) {
      io.axi.b.ready       := io.tl.d.ready
      io.tl.d.valid        := io.axi.b.valid
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
  }
}
