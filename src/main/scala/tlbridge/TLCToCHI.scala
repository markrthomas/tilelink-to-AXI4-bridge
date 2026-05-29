package tlbridge

import chisel3._
import chisel3.util._

/** TileLink-C → CHI Issue-E bridge (RN-F role).
  *
  *  Stage 4 implementation: read path (NtoB / NtoT / BtoT / AcquirePerm)
  *  plus release path (Release → Evict, ReleaseData(TtoN) → WriteBackFull,
  *  ReleaseData(TtoB) → WriteCleanFull).  Acquire and release engines
  *  run in parallel, arbitrating the shared CHI REQ and TL D channels
  *  with acquire-first priority.
  *
  *  TxnID allocation keeps the two engines disjoint:
  *    acquire txnID = {1'b0, source}
  *    release txnID = {1'b1, source}
  *  so inbound rxrsp can be routed by txnID[7] without ambiguity even
  *  if the two engines reuse the same TL source ID.
  */
class TLCToCHI(val chip: CHIBridgeParams = CHIBridgeParams()) extends Module {
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

  // =====================================================================
  // ACQUIRE ENGINE — NtoB, NtoT, BtoT, AcquirePerm
  // =====================================================================
  val sAcqIdle :: sAcqREQ :: sAcqDAT :: sAcqRSP :: sAcqAck :: sAcqCompAck :: Nil = Enum(6)
  val acqState     = RegInit(sAcqIdle)
  val acqSource    = RegInit(0.U(chip.sourceBits.W))
  val acqSize      = RegInit(0.U(chip.sizeBits.W))
  val acqAddr      = RegInit(0.U(chip.addrBits.W))
  val acqBeats     = RegInit(0.U((chip.sizeBits + 1).W))
  val acqOp        = RegInit(0.U(chip.reqOpcodeBits.W))
  val acqNeedsData = RegInit(false.B)

  val isAcqBlock = io.tl.a.bits.opcode === TLOpcode.AcquireBlock
  val isAcqPerm  = io.tl.a.bits.opcode === TLOpcode.AcquirePerm
  val isNtoB     = io.tl.a.bits.param  === TLParam.NtoB
  val isNtoT     = io.tl.a.bits.param  === TLParam.NtoT

  val aBeats = Mux(io.tl.a.bits.size <= chip.beatBytesLg.U, 1.U,
                   1.U << (io.tl.a.bits.size - chip.beatBytesLg.U))

  io.tl.a.ready := (acqState === sAcqIdle) && (isAcqBlock || isAcqPerm)

  when(io.tl.a.fire) {
    acqSource := io.tl.a.bits.source
    acqSize   := io.tl.a.bits.size
    acqAddr   := io.tl.a.bits.address
    acqBeats  := aBeats
    acqState  := sAcqREQ
    when(isAcqPerm) {
      acqOp := CHIOpcode.MakeUnique
      acqNeedsData := false.B
    }.elsewhen(isNtoB) {
      acqOp := CHIOpcode.ReadShared
      acqNeedsData := true.B
    }.elsewhen(isNtoT) {
      acqOp := CHIOpcode.ReadUnique
      acqNeedsData := true.B
    }.otherwise {
      // AcquireBlock(BtoT) — permission upgrade, no data
      acqOp := CHIOpcode.MakeUnique
      acqNeedsData := false.B
    }
  }

  val acqTxnID = acqSource.pad(chip.txnIDBits)

  // =====================================================================
  // RELEASE ENGINE — Evict / WriteBackFull / WriteCleanFull
  // =====================================================================
  val sRelIdle :: sRelREQ :: sRelRsp :: sRelDAT :: sRelAck :: Nil = Enum(5)
  val relState   = RegInit(sRelIdle)
  val relSource  = RegInit(0.U(chip.sourceBits.W))
  val relSize    = RegInit(0.U(chip.sizeBits.W))
  val relAddr    = RegInit(0.U(chip.addrBits.W))
  val relBeats   = RegInit(0.U((chip.sizeBits + 1).W))
  val relOp      = RegInit(0.U(chip.reqOpcodeBits.W))
  val relHasData = RegInit(false.B)
  val relDBID    = RegInit(0.U(chip.dbIDBits.W))

  val isRelease     = io.tl.c.bits.opcode === TLOpcode.Release
  val isReleaseData = io.tl.c.bits.opcode === TLOpcode.ReleaseData
  val isReleaseAny  = isRelease || isReleaseData
  val cIsTtoB       = io.tl.c.bits.param === TLParam.TtoB

