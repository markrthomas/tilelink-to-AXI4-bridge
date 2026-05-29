package tlbridge

import chisel3._
import chisel3.util._

/** TileLink-C → CHI Issue-E bridge (RN-F role).
  *
  *  This is the **Stage 1 skeleton** per `doc/CHI_PLAN.md`: all five TL-C
  *  channels (A + B + C + D + E) and all four CHI channels (REQ + RSP +
  *  DAT + SNP, split into RN-tx and RN-rx halves) are exposed on the
  *  module boundary; every output is tied to a safe default and no
  *  functional behavior is implemented yet.
  *
  *  Subsequent stages (mapping in `doc/DESIGN_SPEC_CHI.md`):
  *    Stage 2 — Read-shared    : AcquireBlock(NtoB) → ReadShared → CompData(SC) → GrantData(toB) → CompAck
  *    Stage 3 — Read-unique    : AcquireBlock(NtoT/BtoT) → ReadUnique / MakeUnique
  *    Stage 4 — Release        : Release / ReleaseData → WriteBackFull / WriteCleanFull / Evict
  *    Stage 5 — Snoop          : SnpShared / SnpUnique → Probe → ProbeAck(Data) → SnpResp(Data)
  *    Stage 6 — Atomics + CMO  : ArithmeticData / LogicalData → AtomicStore / AtomicLoad
  *    Stage 7 — Verification parity + CI
  *
  *  Coherence-state mapping (Stage 1 contract):
  *    TL-C N ≡ CHI I
  *    TL-C B ≡ CHI SC  (shared dirty SD is collapsed to clean on grant)
  *    TL-C T ≡ CHI UC or UD
  *
  *  Pinned for Stage 1: DCT/DMT off, 64 B line, single-line atomics,
  *  64-bit data path, MTE sidebands tied to 0.
  */
class TLCToCHI(val chip: CHIBridgeParams = CHIBridgeParams()) extends Module {
  // Derive matching TL-side params from CHI params so the TL bundles
  // align with the CHI address / data widths.
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

  // ----------------------------------------------------------------------
  // TL slave-side outputs.  Accept nothing (a.ready=0, c.ready=0,
  // e.ready=0), produce nothing (b.valid=0, d.valid=0).
  // ----------------------------------------------------------------------
  io.tl.a.ready := false.B
  io.tl.b.valid := false.B
  io.tl.b.bits  := 0.U.asTypeOf(new TLBChannel(tlp))
  io.tl.c.ready := false.B
  io.tl.d.valid := false.B
  io.tl.d.bits  := 0.U.asTypeOf(new TLDChannel(tlp))
  io.tl.e.ready := false.B

  // ----------------------------------------------------------------------
  // CHI tx (RN → HN) outputs.  Emit nothing.
  // ----------------------------------------------------------------------
  io.chi.txreq.valid := false.B
  io.chi.txreq.bits  := 0.U.asTypeOf(new CHIReq(chip))
  io.chi.txrsp.valid := false.B
  io.chi.txrsp.bits  := 0.U.asTypeOf(new CHIRsp(chip))
  io.chi.txdat.valid := false.B
  io.chi.txdat.bits  := 0.U.asTypeOf(new CHIDat(chip))

  // ----------------------------------------------------------------------
  // CHI rx (HN → RN) acceptance.  Accept nothing.
  // ----------------------------------------------------------------------
  io.chi.rxrsp.ready := false.B
  io.chi.rxdat.ready := false.B
  io.chi.rxsnp.ready := false.B
}
