// tlctochi_props.sv — SymbiYosys formal wrapper for TLCToCHI
//
// Stage 5 properties (Read + Release + Snoop paths).
//
//   F-CHI-1  REQ opcode matches the snapshot {opcode, param} at the
//            moment the REQ was queued (A.fire for acquires, first C-beat
//            for releases).
//   F-CHI-2  CompAck txnID equals the TL-A source that initiated the
//            outstanding acquire (only constrains CompAck txrsp).
//   F-CHI-3  D-channel routing: Grant/GrantData carry the acquire
//            snapshot source; ReleaseAck carries the release source.
//   F-CHI-4  CopyBackWrData txdat only fires with a release in flight.
//   F-CHI-5  txnID partition — acquire REQs carry txnID[7]=0, release
//            REQs carry txnID[7]=1.
//   F-CHI-6  Snoop response conservation: SnpResp (txrsp) / SnpRespData
//            (txdat) only fire while a snoop snapshot is live and echo
//            the snoop's txnID.
//   F-CHI-7  No spurious Probe: TL-B is only valid while a snoop is in
//            flight; the Probe address/param match the snoop snapshot.
//   F-CHI-8  Probe/Release race determinism: the snoop and release
//            engines never source a response from state they don't own,
//            and may be simultaneously in flight without collision.  The
//            bridge resolves the race by independent completion (it does
//            not collapse the probe — see TLCToCHI Stage 5 limits).
//
// Cover goals: Grant, GrantData, ReleaseAck, CopyBackWrData, Evict,
// WriteBackFull, Probe issued, SnpResp, SnpRespData, and acquire+release
// vs. snoop simultaneously in flight.

`default_nettype none
`timescale 1ns/1ps