  val cBeats = Mux(io.tl.c.bits.size <= chip.beatBytesLg.U, 1.U,
                   1.U << (io.tl.c.bits.size - chip.beatBytesLg.U))

  // Latch the snapshot off C-bits while c.valid is high in idle.  C is
  // not fired in idle; the first ReleaseData beat stays asserted by the
  // master until we accept it in sRelDAT.  Release (no data) snapshots
  // and never needs to fire C — see the explicit c.ready term below.
  when(io.tl.c.valid && (relState === sRelIdle) && isReleaseAny) {
    relSource := io.tl.c.bits.source
    relSize   := io.tl.c.bits.size
    relAddr   := io.tl.c.bits.address
    relBeats  := cBeats
    relHasData := isReleaseData
    when(isReleaseData) {
      relOp := Mux(cIsTtoB, CHIOpcode.WriteCleanFull, CHIOpcode.WriteBackFull)
    }.otherwise {
      relOp := CHIOpcode.Evict
    }
    relState := sRelREQ
  }

  val relTxnID = relSource.pad(chip.txnIDBits) | (1.U << (chip.txnIDBits - 1).U)

  // =====================================================================
  // CHI txreq — arbitrated, acquire priority
  // =====================================================================
  val acqWantsREQ = (acqState === sAcqREQ)
  val relWantsREQ = (relState === sRelREQ)

  io.chi.txreq.valid := acqWantsREQ || relWantsREQ
  io.chi.txreq.bits  := 0.U.asTypeOf(new CHIReq(chip))
  when(acqWantsREQ) {
    io.chi.txreq.bits.opcode     := acqOp
    io.chi.txreq.bits.addr       := acqAddr
    io.chi.txreq.bits.txnID      := acqTxnID
    io.chi.txreq.bits.size       := acqSize(2,0)
    io.chi.txreq.bits.expCompAck := true.B
    io.chi.txreq.bits.snpAttr    := true.B
  }.otherwise {
    io.chi.txreq.bits.opcode     := relOp
    io.chi.txreq.bits.addr       := relAddr
    io.chi.txreq.bits.txnID      := relTxnID
    io.chi.txreq.bits.size       := relSize(2,0)
    io.chi.txreq.bits.expCompAck := false.B
    io.chi.txreq.bits.snpAttr    := true.B
  }

  when(io.chi.txreq.fire) {
    when(acqWantsREQ) {
      acqState := Mux(acqNeedsData, sAcqDAT, sAcqRSP)
    }.otherwise {
      relState := sRelRsp
    }
  }

  // =====================================================================
  // CHI rxdat → TL D (acquire data path only)
  // =====================================================================
  val datMatch = io.chi.rxdat.valid && (io.chi.rxdat.bits.txnID === acqTxnID)
  io.chi.rxdat.ready := (acqState === sAcqDAT) && io.tl.d.ready

  // =====================================================================
  // CHI rxrsp — routed by txnID MSB
  //   txnID[N-1] = 0 → acquire (Comp)
  //   txnID[N-1] = 1 → release (Comp / CompDBIDResp)
  // =====================================================================
  val rxrspIsRel  = io.chi.rxrsp.bits.txnID(chip.txnIDBits - 1)
  val rxrspForAcq = io.chi.rxrsp.valid && !rxrspIsRel && (io.chi.rxrsp.bits.txnID === acqTxnID)
  val rxrspForRel = io.chi.rxrsp.valid &&  rxrspIsRel && (io.chi.rxrsp.bits.txnID === relTxnID)

  val acqWantsRsp = (acqState === sAcqRSP) && rxrspForAcq
  val relWantsRsp = (relState === sRelRsp) && rxrspForRel
  io.chi.rxrsp.ready := (acqWantsRsp && io.tl.d.ready) || relWantsRsp

  val respToT = Mux(acqState === sAcqDAT,
                    io.chi.rxdat.bits.resp === CHIResp.UC || io.chi.rxdat.bits.resp === CHIResp.UD,
                    io.chi.rxrsp.bits.resp === CHIResp.UC || io.chi.rxrsp.bits.resp === CHIResp.UD)

  // =====================================================================
  // TL D-channel — acquire (GrantData/Grant) OR release (ReleaseAck)
  // =====================================================================
  val acqWantsD = ((acqState === sAcqDAT) && datMatch) ||
                  ((acqState === sAcqRSP) && rxrspForAcq)
  val relWantsD = (relState === sRelAck)

