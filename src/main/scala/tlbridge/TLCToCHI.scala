package tlbridge

import chisel3._
import chisel3.util._

/** TileLink-C → CHI Issue-E bridge (RN-F role).
  *
  *  This is the **Stage 2** implementation: supports the Read-shared path
  *  enabling cold cache-line acquisitions (AcquireBlock NtoB).
  *
  *  Subsequent stages (mapping in `doc/DESIGN_SPEC_CHI.md`):
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
  *  Pinned for Stage 1/2: DCT/DMT off, 64 B line, single-line atomics,
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
  // ACQUIRE ENGINE (Stage 2: AcquireBlock NtoB)
  // ----------------------------------------------------------------------
  val sAcqIdle :: sAcqREQ :: sAcqDAT :: sAcqAck :: sAcqCompAck :: Nil = Enum(5)
  val acqState  = RegInit(sAcqIdle)
  val acqSource = RegInit(0.U(chip.sourceBits.W))
  val acqSize   = RegInit(0.U(chip.sizeBits.W))
  val acqAddr   = RegInit(0.U(chip.addrBits.W))
  val acqBeats  = RegInit(0.U((chip.sizeBits + 1).W))

  val isAcqBlock = io.tl.a.bits.opcode === TLOpcode.AcquireBlock
  val isNtoB     = io.tl.a.bits.param  === TLParam.NtoB

  // beats = max(1, (1 << a_size) / beatBytes)
  val aBeats = Mux(io.tl.a.bits.size <= chip.beatBytesLg.U, 1.U,
                   1.U << (io.tl.a.bits.size - chip.beatBytesLg.U))

  // ---- A-channel acceptance ----
  io.tl.a.ready := (acqState === sAcqIdle) && isAcqBlock && isNtoB

  when(io.tl.a.fire) {
    acqSource := io.tl.a.bits.source
    acqSize   := io.tl.a.bits.size
    acqAddr   := io.tl.a.bits.address
    acqBeats  := aBeats
    acqState  := sAcqREQ
  }

  // ---- CHI txreq ----
  io.chi.txreq.valid := (acqState === sAcqREQ)
  io.chi.txreq.bits  := 0.U.asTypeOf(new CHIReq(chip))
  io.chi.txreq.bits.opcode     := CHIOpcode.ReadShared
  io.chi.txreq.bits.addr       := acqAddr
  io.chi.txreq.bits.txnID      := acqSource.pad(chip.txnIDBits)
  io.chi.txreq.bits.size       := acqSize(2,0) // CHI size is 3 bits
  io.chi.txreq.bits.expCompAck := true.B
  io.chi.txreq.bits.snpAttr    := true.B
  io.chi.txreq.bits.memAttr    := 0.U // NormalNC
  
  when(io.chi.txreq.fire) {
    acqState := sAcqDAT
  }

  // ---- CHI rxdat / TL D-channel ----
  // Match txnID to acqSource.
  val datMatch = io.chi.rxdat.valid && (io.chi.rxdat.bits.txnID === acqSource.pad(chip.txnIDBits))
  
  io.tl.d.valid := (acqState === sAcqDAT) && datMatch
  io.tl.d.bits  := 0.U.asTypeOf(new TLDChannel(tlp))
  io.tl.d.bits.opcode  := TLOpcode.GrantData
  io.tl.d.bits.source  := acqSource
  io.tl.d.bits.size    := acqSize
  io.tl.d.bits.data    := io.chi.rxdat.bits.data
  io.tl.d.bits.param   := TLParam.toB
  io.tl.d.bits.denied  := io.chi.rxdat.bits.respErr(1)
  io.tl.d.bits.corrupt := io.chi.rxdat.bits.respErr(1)

  io.chi.rxdat.ready := (acqState === sAcqDAT) && io.tl.d.ready

  when(io.tl.d.fire) {
    acqBeats := acqBeats - 1.U
    when(acqBeats === 1.U) {
      acqState := sAcqAck
    }
  }

  // ---- TL E-channel (GrantAck) ----
  io.tl.e.ready := (acqState === sAcqAck)
  when(io.tl.e.fire) {
    acqState := sAcqCompAck
  }

  // ---- CHI txrsp (CompAck) ----
  io.chi.txrsp.valid := (acqState === sAcqCompAck)
  io.chi.txrsp.bits  := 0.U.asTypeOf(new CHIRsp(chip))
  io.chi.txrsp.bits.opcode := CHIOpcode.CompAck
  io.chi.txrsp.bits.txnID  := acqSource.pad(chip.txnIDBits)
  
  when(io.chi.txrsp.fire) {
    acqState := sAcqIdle
  }

  // ----------------------------------------------------------------------
  // TL slave-side defaults for unused channels.
  // ----------------------------------------------------------------------
  io.tl.b.valid := false.B
  io.tl.b.bits  := 0.U.asTypeOf(new TLBChannel(tlp))
  io.tl.c.ready := false.B

  // ----------------------------------------------------------------------
  // CHI tx / rx defaults for unused channels.
  // ----------------------------------------------------------------------
  io.chi.txdat.valid := false.B
  io.chi.txdat.bits  := 0.U.asTypeOf(new CHIDat(chip))

  io.chi.rxrsp.ready := false.B
  io.chi.rxsnp.ready := false.B
}
