package tlbridge

import chisel3._
import chisel3.util._

/** A region of the upstream address space mapped to one AXI subordinate.
  *
  *  `[lo, hi)` — half-open interval.  Regions must be non-overlapping; the
  *  decoder doesn't enforce this at elaboration time, behaviour is
  *  unspecified if they do overlap.
  */
case class DecodeRegion(lo: BigInt, hi: BigInt) {
  require(lo < hi, s"DecodeRegion lo (0x${lo.toString(16)}) must be < hi (0x${hi.toString(16)})")
}

/** Address-decoded TileLink-UH → AXI4 bridge.
  *
  *  Wraps N independent [[TLUHToAXI4]] instances and dispatches inbound
  *  TL-A transactions to the matching subordinate by address.  Each
  *  subordinate has its own AXI master port; the decoder fans A out and
  *  arbitrates D back to the single TL host with a sticky lock so a
  *  multi-beat AccessAckData burst is never interrupted by another
  *  subordinate's response.
  *
  *  ## Assumptions on the upstream master
  *
  *   1. **Per-source ordering across subordinates** is the master's
  *      responsibility.  This decoder does NOT track per-source destination
  *      and will NOT stall a new A whose source has an outstanding
  *      transaction at a different subordinate.  A well-behaved master
  *      should issue a fresh source for each outstanding transaction (which
  *      is the usual convention) and at worst will observe out-of-source-
  *      order D returns from differently-paced subordinates.
  *   2. **No region-crossing bursts.**  A burst must lie entirely within
  *      one [[DecodeRegion]].  Crossing regions is undefined.
  *   3. **Unmapped addresses route to subordinate 0.**  If no region
  *      contains the request address, the request falls through to the
  *      first bridge — whose downstream AXI slave is expected to return
  *      DECERR for the unmapped range, which the bridge propagates as
  *      `denied=1` on D.
  *
  *  ## D-channel arbitration
  *
  *  Fixed priority by bridge index (bridge 0 wins ties), plus a sticky
  *  lock for multi-beat AccessAckData bursts.  The lock engages on the
  *  first beat of a multi-beat read response and releases on the last
  *  beat.  Single-beat responses (AccessAck, HintAck, single-beat Get
  *  or atomic) bypass the lock entirely.
  */
class TLUHToAXI4Decoder(val p: BridgeParams, val regions: Seq[DecodeRegion]) extends Module {
  require(regions.nonEmpty, "Decoder needs at least one region")
  val n = regions.length

  val io = IO(new Bundle {
    val tl  = new TLSlaveIO(p)
    val axi = Vec(n, new AxiMasterIO(p))
  })

  // ----------------------------------------------------------------------
  // Instantiate one TLUHToAXI4 per region; wire its AXI port out.
  // ----------------------------------------------------------------------
  val bridges = Seq.tabulate(n)(_ => Module(new TLUHToAXI4(p)))
  for (i <- 0 until n) {
    io.axi(i) <> bridges(i).io.axi
  }

  // ----------------------------------------------------------------------
  // Address decode — first match wins; falls through to subordinate 0 on
  // miss (see "Unmapped addresses route to subordinate 0" in the scaladoc).
  // ----------------------------------------------------------------------
  val selBits = if (n == 1) 1 else log2Ceil(n)
  val sel = Wire(UInt(selBits.W))
  sel := 0.U
  // Compare in (addrBits + 1) width so `hi == 2^addrBits` (full-space upper
  // bound, e.g., 0x1_0000_0000 on a 32-bit map) fits as a literal.
  val cmpW   = p.addrBits + 1
  val addrEx = Cat(0.U(1.W), io.tl.a.bits.address)
  for (i <- (n - 1) to 0 by -1) {
    val r = regions(i)
    when(addrEx >= r.lo.U(cmpW.W) && addrEx < r.hi.U(cmpW.W)) {
      sel := i.U
    }
  }

  // ----------------------------------------------------------------------
  // A-channel fanout: only the selected bridge sees a.valid; others get 0.
  // ----------------------------------------------------------------------
  for (i <- 0 until n) {
    bridges(i).io.tl.a.valid := io.tl.a.valid && (sel === i.U)
    bridges(i).io.tl.a.bits  := io.tl.a.bits
  }
  io.tl.a.ready := VecInit(bridges.map(_.io.tl.a.ready))(sel)

  // ----------------------------------------------------------------------
  // D-channel arbitration with sticky lock for multi-beat read bursts.
  // ----------------------------------------------------------------------
  val dValids = VecInit(bridges.map(_.io.tl.d.valid))
  val dBitsVec = VecInit(bridges.map(_.io.tl.d.bits))

  val firstValid = PriorityEncoder(dValids)
  val anyValid   = dValids.asUInt.orR

  val locked         = RegInit(false.B)
  val lockedBridge   = RegInit(0.U(selBits.W))
  val lockedBeatsLeft = RegInit(0.U((p.sizeBits + 1).W))

  val dSel = Mux(locked, lockedBridge, firstValid)

  io.tl.d.valid := dValids(dSel)
  io.tl.d.bits  := dBitsVec(dSel)
  for (i <- 0 until n) {
    bridges(i).io.tl.d.ready := io.tl.d.ready && (dSel === i.U)
  }

  // Lock management.  AccessAckData with size > beatSizeLg means the bridge
  // will emit multiple D beats; lock the arbiter to that bridge for the
  // duration so the burst is contiguous.
  val curOpcode = io.tl.d.bits.opcode
  val curSize   = io.tl.d.bits.size
  val isAckData = curOpcode === TLOpcode.AccessAckData
  val totalDBeats = Mux(curSize <= p.beatSizeLg.U, 1.U,
                        1.U << (curSize - p.beatSizeLg.U))

  when(io.tl.d.fire) {
    when(!locked && isAckData && totalDBeats > 1.U) {
      // First beat of a multi-beat AccessAckData burst — engage lock.
      locked          := true.B
      lockedBridge    := dSel
      lockedBeatsLeft := totalDBeats - 1.U
    }.elsewhen(locked) {
      // Inside a locked burst — count down; release on the last beat.
      lockedBeatsLeft := lockedBeatsLeft - 1.U
      when(lockedBeatsLeft === 1.U) {
        locked := false.B
      }
    }
  }
}
