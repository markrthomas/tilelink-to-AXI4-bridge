package tlbridge

import chisel3._
import chisel3.util._

/** TileLink-UH (slave) → AXI4 (master) bridge.
  *
  *  Supported A-channel opcodes: Get, PutFullData, PutPartialData, Hint
  *  Atomics (ArithmeticData / LogicalData) are not implemented.
  *
  *  Mapping:
  *    Get             → AR + R   → D = AccessAckData
  *    PutFullData     → AW + W   → D = AccessAck
  *    PutPartialData  → AW + W   → D = AccessAck      (TL mask  → AXI WSTRB)
  *    Hint            → (none)   → D = HintAck
  *
  *  One outstanding TL transaction at a time (single-source, in-order).
  *  AXI bursts are always INCR; AxSIZE is fixed at log2(beatBytes), with
  *  WSTRB (writes) handling sub-bus byte enables.
  */
class TLUHToAXI4(val p: BridgeParams = BridgeParams()) extends Module {
  val io = IO(new Bundle {
    val tl  = new TLSlaveIO(p)
    val axi = new AxiMasterIO(p)
  })

  // ---- FSM ----
  val sIdle :: sReadAR :: sReadResp :: sWriteAW :: sWriteData :: sWriteResp :: sHintAck :: Nil =
    Enum(7)
  val state = RegInit(sIdle)

  // ---- Latched request context ----
  val regSource = RegInit(0.U(p.sourceBits.W))
  val regSize   = RegInit(0.U(p.sizeBits.W))
  val regAddr   = RegInit(0.U(p.addrBits.W))
  val regBeats  = RegInit(0.U((p.sizeBits + 1).W)) // beats remaining

  // ---- Beat count derived from incoming A.size ----
  // beats = max(1, (1 << a_size) / beatBytes)
  val aBytes = (1.U << io.tl.a.bits.size).asUInt
  val aBeats = Mux(aBytes <= p.beatBytes.U, 1.U, (aBytes >> p.beatSizeLg.U).asUInt)

  // ---- AXI address must be aligned to beatBytes for AxSIZE = log2(beatBytes) INCR bursts.
  //      Sub-beat positioning is conveyed by WSTRB on writes and recovered from
  //      a_address[beatSizeLg-1:0] by the TL master on reads.
  val regAddrAligned =
    if (p.beatSizeLg == 0) regAddr
    else Cat(regAddr(p.addrBits - 1, p.beatSizeLg), 0.U(p.beatSizeLg.W))

  // ---- Defaults ----
  io.tl.a.ready := false.B

  io.tl.d.valid       := false.B
  io.tl.d.bits        := 0.U.asTypeOf(new TLDChannel(p))
  io.tl.d.bits.source := regSource
  io.tl.d.bits.size   := regSize

  io.axi.aw.valid      := false.B
  io.axi.aw.bits       := 0.U.asTypeOf(new AxiAddr(p))
  io.axi.aw.bits.id    := regSource
  io.axi.aw.bits.addr  := regAddrAligned
  io.axi.aw.bits.len   := (regBeats - 1.U).pad(p.lenBits)
  io.axi.aw.bits.size  := p.beatSizeLg.U
  io.axi.aw.bits.burst := AxiBurst.INCR

  io.axi.w.valid     := false.B
  io.axi.w.bits      := 0.U.asTypeOf(new AxiW(p))

  io.axi.b.ready := false.B

  io.axi.ar.valid      := false.B
  io.axi.ar.bits       := 0.U.asTypeOf(new AxiAddr(p))
  io.axi.ar.bits.id    := regSource
  io.axi.ar.bits.addr  := regAddrAligned
  io.axi.ar.bits.len   := (regBeats - 1.U).pad(p.lenBits)
  io.axi.ar.bits.size  := p.beatSizeLg.U
  io.axi.ar.bits.burst := AxiBurst.INCR

  io.axi.r.ready := false.B

