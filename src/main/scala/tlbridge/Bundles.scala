package tlbridge

import chisel3._
import chisel3.util._

case class BridgeParams(
  addrBits:   Int = 32,
  dataBits:   Int = 64,
  sourceBits: Int = 4,
  idBits:     Int = 4,
  sizeBits:   Int = 6   // log2 of max single-transaction bytes
) {
  require(isPow2(dataBits) && dataBits >= 8, "dataBits must be power of two and >= 8")
  require(addrBits   > 0)
  require(sourceBits > 0)
  require(idBits     >= sourceBits)
  require(sizeBits   > 0)

  val beatBytes:  Int = dataBits / 8
  val strbBits:   Int = beatBytes
  val lenBits:    Int = 8
  val sizeFld:    Int = 3
  val burstBits:  Int = 2
  val respBits:   Int = 2
  val cacheBits:  Int = 4
  val protBits:   Int = 3
  val lockBits:   Int = 1
  val qosBits:    Int = 4
  val regionBits: Int = 4
  val beatSizeLg: Int = log2Ceil(beatBytes)
}

// ---------------------------------------------------------------------------
// TileLink-UH (non-coherent) — bridge is the SLAVE
//   Channel A : master -> slave (requests)
//   Channel D : slave  -> master (responses)
// ---------------------------------------------------------------------------
class TLAChannel(p: BridgeParams) extends Bundle {
  val opcode  = UInt(3.W)
  val param   = UInt(3.W)
  val size    = UInt(p.sizeBits.W)
  val source  = UInt(p.sourceBits.W)
  val address = UInt(p.addrBits.W)
  val mask    = UInt(p.strbBits.W)
  val data    = UInt(p.dataBits.W)
  val corrupt = Bool()
}

class TLDChannel(p: BridgeParams) extends Bundle {
  val opcode  = UInt(3.W)
  val param   = UInt(3.W)
  val size    = UInt(p.sizeBits.W)
  val source  = UInt(p.sourceBits.W)
  val sink    = UInt(1.W)
  val denied  = Bool()
  val data    = UInt(p.dataBits.W)
  val corrupt = Bool()
}

class TLSlaveIO(p: BridgeParams) extends Bundle {
  val a = Flipped(Decoupled(new TLAChannel(p)))
  val d = Decoupled(new TLDChannel(p))
}

// ---------------------------------------------------------------------------
// TileLink-C (cached) extension channels — used by the TLUCToAXI4 variant.
//
//   B (slave -> master) : probes.  This bridge never issues probes; the
//                         channel is exposed for protocol-shape parity and
//                         tied off at module level.
//   C (master -> slave) : releases (voluntary writeback) and probe-acks.
//                         Without probes the bridge only ever sees Release
//                         and ReleaseData on C.
//   E (master -> slave) : grant-acks completing an Acquire flow.
//
// The bundle field widths mirror the A/D channels so a TL-C master can
// reuse the same router/MUX widths across the bridge boundary.
// ---------------------------------------------------------------------------
class TLBChannel(p: BridgeParams) extends Bundle {
  val opcode  = UInt(3.W)
  val param   = UInt(3.W)
  val size    = UInt(p.sizeBits.W)
  val source  = UInt(p.sourceBits.W)
  val address = UInt(p.addrBits.W)
  val mask    = UInt(p.strbBits.W)
  val data    = UInt(p.dataBits.W)
  val corrupt = Bool()
}

class TLCChannel(p: BridgeParams) extends Bundle {
  val opcode  = UInt(3.W)
  val param   = UInt(3.W)
  val size    = UInt(p.sizeBits.W)
  val source  = UInt(p.sourceBits.W)
  val address = UInt(p.addrBits.W)
  val data    = UInt(p.dataBits.W)
  val corrupt = Bool()
}

class TLEChannel(p: BridgeParams) extends Bundle {
  // Sink width matches the bridge's D.sink (single-bit for one acquire slot).
  val sink = UInt(1.W)
}

