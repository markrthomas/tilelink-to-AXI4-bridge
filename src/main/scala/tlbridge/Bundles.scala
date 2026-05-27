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
  val Get            = 4.U(3.W)
  val Hint           = 5.U(3.W)
  // D channel
  val AccessAck      = 0.U(3.W)
  val AccessAckData  = 1.U(3.W)
  val HintAck        = 2.U(3.W)
}

object AxiBurst {
  val FIXED = 0.U(2.W)
  val INCR  = 1.U(2.W)
  val WRAP  = 2.U(2.W)
}