module tlctochi_props (
    input wire clock
);

    reg [2:0] ph;
    initial ph = 3'd0;
    always @(posedge clock) if (ph != 3'd7) ph <= ph + 3'd1;
    wire reset = (ph < 3'd4);

    reg f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge clock) f_past_valid <= 1'b1;
    wire chk = f_past_valid && !reset;

    // -----------------------------------------------------------------
    // Free inputs
    // -----------------------------------------------------------------
    (* anyseq *) wire        io_tl_a_valid;
    (* anyseq *) wire [2:0]  io_tl_a_bits_opcode;
    (* anyseq *) wire [2:0]  io_tl_a_bits_param;
    (* anyseq *) wire [5:0]  io_tl_a_bits_size;
    (* anyseq *) wire [3:0]  io_tl_a_bits_source;
    (* anyseq *) wire [47:0] io_tl_a_bits_address;
    (* anyseq *) wire [7:0]  io_tl_a_bits_mask;
    (* anyseq *) wire [63:0] io_tl_a_bits_data;
    (* anyseq *) wire        io_tl_a_bits_corrupt;
    (* anyseq *) wire        io_tl_b_ready;
    (* anyseq *) wire        io_tl_c_valid;
    (* anyseq *) wire [2:0]  io_tl_c_bits_opcode;
    (* anyseq *) wire [2:0]  io_tl_c_bits_param;
    (* anyseq *) wire [5:0]  io_tl_c_bits_size;
    (* anyseq *) wire [3:0]  io_tl_c_bits_source;
    (* anyseq *) wire [47:0] io_tl_c_bits_address;
    (* anyseq *) wire [63:0] io_tl_c_bits_data;
    (* anyseq *) wire        io_tl_c_bits_corrupt;
    (* anyseq *) wire        io_tl_d_ready;
    (* anyseq *) wire        io_tl_e_valid;
    (* anyseq *) wire        io_tl_e_bits_sink;

    (* anyseq *) wire        io_chi_txreq_ready;
    (* anyseq *) wire        io_chi_txrsp_ready;
    (* anyseq *) wire        io_chi_txdat_ready;

    (* anyseq *) wire        io_chi_rxrsp_valid;
    (* anyseq *) wire [3:0]  io_chi_rxrsp_bits_qos;
    (* anyseq *) wire [6:0]  io_chi_rxrsp_bits_tgtID;
    (* anyseq *) wire [6:0]  io_chi_rxrsp_bits_srcID;
    (* anyseq *) wire [7:0]  io_chi_rxrsp_bits_txnID;
    (* anyseq *) wire [4:0]  io_chi_rxrsp_bits_opcode;
    (* anyseq *) wire [1:0]  io_chi_rxrsp_bits_respErr;
    (* anyseq *) wire [2:0]  io_chi_rxrsp_bits_resp;
    (* anyseq *) wire [2:0]  io_chi_rxrsp_bits_fwdState;
    (* anyseq *) wire [2:0]  io_chi_rxrsp_bits_cBusy;
    (* anyseq *) wire [7:0]  io_chi_rxrsp_bits_dbID;
    (* anyseq *) wire [3:0]  io_chi_rxrsp_bits_pCrdType;
    (* anyseq *) wire        io_chi_rxrsp_bits_traceTag;

    (* anyseq *) wire        io_chi_rxdat_valid;
    (* anyseq *) wire [3:0]  io_chi_rxdat_bits_qos;
    (* anyseq *) wire [6:0]  io_chi_rxdat_bits_tgtID;
    (* anyseq *) wire [6:0]  io_chi_rxdat_bits_srcID;
    (* anyseq *) wire [7:0]  io_chi_rxdat_bits_txnID;
    (* anyseq *) wire [6:0]  io_chi_rxdat_bits_homeNID;
    (* anyseq *) wire [3:0]  io_chi_rxdat_bits_opcode;
    (* anyseq *) wire [1:0]  io_chi_rxdat_bits_respErr;
    (* anyseq *) wire [2:0]  io_chi_rxdat_bits_resp;
    (* anyseq *) wire [2:0]  io_chi_rxdat_bits_fwdState;
    (* anyseq *) wire [2:0]  io_chi_rxdat_bits_cBusy;
    (* anyseq *) wire [7:0]  io_chi_rxdat_bits_dbID;
    (* anyseq *) wire [1:0]  io_chi_rxdat_bits_ccID;
    (* anyseq *) wire [2:0]  io_chi_rxdat_bits_dataID;
    (* anyseq *) wire [1:0]  io_chi_rxdat_bits_tagOp;
    (* anyseq *) wire [1:0]  io_chi_rxdat_bits_tag;
    (* anyseq *) wire        io_chi_rxdat_bits_tu;
    (* anyseq *) wire [7:0]  io_chi_rxdat_bits_be;
    (* anyseq *) wire [63:0] io_chi_rxdat_bits_data;
    (* anyseq *) wire [7:0]  io_chi_rxdat_bits_dataCheck;
    (* anyseq *) wire        io_chi_rxdat_bits_poison;
    (* anyseq *) wire        io_chi_rxdat_bits_traceTag;

    (* anyseq *) wire        io_chi_rxsnp_valid;
    (* anyseq *) wire [3:0]  io_chi_rxsnp_bits_qos;
    (* anyseq *) wire [6:0]  io_chi_rxsnp_bits_srcID;
    (* anyseq *) wire [7:0]  io_chi_rxsnp_bits_txnID;
    (* anyseq *) wire [6:0]  io_chi_rxsnp_bits_fwdNID;
    (* anyseq *) wire [7:0]  io_chi_rxsnp_bits_fwdTxnID;
    (* anyseq *) wire [4:0]  io_chi_rxsnp_bits_opcode;
    (* anyseq *) wire [44:0] io_chi_rxsnp_bits_addr;
    (* anyseq *) wire        io_chi_rxsnp_bits_ns;
    (* anyseq *) wire        io_chi_rxsnp_bits_doNotGoToSD;
    (* anyseq *) wire        io_chi_rxsnp_bits_retToSrc;
    (* anyseq *) wire        io_chi_rxsnp_bits_traceTag;

    // -----------------------------------------------------------------
    // DUT outputs
    // -----------------------------------------------------------------
    wire        io_tl_a_ready;
    wire        io_tl_b_valid;
    wire [2:0]  io_tl_b_bits_opcode;
    wire [2:0]  io_tl_b_bits_param;
    wire [5:0]  io_tl_b_bits_size;
    wire [3:0]  io_tl_b_bits_source;
    wire [47:0] io_tl_b_bits_address;
    wire [7:0]  io_tl_b_bits_mask;
    wire [63:0] io_tl_b_bits_data;
    wire        io_tl_b_bits_corrupt;
    wire        io_tl_c_ready;
    wire        io_tl_d_valid;
    wire [2:0]  io_tl_d_bits_opcode;
    wire [2:0]  io_tl_d_bits_param;
    wire [5:0]  io_tl_d_bits_size;
    wire [3:0]  io_tl_d_bits_source;
    wire        io_tl_d_bits_sink;
    wire        io_tl_d_bits_denied;
    wire [63:0] io_tl_d_bits_data;
    wire        io_tl_d_bits_corrupt;
    wire        io_tl_e_ready;

    wire        io_chi_txreq_valid;
    wire [3:0]  io_chi_txreq_bits_qos;
    wire [6:0]  io_chi_txreq_bits_tgtID;
    wire [6:0]  io_chi_txreq_bits_srcID;
    wire [7:0]  io_chi_txreq_bits_txnID;
    wire [6:0]  io_chi_txreq_bits_returnNID;
    wire [7:0]  io_chi_txreq_bits_returnTxnID;
    wire [6:0]  io_chi_txreq_bits_opcode;
    wire [2:0]  io_chi_txreq_bits_size;
    wire [47:0] io_chi_txreq_bits_addr;
    wire        io_chi_txreq_bits_ns;
    wire        io_chi_txreq_bits_likelyShared;
    wire        io_chi_txreq_bits_allowRetry;
    wire [1:0]  io_chi_txreq_bits_order;
    wire [3:0]  io_chi_txreq_bits_pCrdType;
    wire [3:0]  io_chi_txreq_bits_memAttr;
    wire        io_chi_txreq_bits_snpAttr;
    wire [4:0]  io_chi_txreq_bits_lpID;
    wire        io_chi_txreq_bits_excl;
    wire        io_chi_txreq_bits_expCompAck;
    wire        io_chi_txreq_bits_traceTag;

    wire        io_chi_txrsp_valid;
    wire [3:0]  io_chi_txrsp_bits_qos;
    wire [6:0]  io_chi_txrsp_bits_tgtID;
    wire [6:0]  io_chi_txrsp_bits_srcID;
    wire [7:0]  io_chi_txrsp_bits_txnID;
    wire [4:0]  io_chi_txrsp_bits_opcode;
    wire [1:0]  io_chi_txrsp_bits_respErr;
    wire [2:0]  io_chi_txrsp_bits_resp;
    wire [2:0]  io_chi_txrsp_bits_fwdState;
    wire [2:0]  io_chi_txrsp_bits_cBusy;
    wire [7:0]  io_chi_txrsp_bits_dbID;
    wire [3:0]  io_chi_txrsp_bits_pCrdType;
    wire        io_chi_txrsp_bits_traceTag;

    wire        io_chi_txdat_valid;
    wire [3:0]  io_chi_txdat_bits_qos;
    wire [6:0]  io_chi_txdat_bits_tgtID;
    wire [6:0]  io_chi_txdat_bits_srcID;
    wire [7:0]  io_chi_txdat_bits_txnID;
    wire [6:0]  io_chi_txdat_bits_homeNID;
    wire [3:0]  io_chi_txdat_bits_opcode;
    wire [1:0]  io_chi_txdat_bits_respErr;
    wire [2:0]  io_chi_txdat_bits_resp;
    wire [2:0]  io_chi_txdat_bits_fwdState;
    wire [2:0]  io_chi_txdat_bits_cBusy;
    wire [7:0]  io_chi_txdat_bits_dbID;
    wire [1:0]  io_chi_txdat_bits_ccID;
    wire [2:0]  io_chi_txdat_bits_dataID;
    wire [1:0]  io_chi_txdat_bits_tagOp;
    wire [1:0]  io_chi_txdat_bits_tag;
    wire        io_chi_txdat_bits_tu;
    wire [7:0]  io_chi_txdat_bits_be;
    wire [63:0] io_chi_txdat_bits_data;
    wire [7:0]  io_chi_txdat_bits_dataCheck;
    wire        io_chi_txdat_bits_poison;
    wire        io_chi_txdat_bits_traceTag;

    wire        io_chi_rxrsp_ready;
    wire        io_chi_rxdat_ready;
    wire        io_chi_rxsnp_ready;

    // -----------------------------------------------------------------
    // DUT instance
    // -----------------------------------------------------------------
    TLCToCHI dut (
        .clock(clock), .reset(reset),
        .io_tl_a_ready(io_tl_a_ready),
        .io_tl_a_valid(io_tl_a_valid),
        .io_tl_a_bits_opcode(io_tl_a_bits_opcode),
        .io_tl_a_bits_param(io_tl_a_bits_param),
        .io_tl_a_bits_size(io_tl_a_bits_size),
        .io_tl_a_bits_source(io_tl_a_bits_source),
        .io_tl_a_bits_address(io_tl_a_bits_address),
        .io_tl_a_bits_mask(io_tl_a_bits_mask),
        .io_tl_a_bits_data(io_tl_a_bits_data),
        .io_tl_a_bits_corrupt(io_tl_a_bits_corrupt),
        .io_tl_b_ready(io_tl_b_ready),
        .io_tl_b_valid(io_tl_b_valid),
        .io_tl_b_bits_opcode(io_tl_b_bits_opcode),
        .io_tl_b_bits_param(io_tl_b_bits_param),
        .io_tl_b_bits_size(io_tl_b_bits_size),
        .io_tl_b_bits_source(io_tl_b_bits_source),
        .io_tl_b_bits_address(io_tl_b_bits_address),
        .io_tl_b_bits_mask(io_tl_b_bits_mask),
        .io_tl_b_bits_data(io_tl_b_bits_data),
        .io_tl_b_bits_corrupt(io_tl_b_bits_corrupt),
        .io_tl_c_ready(io_tl_c_ready),
        .io_tl_c_valid(io_tl_c_valid),
        .io_tl_c_bits_opcode(io_tl_c_bits_opcode),
        .io_tl_c_bits_param(io_tl_c_bits_param),
        .io_tl_c_bits_size(io_tl_c_bits_size),
        .io_tl_c_bits_source(io_tl_c_bits_source),
        .io_tl_c_bits_address(io_tl_c_bits_address),
        .io_tl_c_bits_data(io_tl_c_bits_data),
        .io_tl_c_bits_corrupt(io_tl_c_bits_corrupt),
        .io_tl_d_ready(io_tl_d_ready),
        .io_tl_d_valid(io_tl_d_valid),
        .io_tl_d_bits_opcode(io_tl_d_bits_opcode),
        .io_tl_d_bits_param(io_tl_d_bits_param),
        .io_tl_d_bits_size(io_tl_d_bits_size),
        .io_tl_d_bits_source(io_tl_d_bits_source),
        .io_tl_d_bits_sink(io_tl_d_bits_sink),
        .io_tl_d_bits_denied(io_tl_d_bits_denied),
        .io_tl_d_bits_data(io_tl_d_bits_data),
        .io_tl_d_bits_corrupt(io_tl_d_bits_corrupt),
        .io_tl_e_ready(io_tl_e_ready),
        .io_tl_e_valid(io_tl_e_valid),
        .io_tl_e_bits_sink(io_tl_e_bits_sink),
        .io_chi_txreq_ready(io_chi_txreq_ready),
        .io_chi_txreq_valid(io_chi_txreq_valid),
        .io_chi_txreq_bits_qos(io_chi_txreq_bits_qos),
        .io_chi_txreq_bits_tgtID(io_chi_txreq_bits_tgtID),
        .io_chi_txreq_bits_srcID(io_chi_txreq_bits_srcID),
        .io_chi_txreq_bits_txnID(io_chi_txreq_bits_txnID),
        .io_chi_txreq_bits_returnNID(io_chi_txreq_bits_returnNID),
        .io_chi_txreq_bits_returnTxnID(io_chi_txreq_bits_returnTxnID),
        .io_chi_txreq_bits_opcode(io_chi_txreq_bits_opcode),
        .io_chi_txreq_bits_size(io_chi_txreq_bits_size),
        .io_chi_txreq_bits_addr(io_chi_txreq_bits_addr),
        .io_chi_txreq_bits_ns(io_chi_txreq_bits_ns),
        .io_chi_txreq_bits_likelyShared(io_chi_txreq_bits_likelyShared),
        .io_chi_txreq_bits_allowRetry(io_chi_txreq_bits_allowRetry),
        .io_chi_txreq_bits_order(io_chi_txreq_bits_order),
        .io_chi_txreq_bits_pCrdType(io_chi_txreq_bits_pCrdType),
        .io_chi_txreq_bits_memAttr(io_chi_txreq_bits_memAttr),
        .io_chi_txreq_bits_snpAttr(io_chi_txreq_bits_snpAttr),
        .io_chi_txreq_bits_lpID(io_chi_txreq_bits_lpID),
        .io_chi_txreq_bits_excl(io_chi_txreq_bits_excl),
        .io_chi_txreq_bits_expCompAck(io_chi_txreq_bits_expCompAck),
        .io_chi_txreq_bits_traceTag(io_chi_txreq_bits_traceTag),
        .io_chi_txrsp_ready(io_chi_txrsp_ready),
        .io_chi_txrsp_valid(io_chi_txrsp_valid),
        .io_chi_txrsp_bits_qos(io_chi_txrsp_bits_qos),
        .io_chi_txrsp_bits_tgtID(io_chi_txrsp_bits_tgtID),
        .io_chi_txrsp_bits_srcID(io_chi_txrsp_bits_srcID),
        .io_chi_txrsp_bits_txnID(io_chi_txrsp_bits_txnID),
        .io_chi_txrsp_bits_opcode(io_chi_txrsp_bits_opcode),
        .io_chi_txrsp_bits_respErr(io_chi_txrsp_bits_respErr),
        .io_chi_txrsp_bits_resp(io_chi_txrsp_bits_resp),
        .io_chi_txrsp_bits_fwdState(io_chi_txrsp_bits_fwdState),
        .io_chi_txrsp_bits_cBusy(io_chi_txrsp_bits_cBusy),
        .io_chi_txrsp_bits_dbID(io_chi_txrsp_bits_dbID),
        .io_chi_txrsp_bits_pCrdType(io_chi_txrsp_bits_pCrdType),
        .io_chi_txrsp_bits_traceTag(io_chi_txrsp_bits_traceTag),
        .io_chi_txdat_ready(io_chi_txdat_ready),
        .io_chi_txdat_valid(io_chi_txdat_valid),
        .io_chi_txdat_bits_qos(io_chi_txdat_bits_qos),
        .io_chi_txdat_bits_tgtID(io_chi_txdat_bits_tgtID),
        .io_chi_txdat_bits_srcID(io_chi_txdat_bits_srcID),
        .io_chi_txdat_bits_txnID(io_chi_txdat_bits_txnID),
        .io_chi_txdat_bits_homeNID(io_chi_txdat_bits_homeNID),
        .io_chi_txdat_bits_opcode(io_chi_txdat_bits_opcode),
        .io_chi_txdat_bits_respErr(io_chi_txdat_bits_respErr),
        .io_chi_txdat_bits_resp(io_chi_txdat_bits_resp),
        .io_chi_txdat_bits_fwdState(io_chi_txdat_bits_fwdState),
        .io_chi_txdat_bits_cBusy(io_chi_txdat_bits_cBusy),
        .io_chi_txdat_bits_dbID(io_chi_txdat_bits_dbID),
        .io_chi_txdat_bits_ccID(io_chi_txdat_bits_ccID),
        .io_chi_txdat_bits_dataID(io_chi_txdat_bits_dataID),
        .io_chi_txdat_bits_tagOp(io_chi_txdat_bits_tagOp),
        .io_chi_txdat_bits_tag(io_chi_txdat_bits_tag),
        .io_chi_txdat_bits_tu(io_chi_txdat_bits_tu),
        .io_chi_txdat_bits_be(io_chi_txdat_bits_be),
        .io_chi_txdat_bits_data(io_chi_txdat_bits_data),
        .io_chi_txdat_bits_dataCheck(io_chi_txdat_bits_dataCheck),
        .io_chi_txdat_bits_poison(io_chi_txdat_bits_poison),
        .io_chi_txdat_bits_traceTag(io_chi_txdat_bits_traceTag),
        .io_chi_rxrsp_ready(io_chi_rxrsp_ready),
        .io_chi_rxrsp_valid(io_chi_rxrsp_valid),
        .io_chi_rxrsp_bits_qos(io_chi_rxrsp_bits_qos),
        .io_chi_rxrsp_bits_tgtID(io_chi_rxrsp_bits_tgtID),
        .io_chi_rxrsp_bits_srcID(io_chi_rxrsp_bits_srcID),
        .io_chi_rxrsp_bits_txnID(io_chi_rxrsp_bits_txnID),
        .io_chi_rxrsp_bits_opcode(io_chi_rxrsp_bits_opcode),
        .io_chi_rxrsp_bits_respErr(io_chi_rxrsp_bits_respErr),
        .io_chi_rxrsp_bits_resp(io_chi_rxrsp_bits_resp),
        .io_chi_rxrsp_bits_fwdState(io_chi_rxrsp_bits_fwdState),
        .io_chi_rxrsp_bits_cBusy(io_chi_rxrsp_bits_cBusy),
        .io_chi_rxrsp_bits_dbID(io_chi_rxrsp_bits_dbID),
        .io_chi_rxrsp_bits_pCrdType(io_chi_rxrsp_bits_pCrdType),
        .io_chi_rxrsp_bits_traceTag(io_chi_rxrsp_bits_traceTag),
        .io_chi_rxdat_ready(io_chi_rxdat_ready),
        .io_chi_rxdat_valid(io_chi_rxdat_valid),
        .io_chi_rxdat_bits_qos(io_chi_rxdat_bits_qos),
        .io_chi_rxdat_bits_tgtID(io_chi_rxdat_bits_tgtID),
        .io_chi_rxdat_bits_srcID(io_chi_rxdat_bits_srcID),
        .io_chi_rxdat_bits_txnID(io_chi_rxdat_bits_txnID),
        .io_chi_rxdat_bits_homeNID(io_chi_rxdat_bits_homeNID),
        .io_chi_rxdat_bits_opcode(io_chi_rxdat_bits_opcode),
        .io_chi_rxdat_bits_respErr(io_chi_rxdat_bits_respErr),
        .io_chi_rxdat_bits_resp(io_chi_rxdat_bits_resp),
        .io_chi_rxdat_bits_fwdState(io_chi_rxdat_bits_fwdState),
        .io_chi_rxdat_bits_cBusy(io_chi_rxdat_bits_cBusy),
        .io_chi_rxdat_bits_dbID(io_chi_rxdat_bits_dbID),
        .io_chi_rxdat_bits_ccID(io_chi_rxdat_bits_ccID),
        .io_chi_rxdat_bits_dataID(io_chi_rxdat_bits_dataID),
        .io_chi_rxdat_bits_tagOp(io_chi_rxdat_bits_tagOp),
        .io_chi_rxdat_bits_tag(io_chi_rxdat_bits_tag),
        .io_chi_rxdat_bits_tu(io_chi_rxdat_bits_tu),
        .io_chi_rxdat_bits_be(io_chi_rxdat_bits_be),
        .io_chi_rxdat_bits_data(io_chi_rxdat_bits_data),
        .io_chi_rxdat_bits_dataCheck(io_chi_rxdat_bits_dataCheck),
        .io_chi_rxdat_bits_poison(io_chi_rxdat_bits_poison),
        .io_chi_rxdat_bits_traceTag(io_chi_rxdat_bits_traceTag),
        .io_chi_rxsnp_ready(io_chi_rxsnp_ready),
        .io_chi_rxsnp_valid(io_chi_rxsnp_valid),
        .io_chi_rxsnp_bits_qos(io_chi_rxsnp_bits_qos),
        .io_chi_rxsnp_bits_srcID(io_chi_rxsnp_bits_srcID),
        .io_chi_rxsnp_bits_txnID(io_chi_rxsnp_bits_txnID),
        .io_chi_rxsnp_bits_fwdNID(io_chi_rxsnp_bits_fwdNID),
        .io_chi_rxsnp_bits_fwdTxnID(io_chi_rxsnp_bits_fwdTxnID),
        .io_chi_rxsnp_bits_opcode(io_chi_rxsnp_bits_opcode),
        .io_chi_rxsnp_bits_addr(io_chi_rxsnp_bits_addr),
        .io_chi_rxsnp_bits_ns(io_chi_rxsnp_bits_ns),
        .io_chi_rxsnp_bits_doNotGoToSD(io_chi_rxsnp_bits_doNotGoToSD),
        .io_chi_rxsnp_bits_retToSrc(io_chi_rxsnp_bits_retToSrc),
        .io_chi_rxsnp_bits_traceTag(io_chi_rxsnp_bits_traceTag)
    );

    // -----------------------------------------------------------------
    // Assumptions
    // -----------------------------------------------------------------
    //   TL-A opcodes (Stage 6): all eight are legal — acquire (6,7) plus
    //   the uncached engine's Put(0,1)/Arith(2)/Logical(3)/Get(4)/Hint(5).
    //   Acquire params are NtoB/NtoT/BtoT (≤2); uncached/atomic params run
    //   up to 4 (Arithmetic ADD).  Scope A to single-beat transactions
    //   (size ≤ beat): the line-buffer collect path is exercised in sim /
    //   cocotb, and single-beat keeps each A.fire unambiguously owned by
    //   exactly one engine (no mid-burst opcode aliasing for the shadows).
    always @(*) if (io_tl_a_valid) begin
        if      (io_tl_a_bits_opcode >= 3'd6) assume (io_tl_a_bits_param <= 3'd2); // acquire
        else if (io_tl_a_bits_opcode == 3'd3) assume (io_tl_a_bits_param <= 3'd3); // logical
        else                                  assume (io_tl_a_bits_param <= 3'd4); // arith ADD=4
        assume (io_tl_a_bits_size <= 3'd3);
    end
    //   Legal TL-C opcodes: ProbeAck=4, ProbeAckData=5, Release=6,
    //   ReleaseData=7.  Stage 5 adds the probe-response cases.
    always @(*) if (io_tl_c_valid) begin
        assume (io_tl_c_bits_opcode >= 3'd4 && io_tl_c_bits_opcode <= 3'd7);
        assume (io_tl_c_bits_param  <= 3'd2);
    end
    //   Legal CHI snoop opcodes for Stage 5: SnpShared=1, SnpUnique=7,
    //   SnpClean=2, SnpNotSharedDirty=4, SnpCleanInvalid=9, SnpMakeInvalid=10.
    //   Restrict to this set so BMC does not need to reason about
    //   unimplemented opcodes (DVM, SnpOnceFwd, etc).
    always @(*) if (io_chi_rxsnp_valid) begin
        assume (io_chi_rxsnp_bits_opcode == 5'd1  ||
                io_chi_rxsnp_bits_opcode == 5'd2  ||
                io_chi_rxsnp_bits_opcode == 5'd4  ||
                io_chi_rxsnp_bits_opcode == 5'd7  ||
                io_chi_rxsnp_bits_opcode == 5'd9  ||
                io_chi_rxsnp_bits_opcode == 5'd10);
    end
    //   Assume downstream always ready (open-loop bridge view).
    always @(*) assume (io_chi_txreq_ready);
    always @(*) assume (io_chi_txrsp_ready);
    always @(*) assume (io_chi_txdat_ready);
    //   TL master always ready to sink Probes.  Without this assumption
    //   BMC can stall the snoop FSM in sSnpProbe indefinitely.
    always @(*) assume (io_tl_b_ready);

    // -----------------------------------------------------------------
    // Channel handshake wires
    // -----------------------------------------------------------------
    wire a_fire    = io_tl_a_valid    && io_tl_a_ready;
    wire c_fire    = io_tl_c_valid    && io_tl_c_ready;
    wire b_fire    = io_tl_b_valid    && io_tl_b_ready;
    wire req_fire  = io_chi_txreq_valid && io_chi_txreq_ready;
    wire d_fire    = io_tl_d_valid    && io_tl_d_ready;
    wire txrsp_fire= io_chi_txrsp_valid && io_chi_txrsp_ready;
    wire txdat_fire = io_chi_txdat_valid && io_chi_txdat_ready;
    wire snp_fire  = io_chi_rxsnp_valid && io_chi_rxsnp_ready;
    wire e_fire    = io_tl_e_valid    && io_tl_e_ready;

    wire d_is_releaseack = (io_tl_d_bits_opcode == 3'd6);
    wire d_is_grantdata  = (io_tl_d_bits_opcode == 3'd5);
    wire d_is_grant      = (io_tl_d_bits_opcode == 3'd4);
    // Uncached D responses: AccessAck=0, AccessAckData=1, HintAck=2.
    wire d_is_unc_resp   = (io_tl_d_bits_opcode <= 3'd2);

    // TL-A engine ownership (single-beat scope -> opcode is unambiguous).
    wire a_is_acq = (io_tl_a_bits_opcode >= 3'd6);   // Acquire*
    wire a_is_unc = (io_tl_a_bits_opcode <= 3'd5);   // Get/Put/Hint/Atomic

    // CHI REQ txnID partition (bits[7:6]): 00 acquire, 10 release, 01 unc.
    wire req_is_rel = io_chi_txreq_bits_txnID[7];
    wire req_is_unc = !io_chi_txreq_bits_txnID[7] && io_chi_txreq_bits_txnID[6];
    wire req_is_acq = !io_chi_txreq_bits_txnID[7] && !io_chi_txreq_bits_txnID[6];

    wire c_is_probeack     = (io_tl_c_bits_opcode == 3'd4);
    wire c_is_probeackdata = (io_tl_c_bits_opcode == 3'd5);
    wire c_is_release      = (io_tl_c_bits_opcode == 3'd6);
    wire c_is_releasedata  = (io_tl_c_bits_opcode == 3'd7);

    wire txrsp_is_snpresp = (io_chi_txrsp_bits_opcode == 5'd1);
    wire txrsp_is_compack = (io_chi_txrsp_bits_opcode == 5'd2);
    wire txdat_is_snprespdata = (io_chi_txdat_bits_opcode == 4'd1);
    wire txdat_is_copyback    = (io_chi_txdat_bits_opcode == 4'd2);
    wire txdat_is_noncopyback = (io_chi_txdat_bits_opcode == 4'd3);

    // -----------------------------------------------------------------
    // Acquire snapshot — latched at A.fire, cleared at CompAck.  txrsp is
    // shared with the snoop engine, so the clear is gated on CompAck
    // specifically: a snoop SnpResp must NOT retire an in-flight acquire.
    // -----------------------------------------------------------------
    reg        acq_snap_valid;
    reg [2:0]  acq_snap_opcode;
    reg [2:0]  acq_snap_param;
    reg [3:0]  acq_snap_source;
    initial acq_snap_valid = 1'b0;
    always @(posedge clock) begin
        if (reset) acq_snap_valid <= 1'b0;
        else if (a_fire && a_is_acq) begin    // only Acquire* feeds this engine
            acq_snap_valid  <= 1'b1;
            acq_snap_opcode <= io_tl_a_bits_opcode;
            acq_snap_param  <= io_tl_a_bits_param;
            acq_snap_source <= io_tl_a_bits_source;
        end else if (txrsp_fire && txrsp_is_compack) begin
            acq_snap_valid  <= 1'b0;
        end
    end

    // -----------------------------------------------------------------
    // Uncached snapshot — latched at the uncached A.fire (Get/Put/Hint/
    // Atomic), cleared when its TL-D response (AccessAck/AccessAckData/
    // HintAck) fires.  Single-beat A scope means one beat == one accept.
    // -----------------------------------------------------------------
    reg        unc_snap_valid;
    reg [2:0]  unc_snap_opcode;
    reg [2:0]  unc_snap_param;
    reg [3:0]  unc_snap_source;
    initial unc_snap_valid = 1'b0;
    always @(posedge clock) begin
        if (reset) unc_snap_valid <= 1'b0;
        else if (!unc_snap_valid && a_fire && a_is_unc) begin
            unc_snap_valid  <= 1'b1;
            unc_snap_opcode <= io_tl_a_bits_opcode;
            unc_snap_param  <= io_tl_a_bits_param;
            unc_snap_source <= io_tl_a_bits_source;
        end else if (d_fire && d_is_unc_resp) begin
            unc_snap_valid  <= 1'b0;
        end
    end

    // -----------------------------------------------------------------
    // Release snapshot — latched on first Release/ReleaseData C-beat
    // when no release is already in flight.  Cleared on ReleaseAck.
    // ProbeAck/ProbeAckData C-beats DO NOT trigger this snapshot
    // (they are routed to the snoop engine).
    // -----------------------------------------------------------------
    reg        rel_snap_valid;
    reg [2:0]  rel_snap_opcode;
    reg [2:0]  rel_snap_param;
    reg [3:0]  rel_snap_source;
    initial rel_snap_valid = 1'b0;
    always @(posedge clock) begin
        if (reset) rel_snap_valid <= 1'b0;
        else begin
            if (!rel_snap_valid && io_tl_c_valid &&
                (c_is_release || c_is_releasedata)) begin
                rel_snap_valid  <= 1'b1;
                rel_snap_opcode <= io_tl_c_bits_opcode;
                rel_snap_param  <= io_tl_c_bits_param;
                rel_snap_source <= io_tl_c_bits_source;
            end
            if (d_fire && d_is_releaseack) begin
                rel_snap_valid <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------
    // Snoop snapshot — {opcode, txnID, addr} latched at rxsnp.fire.
    //
    // "Snoop in flight" is taken directly from the DUT's own FSM rather
    // than a shadow beat counter: the RTL drives io_chi_rxsnp_ready high
    // *only* in sSnpIdle, so !rxsnp_ready means the snoop engine is busy
    // (Probe issued / waiting on C / forwarding SnpResp[Data]).  Deriving
    // the in-flight gate from rxsnp_ready keeps it exactly in step with
    // the RTL across any SnpRespData beat count (the C size, hence the
    // beat count, is a free input here).
    // -----------------------------------------------------------------
    reg [4:0]  snp_snap_opcode;
    reg [7:0]  snp_snap_txnID;
    reg [44:0] snp_snap_addr;
    always @(posedge clock) begin
        if (snp_fire) begin
            snp_snap_opcode <= io_chi_rxsnp_bits_opcode;
            snp_snap_txnID  <= io_chi_rxsnp_bits_txnID;
            snp_snap_addr   <= io_chi_rxsnp_bits_addr;
        end
    end
    wire snp_busy = !io_chi_rxsnp_ready;

    // -----------------------------------------------------------------
    // F-CHI-1: REQ opcode matches snapshot's {opcode, param}.
    //   Acquire side (txnID[7]==0):
    //     AcquireBlock(NtoB) -> ReadShared (0x01)
    //     AcquireBlock(NtoT) -> ReadUnique (0x07)
    //     AcquireBlock(BtoT) -> MakeUnique (0x0C)
    //     AcquirePerm(*)     -> MakeUnique (0x0C)
    //   Release side (txnID[7]==1):
    //     Release             -> Evict        (0x0D)
    //     ReleaseData(TtoN)   -> WriteBackFull(0x1D)
    //     ReleaseData(TtoB)   -> WriteCleanFull(0x19)
    // -----------------------------------------------------------------
    always @(*) if (chk && req_fire && req_is_acq) begin
        assert (acq_snap_valid);
        if (acq_snap_opcode == 3'd7)
            assert (io_chi_txreq_bits_opcode == 7'h0C);
        else if (acq_snap_param == 3'd0)
            assert (io_chi_txreq_bits_opcode == 7'h01);
        else if (acq_snap_param == 3'd1)
            assert (io_chi_txreq_bits_opcode == 7'h07);
        else
            assert (io_chi_txreq_bits_opcode == 7'h0C);
    end

    always @(*) if (chk && req_fire && req_is_rel) begin
        assert (rel_snap_valid);
        if (rel_snap_opcode == 3'd6)
            assert (io_chi_txreq_bits_opcode == 7'h0D);
        else if (rel_snap_param == 3'd0)
            assert (io_chi_txreq_bits_opcode == 7'h19);
        else
            assert (io_chi_txreq_bits_opcode == 7'h1D);
    end

    // -----------------------------------------------------------------
    // F-CHI-2: CompAck txnID equals acquire snapshot.source.  txrsp is
    // now shared between the acquire engine (CompAck) and the snoop
    // engine (SnpResp); every txrsp beat is exactly one of those two,
    // and only the CompAck case is constrained here.
    // -----------------------------------------------------------------
    always @(*) if (chk && txrsp_fire) begin
        assert (txrsp_is_compack || txrsp_is_snpresp);
    end
    always @(*) if (chk && txrsp_fire && txrsp_is_compack) begin
        assert (acq_snap_valid);
        assert (io_chi_txrsp_bits_txnID == {4'b0, acq_snap_source});
    end

    // -----------------------------------------------------------------
    // F-CHI-3: D-channel routing.  Grant/GrantData routed from acquire
    // snapshot; ReleaseAck routed from release snapshot.
    // -----------------------------------------------------------------
    always @(*) if (chk && d_fire && (d_is_grant || d_is_grantdata)) begin
        assert (acq_snap_valid);
        assert (io_tl_d_bits_source == acq_snap_source);
    end
    always @(*) if (chk && d_fire && d_is_releaseack) begin
        assert (rel_snap_valid);
        assert (io_tl_d_bits_source == rel_snap_source);
    end

    // -----------------------------------------------------------------
    // F-CHI-4: Release txdat (CopyBackWrData) only fires while a release
    // snapshot is in flight.  txdat is shared three ways now — release
    // (CopyBackWrData), uncached (NonCopyBackWrData) and snoop
    // (SnpRespData) — so every beat is exactly one of those, and only the
    // CopyBackWrData case requires a live release here (NonCopyBackWrData
    // is F-CHI-10, SnpRespData is F-CHI-6).
    // -----------------------------------------------------------------
    always @(*) if (chk && txdat_fire) begin
        assert (txdat_is_copyback || txdat_is_snprespdata || txdat_is_noncopyback);
    end
    always @(*) if (chk && txdat_fire && txdat_is_copyback) begin
        assert (rel_snap_valid);
    end

    // -----------------------------------------------------------------
    // F-CHI-5: txnID partition (bits[7:6]) — acquire 00, release 10,
    // uncached 01.  Each partition only ever emits its own opcode set, so
    // the three engines never collide on txnID even with the same source.
    // -----------------------------------------------------------------
    always @(*) if (chk && req_fire && req_is_acq) begin
        // Acquire REQ opcodes
        assert (io_chi_txreq_bits_opcode == 7'h01 ||
                io_chi_txreq_bits_opcode == 7'h07 ||
                io_chi_txreq_bits_opcode == 7'h0C);
    end
    always @(*) if (chk && req_fire && req_is_rel) begin
        // Release REQ opcodes
        assert (io_chi_txreq_bits_opcode == 7'h0D ||
                io_chi_txreq_bits_opcode == 7'h19 ||
                io_chi_txreq_bits_opcode == 7'h1D);
    end

    // -----------------------------------------------------------------
    // F-CHI-6: Snoop response conservation.  A SnpResp (txrsp) or
    // SnpRespData (txdat) only fires while a snoop snapshot is live, and
    // its txnID echoes the snoop the HN issued.  No snoop response is
    // ever produced without a covering rxsnp.
    // -----------------------------------------------------------------
    always @(*) if (chk && txrsp_fire && txrsp_is_snpresp) begin
        assert (snp_busy);
        assert (io_chi_txrsp_bits_txnID == snp_snap_txnID);
    end
    always @(*) if (chk && txdat_fire && txdat_is_snprespdata) begin
        assert (snp_busy);
        assert (io_chi_txdat_bits_txnID == snp_snap_txnID);
    end

    // -----------------------------------------------------------------
    // F-CHI-7: No spurious Probe.  TL-B is only valid while a snoop is
    // in flight; the Probe carries the snoop's line address and a param
    // determined by the snoop opcode (invalidating snoops -> toN(2),
    // all others -> toB(1)).
    // -----------------------------------------------------------------
    wire snp_is_invalidate = (snp_snap_opcode == 5'd7)  ||   // SnpUnique
                             (snp_snap_opcode == 5'd9)  ||   // SnpCleanInvalid
                             (snp_snap_opcode == 5'd10);      // SnpMakeInvalid
    always @(*) if (chk && io_tl_b_valid) begin
        assert (snp_busy);
        assert (io_tl_b_bits_opcode  == 3'd6);               // Probe
        assert (io_tl_b_bits_address == {snp_snap_addr, 3'b000});
        if (snp_is_invalidate)
            assert (io_tl_b_bits_param == 3'd2);             // toN
        else
            assert (io_tl_b_bits_param == 3'd1);             // toB
    end

    // -----------------------------------------------------------------
    // F-CHI-8: Probe/Release race determinism.  The snoop and release
    // engines share the C, txrsp and txdat channels but never source a
    // response from the other's state: each txdat beat is *exactly* one
    // of CopyBackWrData (release) or SnpRespData (snoop), and each txrsp
    // beat is exactly CompAck (acquire) or SnpResp (snoop).  Combined
    // with the snapshot-gating in F-CHI-4/F-CHI-6 this ties every shared
    // beat to its live engine with no double-claim.  The bridge does not
    // collapse a probe that races a release (see TLCToCHI Stage 5
    // limits); instead the two engines complete independently — the
    // cover goals below show the race window (both in flight) is
    // reachable.
    // -----------------------------------------------------------------
    always @(*) if (chk && txdat_fire) begin
        // Exactly one of the three txdat producers owns the beat.
        assert ((txdat_is_copyback + txdat_is_snprespdata + txdat_is_noncopyback) == 3'd1);
    end
    always @(*) if (chk && txrsp_fire) begin
        assert (txrsp_is_compack != txrsp_is_snpresp);
    end

    // -----------------------------------------------------------------
    // F-CHI-9: Uncached REQ mapping.  A REQ on the uncached partition
    // (txnID[7:6]==01) only fires with a live uncached snapshot, and its
    // CHI opcode is exactly the documented map of the latched TL-A
    // {opcode, param}:
    //   Get(4)        -> ReadOnce      (0x03)
    //   PutFull(0)    -> WriteUniqueFull (0x1B)
    //   PutPartial(1) -> WriteUniquePtl  (0x1A)
    //   Hint(5)       -> CleanShared(0x08) [PrefetchRead] / CleanInvalid(0x09)
    //   Arith(2)      -> AtomicLoad Smin/Smax/Umin/Umax/Add (0x4D/4C/4F/4E/48)
    //   Logical(3)    -> AtomicLoad Eor/Set/Clr (0x4A/4B/49) / AtomicSwap(0x50)
    // -----------------------------------------------------------------
    always @(*) if (chk && req_fire && req_is_unc) begin
        assert (unc_snap_valid);
        case (unc_snap_opcode)
            3'd4: assert (io_chi_txreq_bits_opcode == 7'h03);  // Get
            3'd0: assert (io_chi_txreq_bits_opcode == 7'h1B);  // PutFull
            3'd1: assert (io_chi_txreq_bits_opcode == 7'h1A);  // PutPartial
            3'd5: assert (io_chi_txreq_bits_opcode ==
                          (unc_snap_param == 3'd0 ? 7'h08 : 7'h09));  // Hint
            3'd2: begin  // ArithmeticData
                if      (unc_snap_param == 3'd0) assert (io_chi_txreq_bits_opcode == 7'h4D);
                else if (unc_snap_param == 3'd1) assert (io_chi_txreq_bits_opcode == 7'h4C);
                else if (unc_snap_param == 3'd2) assert (io_chi_txreq_bits_opcode == 7'h4F);
                else if (unc_snap_param == 3'd3) assert (io_chi_txreq_bits_opcode == 7'h4E);
                else                             assert (io_chi_txreq_bits_opcode == 7'h48);
            end
            default: begin  // LogicalData (opcode 3)
                if      (unc_snap_param == 3'd0) assert (io_chi_txreq_bits_opcode == 7'h4A);
                else if (unc_snap_param == 3'd1) assert (io_chi_txreq_bits_opcode == 7'h4B);
                else if (unc_snap_param == 3'd2) assert (io_chi_txreq_bits_opcode == 7'h49);
                else                             assert (io_chi_txreq_bits_opcode == 7'h50);
            end
        endcase
    end

    // -----------------------------------------------------------------
    // F-CHI-10: Uncached write-data conservation.  NonCopyBackWrData only
    // fires while an uncached write/atomic is in flight, and only for ops
    // that actually carry write data (Put / Atomic — never Get / Hint).
    // -----------------------------------------------------------------
    wire unc_has_wdata = (unc_snap_opcode == 3'd0) || (unc_snap_opcode == 3'd1) ||  // Put
                         (unc_snap_opcode == 3'd2) || (unc_snap_opcode == 3'd3);     // Atomic
    always @(*) if (chk && txdat_fire && txdat_is_noncopyback) begin
        assert (unc_snap_valid);
        assert (unc_has_wdata);
    end

    // -----------------------------------------------------------------
    // F-CHI-11: Uncached D routing.  AccessAck/AccessAckData/HintAck only
    // fire with a live uncached snapshot and carry its source; the D
    // opcode matches the op class (read-return -> AccessAckData,
    // hint -> HintAck, write -> AccessAck).
    // -----------------------------------------------------------------
    wire unc_returns_data = (unc_snap_opcode == 3'd4) ||                       // Get
                            (unc_snap_opcode == 3'd2) || (unc_snap_opcode == 3'd3); // Atomic
    wire unc_is_hint      = (unc_snap_opcode == 3'd5);
    always @(*) if (chk && d_fire && d_is_unc_resp) begin
        assert (unc_snap_valid);
        assert (io_tl_d_bits_source == unc_snap_source);
        if (unc_returns_data) assert (io_tl_d_bits_opcode == 3'd1);  // AccessAckData
        else if (unc_is_hint) assert (io_tl_d_bits_opcode == 3'd2);  // HintAck
        else                  assert (io_tl_d_bits_opcode == 3'd0);  // AccessAck
    end

    // -----------------------------------------------------------------
    // Cover goals
    // -----------------------------------------------------------------
    always @(*) cover (chk && d_fire && d_is_grant);       // Grant
    always @(*) cover (chk && d_fire && d_is_grantdata);   // GrantData
    always @(*) cover (chk && d_fire && d_is_releaseack);  // ReleaseAck
    always @(*) cover (chk && txdat_fire && txdat_is_copyback);     // CopyBackWrData
    always @(*) cover (chk && req_fire && io_chi_txreq_bits_opcode == 7'h0D); // Evict
    always @(*) cover (chk && req_fire && io_chi_txreq_bits_opcode == 7'h1D); // WriteBackFull
    always @(*) cover (chk && b_fire);                              // Probe issued
    always @(*) cover (chk && txrsp_fire && txrsp_is_snpresp);      // SnpResp
    always @(*) cover (chk && txdat_fire && txdat_is_snprespdata);  // SnpRespData
    always @(*) cover (chk && snp_busy && rel_snap_valid);          // probe/release race window
    always @(*) cover (chk && snp_busy && acq_snap_valid);          // snoop during acquire
    // Stage 6 uncached / atomic
    always @(*) cover (chk && req_fire && io_chi_txreq_bits_opcode == 7'h03); // ReadOnce
    always @(*) cover (chk && req_fire && io_chi_txreq_bits_opcode == 7'h1B); // WriteUniqueFull
    always @(*) cover (chk && req_fire && io_chi_txreq_bits_opcode == 7'h08); // CleanShared (prefetch)
    always @(*) cover (chk && req_fire && io_chi_txreq_bits_opcode == 7'h48); // AtomicLoadAdd
    always @(*) cover (chk && req_fire && io_chi_txreq_bits_opcode == 7'h50); // AtomicSwap
    always @(*) cover (chk && txdat_fire && txdat_is_noncopyback);           // NonCopyBackWrData
    always @(*) cover (chk && d_fire && (io_tl_d_bits_opcode == 3'd1) && unc_snap_valid); // AccessAckData
    always @(*) cover (chk && d_fire && (io_tl_d_bits_opcode == 3'd2));      // HintAck

endmodule