class TLUCSlaveIO(p: BridgeParams) extends Bundle {
  val a = Flipped(Decoupled(new TLAChannel(p)))
  val b = Decoupled(new TLBChannel(p))
  val c = Flipped(Decoupled(new TLCChannel(p)))
  val d = Decoupled(new TLDChannel(p))
  val e = Flipped(Decoupled(new TLEChannel(p)))
}

// ---------------------------------------------------------------------------
// AXI4 — bridge is the MASTER
// ---------------------------------------------------------------------------
class AxiAddr(p: BridgeParams) extends Bundle {
  val id     = UInt(p.idBits.W)
  val addr   = UInt(p.addrBits.W)
  val len    = UInt(p.lenBits.W)
  val size   = UInt(p.sizeFld.W)
  val burst  = UInt(p.burstBits.W)
  val lock   = UInt(p.lockBits.W)
  val cache  = UInt(p.cacheBits.W)
  val prot   = UInt(p.protBits.W)
  val qos    = UInt(p.qosBits.W)
  val region = UInt(p.regionBits.W)
}

class AxiW(p: BridgeParams) extends Bundle {
  val data = UInt(p.dataBits.W)
  val strb = UInt(p.strbBits.W)
  val last = Bool()
}

class AxiB(p: BridgeParams) extends Bundle {
  val id   = UInt(p.idBits.W)
  val resp = UInt(p.respBits.W)
}

class AxiR(p: BridgeParams) extends Bundle {
  val id   = UInt(p.idBits.W)
  val data = UInt(p.dataBits.W)
  val resp = UInt(p.respBits.W)
  val last = Bool()
}

class AxiMasterIO(p: BridgeParams) extends Bundle {
  val aw = Decoupled(new AxiAddr(p))
  val w  = Decoupled(new AxiW(p))
  val b  = Flipped(Decoupled(new AxiB(p)))
  val ar = Decoupled(new AxiAddr(p))
  val r  = Flipped(Decoupled(new AxiR(p)))
}

object TLOpcode {
  // A channel
  val PutFullData    = 0.U(3.W)
  val PutPartialData = 1.U(3.W)
  val ArithmeticData = 2.U(3.W)
  val LogicalData    = 3.U(3.W)
  val Get            = 4.U(3.W)
  val Hint           = 5.U(3.W)
  val AcquireBlock   = 6.U(3.W)   // TL-C: data + permission
  val AcquirePerm    = 7.U(3.W)   // TL-C: permission only

  // B channel (slave -> master)
  val Probe          = 6.U(3.W)

  // C channel (master -> slave)
  val ProbeAck       = 4.U(3.W)
  val ProbeAckData   = 5.U(3.W)
  val Release        = 6.U(3.W)
  val ReleaseData    = 7.U(3.W)

  // D channel
  val AccessAck      = 0.U(3.W)
  val AccessAckData  = 1.U(3.W)
  val HintAck        = 2.U(3.W)
  val Grant          = 4.U(3.W)   // TL-C: permission only
  val GrantData      = 5.U(3.W)   // TL-C: data + permission
  val ReleaseAck     = 6.U(3.W)
}

object TLParam {
  // A-channel Acquire param: cap requested.
  val NtoB = 0.U(3.W)
  val NtoT = 1.U(3.W)
  val BtoT = 2.U(3.W)

  // C-channel Release / ProbeAck param: permission shrink.
  val TtoB = 0.U(3.W)
  val TtoN = 1.U(3.W)
  val BtoN = 2.U(3.W)
  val TtoT = 3.U(3.W)  // no-change report on probe
  val BtoB = 4.U(3.W)
  val NtoN = 5.U(3.W)

  // D-channel Grant / GrantData param: granted cap.
  val toT  = 0.U(3.W)
  val toB  = 1.U(3.W)
  val toN  = 2.U(3.W)
}

object AxiBurst {
  val FIXED = 0.U(2.W)
  val INCR  = 1.U(2.W)
  val WRAP  = 2.U(2.W)
}