  io.tl.d.valid := acqWantsD || relWantsD
  io.tl.d.bits  := 0.U.asTypeOf(new TLDChannel(tlp))
  io.tl.d.bits.opcode := Mux(acqWantsD,
                              Mux(acqNeedsData, TLOpcode.GrantData, TLOpcode.Grant),
                              TLOpcode.ReleaseAck)
  io.tl.d.bits.source := Mux(acqWantsD, acqSource, relSource)
  io.tl.d.bits.size   := Mux(acqWantsD, acqSize,   relSize)
  io.tl.d.bits.param  := Mux(acqWantsD, Mux(respToT, TLParam.toT, TLParam.toB), 0.U)
  io.tl.d.bits.data   := io.chi.rxdat.bits.data
  io.tl.d.bits.denied := Mux(acqState === sAcqDAT,
                              io.chi.rxdat.bits.respErr(1),
                              io.chi.rxrsp.bits.respErr(1))
  io.tl.d.bits.corrupt := Mux(acqState === sAcqDAT, io.chi.rxdat.bits.respErr(1), false.B)

  // ---- D-fire effects ----
  when(io.tl.d.fire) {
    when(acqWantsD) {
      when(acqState === sAcqDAT) {
        acqBeats := acqBeats - 1.U
        when(acqBeats === 1.U) { acqState := sAcqAck }
      }.otherwise {
        acqState := sAcqAck
      }
    }.elsewhen(relWantsD) {
      relState := sRelIdle
    }
  }

  // ---- rxrsp fire effects for release engine ----
  when(io.chi.rxrsp.fire && relWantsRsp) {
    relDBID := io.chi.rxrsp.bits.dbID
    when(relHasData) {
      relState := sRelDAT
    }.otherwise {
      relState := sRelAck
    }
  }

  // =====================================================================
  // TL E (GrantAck) — acquire engine
  // =====================================================================
  io.tl.e.ready := (acqState === sAcqAck)
  when(io.tl.e.fire) {
    acqState := sAcqCompAck
  }

  // =====================================================================
  // CHI txrsp (CompAck) — acquire engine
  // =====================================================================
  io.chi.txrsp.valid := (acqState === sAcqCompAck)
  io.chi.txrsp.bits  := 0.U.asTypeOf(new CHIRsp(chip))
  io.chi.txrsp.bits.opcode := CHIOpcode.CompAck
  io.chi.txrsp.bits.txnID  := acqTxnID

  when(io.chi.txrsp.fire) {
    acqState := sAcqIdle
  }

  // =====================================================================
  // CHI txdat (CopyBackWrData) — release engine
  // =====================================================================
  io.chi.txdat.valid := (relState === sRelDAT) && io.tl.c.valid
  io.chi.txdat.bits  := 0.U.asTypeOf(new CHIDat(chip))
  io.chi.txdat.bits.opcode := CHIOpcode.CopyBackWrData
  io.chi.txdat.bits.txnID  := relDBID
  io.chi.txdat.bits.data   := io.tl.c.bits.data
  io.chi.txdat.bits.be     := Fill(chip.strbBits, 1.U(1.W))
  io.chi.txdat.bits.resp   := Mux(relOp === CHIOpcode.WriteCleanFull, CHIResp.SC, CHIResp.I)
  io.chi.txdat.bits.dataID := (relBeats - 1.U)

  // =====================================================================
  // TL C-channel
  //   - In sRelIdle, fire on the single Release (no-data) beat —
  //     snapshot and acknowledge in the same cycle.  ReleaseData beat 0
  //     stays asserted by the master until we reach sRelDAT.
  //   - In sRelDAT, fire each data beat as it forwards to txdat.
  // =====================================================================
  io.tl.c.ready := ((relState === sRelIdle) && io.tl.c.valid && isRelease) ||
                   ((relState === sRelDAT)  && io.chi.txdat.ready)

  when(io.tl.c.fire && relState === sRelDAT) {
    relBeats := relBeats - 1.U
    when(relBeats === 1.U) { relState := sRelAck }
  }

  // =====================================================================
  // Tie-offs — Probe/Snoop unimplemented (Stage 5)
  // =====================================================================
  io.tl.b.valid := false.B
  io.tl.b.bits  := 0.U.asTypeOf(new TLBChannel(tlp))
  io.chi.rxsnp.ready := false.B
}
