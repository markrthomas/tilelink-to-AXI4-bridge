package tlbridge

import chisel3._
import chisel3.util._

/** Parameters for the TL-C → CHI bridge.
  *
  *  CHI Issue-E baseline.  The bridge always plays the **Request Node**
  *  (RN-F, fully coherent) role; the downstream is a Home Node fronting
  *  memory.
  *
  *  Stage 1 pinned values (see `doc/CHI_PLAN.md` §2):
  *   - DCT / DMT advertised as **off**; revisit at Stage 5
  *   - Cache line pinned at 64 B (CHI Issue-E RN-F baseline)
  *   - Atomic ops constrained to single cache line
  *   - 64-bit data path, matching the existing two bridges
  *   - MTE (memory tagging) sidebands present but tied to 0
  */
case class CHIBridgeParams(
  addrBits:   Int = 48,
  dataBits:   Int = 64,
  lineBytes:  Int = 64,
  txnIDBits:  Int = 8,
  nodeIDBits: Int = 7,
  sourceBits: Int = 4,   // TL-C side
  sizeBits:   Int = 6,   // TL-C side, log2(transaction bytes)
) {
  require(dataBits == 64, "CHI Issue-E RN-F baseline is 64-bit data")
  require(lineBytes == 64, "Stage 1 pins lineBytes at 64")
  require(addrBits >= 32 && addrBits <= 52, "CHI Issue-E addr range")
  require(txnIDBits >= 4 && txnIDBits <= 12)

  val beatBytes:    Int = dataBits / 8                // 8
  val beatBytesLg:  Int = log2Ceil(beatBytes)         // 3
  val beatsPerLine: Int = lineBytes / beatBytes       // 8
  val strbBits:     Int = beatBytes                   // 8
  val dataIDBits:   Int = log2Ceil(beatsPerLine).max(2)  // 3
  val sizeFld:      Int = 3                           // CHI 3-bit size code

  // CHI sideband widths.  Issue-E specifies these; we keep them parametric
  // for forward compatibility but Stage 1 doesn't drive most of them.
  val qosBits:     Int = 4
  val memAttrBits: Int = 4
  val respErrBits: Int = 2
  val respBits:    Int = 3   // resp[2:0] cache state + perm
  val orderBits:   Int = 2
  val reqOpcodeBits: Int = 7
  val rspOpcodeBits: Int = 5
  val datOpcodeBits: Int = 4
  val snpOpcodeBits: Int = 5
  val dbIDBits:    Int = txnIDBits
  val lpidBits:    Int = 5
  val pCrdBits:    Int = 4
  val tagOpBits:   Int = 2
  val cBusyBits:   Int = 3

  // MTE / RAS sideband — width tracking only; Stage 1 ties to 0.  Use a
  // floor of 1 bit so Chisel doesn't reject zero-width signals at narrow
  // beat sizes.
  val tagBits:     Int = ((beatBytes / 4) max 1)  // 4 bits tag per 16-byte granule
  val tuBits:      Int = ((beatBytes / 16) max 1) // tag-update bit per granule
  val dataCheckBits: Int = beatBytes
  val poisonBits:  Int = ((beatBytes / 8) max 1)  // 1 bit per 64-bit lane
}

// ---------------------------------------------------------------------------
// CHI opcode constants — Issue-E values.
//
// Only the opcodes Stages 2–6 will need are enumerated here; the spec has
// many more (DVM, persistent CMO, MTE-specific, stash) that we add as
// later stages bring them in.
// ---------------------------------------------------------------------------
object CHIOpcode {
  // REQ (7-bit opcode space).
  val ReqLCrdReturn  = 0x00.U(7.W)
  val ReadShared     = 0x01.U(7.W)
  val ReadClean      = 0x02.U(7.W)
  val ReadOnce       = 0x03.U(7.W)
  val ReadNoSnp      = 0x04.U(7.W)
  val PCrdReturn     = 0x05.U(7.W)
  val ReadUnique     = 0x07.U(7.W)
  val CleanShared    = 0x08.U(7.W)
  val CleanInvalid   = 0x09.U(7.W)
  val MakeInvalid    = 0x0A.U(7.W)
  val CleanUnique    = 0x0B.U(7.W)
  val MakeUnique     = 0x0C.U(7.W)
  val Evict          = 0x0D.U(7.W)
  val WriteEvictFull = 0x18.U(7.W)
  val WriteCleanFull = 0x19.U(7.W)
  val WriteUniquePtl = 0x1A.U(7.W)
  val WriteUniqueFull= 0x1B.U(7.W)
  val WriteBackPtl   = 0x1C.U(7.W)
  val WriteBackFull  = 0x1D.U(7.W)
  val WriteNoSnpPtl  = 0x1E.U(7.W)
  val WriteNoSnpFull = 0x1F.U(7.W)

