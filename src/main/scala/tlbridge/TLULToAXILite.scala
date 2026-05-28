package tlbridge

import chisel3._
import chisel3.util._

/** Parameters for the TL-UL → AXI4-Lite bridge.
  *
  *  AXI4-Lite restricts data width to 32 or 64 bits and forbids bursts; the
  *  bridge enforces both at elaboration time.  Address width is parametric.
  */
case class ULBridgeParams(
  addrBits:   Int = 32,
  dataBits:   Int = 32,
  sourceBits: Int = 4,
) {
  require(dataBits == 32 || dataBits == 64,
          s"AXI4-Lite permits only 32 or 64-bit data, got $dataBits")
  require(addrBits   > 0)
  require(sourceBits > 0)

  val beatBytes:  Int = dataBits / 8
  val strbBits:   Int = beatBytes
  // sizeBits must hold values 0..log2(beatBytes).  +1 keeps headroom for the
  // size-legality check ("size <= beatSizeLg") to never alias an oversized
  // request to a legal one.
  val beatSizeLg: Int = log2Ceil(beatBytes)
  val sizeBits:   Int = log2Ceil(beatSizeLg + 1).max(1)
  val respBits:   Int = 2
  val protBits:   Int = 3
}

// ---------------------------------------------------------------------------
// TileLink-UL (uncached lightweight) — bridge is the SLAVE.
//   Channel A : master -> slave (requests)
//   Channel D : slave  -> master (responses)
// Same bundle shape as the TLAChannel used by the TL-UH bridge, but the
// width fields are sized off ULBridgeParams (smaller `size` field).
// ---------------------------------------------------------------------------
class TLULAChannel(p: ULBridgeParams) extends Bundle {
  val opcode  = UInt(3.W)
  val param   = UInt(3.W)
  val size    = UInt(p.sizeBits.W)
  val source  = UInt(p.sourceBits.W)
  val address = UInt(p.addrBits.W)
  val mask    = UInt(p.strbBits.W)
  val data    = UInt(p.dataBits.W)
  val corrupt = Bool()
}

class TLULDChannel(p: ULBridgeParams) extends Bundle {
  val opcode  = UInt(3.W)
  val param   = UInt(3.W)
  val size    = UInt(p.sizeBits.W)
  val source  = UInt(p.sourceBits.W)
  val sink    = UInt(1.W)
  val denied  = Bool()
  val data    = UInt(p.dataBits.W)
  val corrupt = Bool()
}

class TLULSlaveIO(p: ULBridgeParams) extends Bundle {
  val a = Flipped(Decoupled(new TLULAChannel(p)))
  val d = Decoupled(new TLULDChannel(p))
}

// ---------------------------------------------------------------------------
// AXI4-Lite — bridge is the MASTER.
//   No ID, len, size, burst, last, lock, cache, qos, or region fields.
//   AXI4-Lite still carries AxPROT (3 bits) and B/R RESP (2 bits).
// ---------------------------------------------------------------------------
class AxiLiteAddr(p: ULBridgeParams) extends Bundle {
  val addr = UInt(p.addrBits.W)
  val prot = UInt(p.protBits.W)
}

class AxiLiteW(p: ULBridgeParams) extends Bundle {
  val data = UInt(p.dataBits.W)
  val strb = UInt(p.strbBits.W)
}

class AxiLiteB(p: ULBridgeParams) extends Bundle {
  val resp = UInt(p.respBits.W)
}

class AxiLiteR(p: ULBridgeParams) extends Bundle {
  val data = UInt(p.dataBits.W)
  val resp = UInt(p.respBits.W)
}

class AxiLiteMasterIO(p: ULBridgeParams) extends Bundle {
  val aw = Decoupled(new AxiLiteAddr(p))
  val w  = Decoupled(new AxiLiteW(p))
  val b  = Flipped(Decoupled(new AxiLiteB(p)))
  val ar = Decoupled(new AxiLiteAddr(p))
  val r  = Flipped(Decoupled(new AxiLiteR(p)))
}

