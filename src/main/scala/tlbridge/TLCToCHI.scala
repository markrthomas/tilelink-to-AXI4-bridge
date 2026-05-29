package tlbridge

import chisel3._
import chisel3.util._

/** TileLink-C → CHI Issue-E bridge (RN-F role).
  *
  *  This is the **Stage 3** implementation: supports Read-shared and
  *  Read-unique paths, enabling cold/warm unique acquisitions and
  *  permission upgrades (AcquireBlock NtoB/NtoT/BtoT and AcquirePerm).
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

  // ----------------------------------------------------------------------
  // ACQUIRE ENGINE (Stage 3: NtoB, NtoT, BtoT, AcquirePerm)
  // ----------------------------------------------------------------------
  val sAcqIdle :: sAcqREQ :: sAcqDAT :: sAcqRSP :: sAcqAck :: sAcqCompAck :: Nil = Enum(6)
  val acqState  = RegInit(sAcqIdle)
  val acqSource = RegInit(0.U(chip.sourceBits.W))
  val acqSize   = RegInit(0.U(chip.sizeBits.W))
  val acqAddr   = RegInit(0.U(chip.addrBits.W))
  val acqBeats  = RegInit(0.U((chip.sizeBits + 1).W))
  val acqOp     = RegInit(0.U(chip.reqOpcodeBits.W))
  val acqNeedsData = RegInit(false.B)

  val isAcqBlock = io.tl.a.bits.opcode === TLOpcode.AcquireBlock
  val isAcqPerm  = io.tl.a.bits.opcode === TLOpcode.AcquirePerm
  val isNtoB     = io.tl.a.bits.param  === TLParam.NtoB
  val isNtoT     = io.tl.a.bits.param  === TLParam.NtoT
  val isBtoT     = io.tl.a.bits.param  === TLParam.BtoT

  val aBeats = Mux(io.tl.a.bits.size <= chip.beatBytesLg.U, 1.U,
                   1.U << (io.tl.a.bits.size - chip.beatBytesLg.U))

  // ---- A-channel acceptance ----
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

  // ---- CHI txreq ----
  io.chi.txreq.valid := (acqState === sAcqREQ)
  io.chi.txreq.bits  := 0.U.asTypeOf(new CHIReq(chip))
  io.chi.txreq.bits.opcode     := acqOp
  io.chi.txreq.bits.addr       := acqAddr
  io.chi.txreq.bits.txnID      := acqSource.pad(chip.txnIDBits)
  io.chi.txreq.bits.size       := acqSize(2,0)
  io.chi.txreq.bits.expCompAck := true.B
  io.chi.txreq.bits.snpAttr    := true.B
  io.chi.txreq.bits.memAttr    := 0.U
  
  when(io.chi.txreq.fire) {
    acqState := Mux(acqNeedsData, sAcqDAT, sAcqRSP)
  }

  // ---- CHI rxdat / rxrsp -> TL D-channel ----
  val datMatch = io.chi.rxdat.valid && (io.chi.rxdat.bits.txnID === acqSource.pad(chip.txnIDBits))
  val rspMatch = io.chi.rxrsp.valid && (io.chi.rxrsp.bits.txnID === acqSource.pad(chip.txnIDBits))
  
  val respToT = Mux(acqState === sAcqDAT,
                    io.chi.rxdat.bits.resp === CHIResp.UC || io.chi.rxdat.bits.resp === CHIResp.UD,
                    io.chi.rxrsp.bits.resp === CHIResp.UC || io.chi.rxrsp.bits.resp === CHIResp.UD)

  io.tl.d.valid := ((acqState === sAcqDAT) && datMatch) ||
                   ((acqState === sAcqRSP) && rspMatch)
  
  io.tl.d.bits := 0.U.asTypeOf(new TLDChannel(tlp))
  io.tl.d.bits.opcode := Mux(acqNeedsData, TLOpcode.GrantData, TLOpcode.Grant)
  io.tl.d.bits.source := acqSource
  io.tl.d.bits.size   := acqSize
  io.tl.d.bits.param  := Mux(respToT, TLParam.toT, TLParam.toB)
  io.tl.d.bits.data   := io.chi.rxdat.bits.data
  io.tl.d.bits.denied := Mux(acqState === sAcqDAT, io.chi.rxdat.bits.respErr(1), io.chi.rxrsp.bits.respErr(1))
  io.tl.d.bits.corrupt := Mux(acqState === sAcqDAT, io.chi.rxdat.bits.respErr(1), false.B)

  when(io.tl.d.fire) {
    when(acqState === sAcqDAT) {
      acqBeats := acqBeats - 1.U
      when(acqBeats === 1.U) { acqState := sAcqAck }
    }.otherwise {
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

  io.tl.b.valid := false.B
  io.tl.b.bits  := 0.U.asTypeOf(new TLBChannel(tlp))
  io.tl.c.ready := false.B
  io.chi.txdat.valid := false.B
  io.chi.txdat.bits  := 0.U.asTypeOf(new CHIDat(chip))

  io.chi.rxdat.ready := (acqState === sAcqDAT) && io.tl.d.ready
  io.chi.rxrsp.ready := (acqState === sAcqRSP) && io.tl.d.ready
  io.chi.rxsnp.ready := false.B
}