  // RSP (5-bit opcode space).
  val RspLCrdReturn  = 0x00.U(5.W)
  val SnpResp        = 0x01.U(5.W)
  val CompAck        = 0x02.U(5.W)
  val RetryAck       = 0x03.U(5.W)
  val Comp           = 0x04.U(5.W)
  val CompDBIDResp   = 0x05.U(5.W)
  val DBIDResp       = 0x06.U(5.W)
  val PCrdGrant      = 0x07.U(5.W)
  val ReadReceipt    = 0x08.U(5.W)
  val SnpRespFwded   = 0x09.U(5.W)
  val RespSepData    = 0x0B.U(5.W)

  // DAT (4-bit opcode space).
  val DatLCrdReturn      = 0x00.U(4.W)
  val SnpRespData        = 0x01.U(4.W)
  val CopyBackWrData     = 0x02.U(4.W)
  val NonCopyBackWrData  = 0x03.U(4.W)
  val CompData           = 0x04.U(4.W)
  val SnpRespDataPtl     = 0x05.U(4.W)
  val SnpRespDataFwded   = 0x06.U(4.W)
  val WriteDataCancel    = 0x07.U(4.W)
  val DataSepResp        = 0x0B.U(4.W)
  val NCBWrDataCompAck   = 0x0C.U(4.W)

  // SNP (5-bit opcode space).
  val SnpLCrdReturn      = 0x00.U(5.W)
  val SnpShared          = 0x01.U(5.W)
  val SnpClean           = 0x02.U(5.W)
  val SnpOnce            = 0x03.U(5.W)
  val SnpNotSharedDirty  = 0x04.U(5.W)
  val SnpUniqueStash     = 0x05.U(5.W)
  val SnpMakeInvalidStash= 0x06.U(5.W)
  val SnpUnique          = 0x07.U(5.W)
  val SnpCleanShared     = 0x08.U(5.W)
  val SnpCleanInvalid    = 0x09.U(5.W)
  val SnpMakeInvalid     = 0x0A.U(5.W)
}

/** CHI cache-state codes for DAT.resp / RSP.resp (Issue-E §B2).
  *
  *  PassDirty (bit[2]) distinguishes UC vs UD and SC vs SD.
  */
object CHIResp {
  val I  = 0x0.U(3.W)   // Invalid
  val SC = 0x1.U(3.W)   // Shared Clean
  val UC = 0x2.U(3.W)   // Unique Clean
  val UD = 0x6.U(3.W)   // Unique Dirty (UC + PassDirty)
  val SD = 0x5.U(3.W)   // Shared Dirty (SC + PassDirty)
}

// ---------------------------------------------------------------------------
// CHI REQ channel — RN → HN.  Read/write/atomic requests, prefetches, CMOs.
// ---------------------------------------------------------------------------
class CHIReq(p: CHIBridgeParams) extends Bundle {
  val qos         = UInt(p.qosBits.W)
  val tgtID       = UInt(p.nodeIDBits.W)
  val srcID       = UInt(p.nodeIDBits.W)
  val txnID       = UInt(p.txnIDBits.W)
  val returnNID   = UInt(p.nodeIDBits.W)
  val returnTxnID = UInt(p.txnIDBits.W)
  val opcode      = UInt(p.reqOpcodeBits.W)
  val size        = UInt(p.sizeFld.W)
  val addr        = UInt(p.addrBits.W)
  val ns          = Bool()
  val likelyShared= Bool()
  val allowRetry  = Bool()
  val order       = UInt(p.orderBits.W)
  val pCrdType    = UInt(p.pCrdBits.W)
  val memAttr     = UInt(p.memAttrBits.W)
  val snpAttr     = Bool()
  val lpID        = UInt(p.lpidBits.W)
  val excl        = Bool()
  val expCompAck  = Bool()
  val traceTag    = Bool()
}