/** TileLink-UL (slave) → AXI4-Lite (master) bridge.
  *
  *  Supported A-channel opcodes: Get, PutFullData, PutPartialData, Hint.
  *  Atomics, region-crossing bursts, and multi-beat transactions are not
  *  part of TL-UL; oversized requests (`a.size > log2(beatBytes)`) and
  *  unsupported opcodes are consumed locally and answered with a denied
  *  AccessAck instead of stalling A.ready forever.
  *
  *  Mapping:
  *    Get             → AR + R       → D = AccessAckData
  *    PutFullData     → AW + W + B   → D = AccessAck      (TL mask → WSTRB)
  *    PutPartialData  → AW + W + B   → D = AccessAck      (TL mask → WSTRB)
  *    Hint            → (none)       → D = HintAck
  *
  *  Three parallel engines (read, write, hint) share the TL-A channel via
  *  opcode-based routing and share the TL-D channel via a fixed-priority
  *  arbiter (W > R > H > E).  Each engine has a single outstanding slot —
  *  enough to overlap a read with a write and a hint.
  *
  *  AW and W are issued concurrently (both `valid` go high together) so a
  *  cooperative AXI-Lite slave can accept them in any order.  WSTRB carries
  *  the TL mask directly; full-beat writes use all-ones.
  */
class TLULToAXILite(val p: ULBridgeParams = ULBridgeParams()) extends Module {
  val io = IO(new Bundle {
    val tl  = new TLULSlaveIO(p)
    val axi = new AxiLiteMasterIO(p)
  })

  // ----------------------------------------------------------------------
  // A-channel opcode decode
  // ----------------------------------------------------------------------
  val isGet  = io.tl.a.bits.opcode === TLOpcode.Get
  val isPut  = (io.tl.a.bits.opcode === TLOpcode.PutFullData) ||
               (io.tl.a.bits.opcode === TLOpcode.PutPartialData)
  val isHint = io.tl.a.bits.opcode === TLOpcode.Hint
  val isSupported = isGet || isPut || isHint
  // TL-UL is single-beat: size must fit in one bus beat.
  val sizeLegal   = io.tl.a.bits.size <= p.beatSizeLg.U
  val isLocalError = !isSupported || !sizeLegal

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

  val rCanAcceptA = (rState === sRIdle)

  // ======================================================================
  // WRITE ENGINE
  // ----------------------------------------------------------------------
  // AW and W are issued in parallel.  awDone/wDone latch the individual
  // handshakes so the slave may accept them in either order.
  // ======================================================================
  val sWIdle :: sWReq :: sWResp :: Nil = Enum(3)
  val wState   = RegInit(sWIdle)
  val wSource  = RegInit(0.U(p.sourceBits.W))
  val wSize    = RegInit(0.U(p.sizeBits.W))
  val wAddr    = RegInit(0.U(p.addrBits.W))
  val wData    = RegInit(0.U(p.dataBits.W))
  val wMask    = RegInit(0.U(p.strbBits.W))
  val awDone   = RegInit(false.B)
  val wDone    = RegInit(false.B)

  val wCanAcceptA = (wState === sWIdle)

  // ======================================================================
  // HINT SLOT (1-deep) — no AXI traffic, answered locally.
  // ======================================================================
  val hPending = RegInit(false.B)
  val hSource  = RegInit(0.U(p.sourceBits.W))
  val hSize    = RegInit(0.U(p.sizeBits.W))

  val hCanAcceptA = !hPending

  // ======================================================================
  // LOCAL ERROR SLOT (1-deep)
  // ----------------------------------------------------------------------
  // Unsupported opcode or oversized request → denied AccessAck.  TL-UL is
  // single-beat by construction, so this slot drains in one A.fire — no
  // burst-drain state needed (unlike the TL-UH bridge).
  // ======================================================================
  val eState   = RegInit(false.B)        // false = idle, true = response pending
  val eSource  = RegInit(0.U(p.sourceBits.W))
  val eSize    = RegInit(0.U(p.sizeBits.W))
  val eCanAcceptA = !eState

  // ======================================================================
  // A-CHANNEL ROUTING — single-beat handshake by opcode.
  // ======================================================================
  io.tl.a.ready := MuxCase(false.B, Seq(
    (isLocalError && eCanAcceptA)         -> true.B,
    (isGet  && sizeLegal && rCanAcceptA)  -> true.B,
    (isPut  && sizeLegal && wCanAcceptA)  -> true.B,
    (isHint && sizeLegal && hCanAcceptA)  -> true.B,
  ))