  switch(state) {
    is(sIdle) {
      // Peek the A request; only consume it now for single-beat ops
      // (Get / Hint). For writes, hold a.ready=0 until sWriteData consumes
      // each data beat in step with W.
      val isGet   = io.tl.a.bits.opcode === TLOpcode.Get
      val isHint  = io.tl.a.bits.opcode === TLOpcode.Hint
      val isPut   = (io.tl.a.bits.opcode === TLOpcode.PutFullData) ||
                    (io.tl.a.bits.opcode === TLOpcode.PutPartialData)

      io.tl.a.ready := io.tl.a.valid && (isGet || isHint)

      when(io.tl.a.valid) {
        regSource := io.tl.a.bits.source
        regSize   := io.tl.a.bits.size
        regAddr   := io.tl.a.bits.address
        regBeats  := aBeats
        when(isGet)  { state := sReadAR  }
        when(isPut)  { state := sWriteAW }
        when(isHint) { state := sHintAck }
      }
    }

    // -------- READ --------
    is(sReadAR) {
      io.axi.ar.valid := true.B
      when(io.axi.ar.fire) { state := sReadResp }
    }

    is(sReadResp) {
      // Forward R → D, beat for beat
      io.axi.r.ready       := io.tl.d.ready
      io.tl.d.valid        := io.axi.r.valid
      io.tl.d.bits.opcode  := TLOpcode.AccessAckData
      io.tl.d.bits.param   := 0.U
      io.tl.d.bits.size    := regSize
      io.tl.d.bits.source  := regSource
      io.tl.d.bits.sink    := 0.U
      // RRESP bit 1 distinguishes real errors (SLVERR=10, DECERR=11) from
      // OKAY=00 / EXOKAY=01. denied: any non-OKAY. corrupt: real errors only.
      io.tl.d.bits.denied  := (io.axi.r.bits.resp =/= 0.U)
      io.tl.d.bits.corrupt := io.axi.r.bits.resp(1)
      io.tl.d.bits.data    := io.axi.r.bits.data
      when(io.axi.r.fire && io.axi.r.bits.last) { state := sIdle }
    }

    // -------- WRITE --------
    is(sWriteAW) {
      io.axi.aw.valid := true.B
      when(io.axi.aw.fire) { state := sWriteData }
    }

    is(sWriteData) {
      val last = (regBeats === 1.U)
      // Couple TL-A handshake to AXI-W handshake, beat-for-beat
      io.tl.a.ready      := io.axi.w.ready
      io.axi.w.valid     := io.tl.a.valid
      io.axi.w.bits.data := io.tl.a.bits.data
      io.axi.w.bits.strb := io.tl.a.bits.mask
      io.axi.w.bits.last := last
      when(io.axi.w.fire) {
        regBeats := regBeats - 1.U
        when(last) { state := sWriteResp }
      }
    }

    is(sWriteResp) {
      // Forward B → D when both are ready
      io.axi.b.ready       := io.tl.d.ready
      io.tl.d.valid        := io.axi.b.valid
      io.tl.d.bits.opcode  := TLOpcode.AccessAck
      io.tl.d.bits.param   := 0.U
      io.tl.d.bits.size    := regSize
      io.tl.d.bits.source  := regSource
      io.tl.d.bits.sink    := 0.U
      io.tl.d.bits.denied  := (io.axi.b.bits.resp =/= 0.U)
      io.tl.d.bits.corrupt := false.B
      io.tl.d.bits.data    := 0.U
      when(io.tl.d.fire) { state := sIdle }
    }

    // -------- HINT --------
    is(sHintAck) {
      io.tl.d.valid        := true.B
      io.tl.d.bits.opcode  := TLOpcode.HintAck
      io.tl.d.bits.param   := 0.U
      io.tl.d.bits.size    := regSize
      io.tl.d.bits.source  := regSource
      io.tl.d.bits.sink    := 0.U
      io.tl.d.bits.denied  := false.B
      io.tl.d.bits.corrupt := false.B
      io.tl.d.bits.data    := 0.U
      when(io.tl.d.fire) { state := sIdle }
    }
  }
}