// ---------------------------------------------------------------------------
// CHI RSP channel.  Physically one channel; logically carries both
// directions.  HN→RN: Comp, CompDBIDResp, RetryAck, ...
//                   RN→HN: CompAck, SnpResp (snoop response w/o data)
// ---------------------------------------------------------------------------
class CHIRsp(p: CHIBridgeParams) extends Bundle {
  val qos       = UInt(p.qosBits.W)
  val tgtID     = UInt(p.nodeIDBits.W)
  val srcID     = UInt(p.nodeIDBits.W)
  val txnID     = UInt(p.txnIDBits.W)
  val opcode    = UInt(p.rspOpcodeBits.W)
  val respErr   = UInt(p.respErrBits.W)
  val resp      = UInt(p.respBits.W)
  val fwdState  = UInt(p.respBits.W)
  val cBusy     = UInt(p.cBusyBits.W)
  val dbID      = UInt(p.dbIDBits.W)
  val pCrdType  = UInt(p.pCrdBits.W)
  val traceTag  = Bool()
}

// ---------------------------------------------------------------------------
// CHI DAT channel.  Carries data + state metadata.
// ---------------------------------------------------------------------------
class CHIDat(p: CHIBridgeParams) extends Bundle {
  val qos       = UInt(p.qosBits.W)
  val tgtID     = UInt(p.nodeIDBits.W)
  val srcID     = UInt(p.nodeIDBits.W)
  val txnID     = UInt(p.txnIDBits.W)
  val homeNID   = UInt(p.nodeIDBits.W)
  val opcode    = UInt(p.datOpcodeBits.W)
  val respErr   = UInt(p.respErrBits.W)
  val resp      = UInt(p.respBits.W)
  val fwdState  = UInt(p.respBits.W)
  val cBusy     = UInt(p.cBusyBits.W)
  val dbID      = UInt(p.dbIDBits.W)
  val ccID      = UInt(2.W)
  val dataID    = UInt(p.dataIDBits.W)
  val tagOp     = UInt(p.tagOpBits.W)
  val tag       = UInt(p.tagBits.W)
  val tu        = UInt(p.tuBits.W)
  val be        = UInt(p.strbBits.W)
  val data      = UInt(p.dataBits.W)
  val dataCheck = UInt(p.dataCheckBits.W)
  val poison    = UInt(p.poisonBits.W)
  val traceTag  = Bool()
}

// ---------------------------------------------------------------------------
// CHI SNP channel — HN → RN snoops.  Snoop address is line-aligned
// (CHI carries addr[N:3], the low 3 bits implicit zero).
// ---------------------------------------------------------------------------
class CHISnp(p: CHIBridgeParams) extends Bundle {
  val qos         = UInt(p.qosBits.W)
  val srcID       = UInt(p.nodeIDBits.W)
  val txnID       = UInt(p.txnIDBits.W)
  val fwdNID      = UInt(p.nodeIDBits.W)
  val fwdTxnID    = UInt(p.txnIDBits.W)
  val opcode      = UInt(p.snpOpcodeBits.W)
  val addr        = UInt((p.addrBits - 3).W)
  val ns          = Bool()
  val doNotGoToSD = Bool()
  val retToSrc    = Bool()
  val traceTag    = Bool()
}

/** CHI RN-F IO bundle.
  *
  *  Four channels with independent valid/ready handshakes.  The RSP and
  *  DAT channels are physically one wire each in CHI but carry both
  *  directions of traffic; in this bundle we expose tx (RN→HN) and
  *  rx (HN→RN) sides as separate Decoupled ports for clean Chisel modeling.
  *
  *    txreq : RN → HN  (read/write/atomic requests)
  *    txrsp : RN → HN  (CompAck, SnpResp)
  *    txdat : RN → HN  (write data, SnpRespData)
  *    rxrsp : HN → RN  (Comp, CompDBIDResp, RetryAck)
  *    rxdat : HN → RN  (CompData, DataSepResp)
  *    rxsnp : HN → RN  (Snp*)
  */
class CHIMasterIO(p: CHIBridgeParams) extends Bundle {
  val txreq = Decoupled(new CHIReq(p))
  val txrsp = Decoupled(new CHIRsp(p))
  val txdat = Decoupled(new CHIDat(p))
  val rxrsp = Flipped(Decoupled(new CHIRsp(p)))
  val rxdat = Flipped(Decoupled(new CHIDat(p)))
  val rxsnp = Flipped(Decoupled(new CHISnp(p)))
}