  when(io.tl.a.fire) {
    when(isLocalError) {
      eSource := io.tl.a.bits.source
      eSize   := io.tl.a.bits.size
      eState  := true.B
    }.elsewhen(isGet) {
      rSource := io.tl.a.bits.source
      rSize   := io.tl.a.bits.size
      rAddr   := io.tl.a.bits.address
      rState  := sRAR
    }.elsewhen(isPut) {
      wSource := io.tl.a.bits.source
      wSize   := io.tl.a.bits.size
      wAddr   := io.tl.a.bits.address
      wData   := io.tl.a.bits.data
      wMask   := io.tl.a.bits.mask
      awDone  := false.B
      wDone   := false.B
      wState  := sWReq
    }.elsewhen(isHint) {
      hSource  := io.tl.a.bits.source
      hSize    := io.tl.a.bits.size
      hPending := true.B
    }
  }

  // ======================================================================
  // AXI4-LITE OUTPUTS
  // ======================================================================
  io.axi.ar.valid     := (rState === sRAR)
  io.axi.ar.bits.addr := alignAddr(rAddr)
  io.axi.ar.bits.prot := 0.U
  when(io.axi.ar.fire) { rState := sRResp }

  io.axi.aw.valid     := (wState === sWReq) && !awDone
  io.axi.aw.bits.addr := alignAddr(wAddr)
  io.axi.aw.bits.prot := 0.U

  io.axi.w.valid      := (wState === sWReq) && !wDone
  io.axi.w.bits.data  := wData
  io.axi.w.bits.strb  := wMask

  when(io.axi.aw.fire) { awDone := true.B }
  when(io.axi.w.fire)  { wDone  := true.B }
  when(wState === sWReq && (awDone || io.axi.aw.fire) && (wDone || io.axi.w.fire)) {
    wState := sWResp
  }

  // ======================================================================
  // D-CHANNEL ARBITER — fixed priority W > R > H > E.
  // No multi-beat bursts in TL-UL, so no sticky burst lock is required.
  // ======================================================================
  val wRespReady = (wState === sWResp) && io.axi.b.valid
  val rRespReady = (rState === sRResp) && io.axi.r.valid
  val eRespReady = eState
  val hRespReady = hPending

  val dSelNone :: dSelW :: dSelR :: dSelH :: dSelE :: Nil = Enum(5)
  val dSel = WireDefault(dSelNone)
  when(wRespReady)      { dSel := dSelW }
  .elsewhen(rRespReady) { dSel := dSelR }
  .elsewhen(hRespReady) { dSel := dSelH }
  .elsewhen(eRespReady) { dSel := dSelE }

  // ---- D-channel defaults ----
  io.tl.d.valid := false.B
  io.tl.d.bits  := 0.U.asTypeOf(new TLULDChannel(p))

  // B/R defaults — only the selected source consumes the AXI response.
  io.axi.b.ready := false.B
  io.axi.r.ready := false.B

  switch(dSel) {
    is(dSelW) {
      io.axi.b.ready       := io.tl.d.ready
      io.tl.d.valid        := true.B
      io.tl.d.bits.opcode  := TLOpcode.AccessAck
      io.tl.d.bits.size    := wSize
      io.tl.d.bits.source  := wSource
      io.tl.d.bits.denied  := (io.axi.b.bits.resp =/= 0.U)
      when(io.tl.d.fire) { wState := sWIdle }
    }
    is(dSelR) {
      io.axi.r.ready       := io.tl.d.ready
      io.tl.d.valid        := true.B
      io.tl.d.bits.opcode  := TLOpcode.AccessAckData
      io.tl.d.bits.size    := rSize
      io.tl.d.bits.source  := rSource
      io.tl.d.bits.denied  := (io.axi.r.bits.resp =/= 0.U)
      io.tl.d.bits.corrupt := io.axi.r.bits.resp(1)
      io.tl.d.bits.data    := io.axi.r.bits.data
      when(io.tl.d.fire) { rState := sRIdle }
    }
    is(dSelH) {
      io.tl.d.valid        := true.B
      io.tl.d.bits.opcode  := TLOpcode.HintAck
      io.tl.d.bits.size    := hSize
      io.tl.d.bits.source  := hSource
      when(io.tl.d.fire) { hPending := false.B }
    }
    is(dSelE) {
      io.tl.d.valid        := true.B
      io.tl.d.bits.opcode  := TLOpcode.AccessAck
      io.tl.d.bits.size    := eSize
      io.tl.d.bits.source  := eSource
      io.tl.d.bits.denied  := true.B
      when(io.tl.d.fire) { eState := false.B }
    }
  }
}
