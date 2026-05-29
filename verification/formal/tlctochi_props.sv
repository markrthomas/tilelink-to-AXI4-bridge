// tlctochi_props.sv — SymbiYosys formal wrapper for TLCToCHI
//
// Stage 3 properties (Read-shared / Read-unique / Make-unique).
//
//   F-CHI-1  REQ opcode matches TL-A {opcode, param} at the moment the
//            REQ was queued (snapshot at A.fire).
//   F-CHI-2  CompAck txnID equals the TL-A source that initiated the
//            outstanding acquire.
//   F-CHI-3  GrantData.param consistency: toT iff CHI resp carries
//            UC/UD; toB iff SC.
//
// Cover goals: Grant and GrantData both reachable end-to-end.

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
    //   Only legal TL-A acquire opcodes (AcquireBlock=6, AcquirePerm=7)
    //   and legal params (NtoB=0, NtoT=1, BtoT=2).
    always @(*) if (io_tl_a_valid) begin
        assume (io_tl_a_bits_opcode == 3'd6 || io_tl_a_bits_opcode == 3'd7);
        assume (io_tl_a_bits_param  <= 3'd2);
    end
    //   Only legal TL-C release opcodes (Release=6, ReleaseData=7) and
    //   legal params (TtoB=0, TtoN=1, BtoN=2).  ProbeAck variants
    //   (4,5) are Stage 5 territory and tied off here.
    always @(*) if (io_tl_c_valid) begin
        assume (io_tl_c_bits_opcode == 3'd6 || io_tl_c_bits_opcode == 3'd7);
        assume (io_tl_c_bits_param  <= 3'd2);
    end
    //   Assume downstream always ready (open-loop bridge view).
    always @(*) assume (io_chi_txreq_ready);
    always @(*) assume (io_chi_txrsp_ready);
    always @(*) assume (io_chi_txdat_ready);

    // -----------------------------------------------------------------
    // Channel handshake wires
    // -----------------------------------------------------------------
    wire a_fire    = io_tl_a_valid    && io_tl_a_ready;
    wire c_fire    = io_tl_c_valid    && io_tl_c_ready;
    wire req_fire  = io_chi_txreq_valid && io_chi_txreq_ready;
    wire d_fire    = io_tl_d_valid    && io_tl_d_ready;
    wire txrsp_fire= io_chi_txrsp_valid && io_chi_txrsp_ready;
    wire e_fire    = io_tl_e_valid    && io_tl_e_ready;

    wire d_is_releaseack = (io_tl_d_bits_opcode == 3'd6);
    wire d_is_grantdata  = (io_tl_d_bits_opcode == 3'd5);
    wire d_is_grant      = (io_tl_d_bits_opcode == 3'd4);
    wire req_is_rel      = io_chi_txreq_bits_txnID[7];  // txnID MSB

    // -----------------------------------------------------------------
    // Acquire snapshot — latched at A.fire, cleared at CompAck.
    // -----------------------------------------------------------------
    reg        acq_snap_valid;
    reg [2:0]  acq_snap_opcode;
    reg [2:0]  acq_snap_param;
    reg [3:0]  acq_snap_source;
    initial acq_snap_valid = 1'b0;
    always @(posedge clock) begin
        if (reset) acq_snap_valid <= 1'b0;
        else if (a_fire) begin
            acq_snap_valid  <= 1'b1;
            acq_snap_opcode <= io_tl_a_bits_opcode;
            acq_snap_param  <= io_tl_a_bits_param;
            acq_snap_source <= io_tl_a_bits_source;
        end else if (txrsp_fire) begin
            acq_snap_valid  <= 1'b0;
        end
    end

    // -----------------------------------------------------------------
    // Release snapshot — latched on first C-beat of a release (when no
    // release is already in flight).  Cleared on ReleaseAck D.fire.
    // -----------------------------------------------------------------
    reg        rel_snap_valid;
    reg [2:0]  rel_snap_opcode;
    reg [2:0]  rel_snap_param;
    reg [3:0]  rel_snap_source;
    initial rel_snap_valid = 1'b0;
    always @(posedge clock) begin
        if (reset) rel_snap_valid <= 1'b0;
        else begin
            if (!rel_snap_valid && io_tl_c_valid) begin
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
    always @(*) if (chk && req_fire && !req_is_rel) begin
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
    // F-CHI-2: CompAck txnID equals acquire snapshot.source.
    // -----------------------------------------------------------------
    always @(*) if (chk && txrsp_fire) begin
        assert (io_chi_txrsp_bits_opcode == 5'h02); // CompAck
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
    // F-CHI-4: Release txdat (CopyBackWrData) only fires while a
    // release snapshot is in flight.  Guards against spurious writes.
    // -----------------------------------------------------------------
    wire txdat_fire = io_chi_txdat_valid && io_chi_txdat_ready;
    always @(*) if (chk && txdat_fire) begin
        assert (rel_snap_valid);
        assert (io_chi_txdat_bits_opcode == 4'h2); // CopyBackWrData
    end

    // -----------------------------------------------------------------
    // F-CHI-5: txnID partition — acquire REQs always carry txnID[7]=0,
    // release REQs always carry txnID[7]=1.  No collisions possible.
    // -----------------------------------------------------------------
    always @(*) if (chk && req_fire && !req_is_rel) begin
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
    // Cover goals
    // -----------------------------------------------------------------
    always @(*) cover (chk && d_fire && d_is_grant);       // Grant
    always @(*) cover (chk && d_fire && d_is_grantdata);   // GrantData
    always @(*) cover (chk && d_fire && d_is_releaseack);  // ReleaseAck
    always @(*) cover (chk && txdat_fire);                  // CopyBackWrData
    always @(*) cover (chk && req_fire && io_chi_txreq_bits_opcode == 7'h0D); // Evict
    always @(*) cover (chk && req_fire && io_chi_txreq_bits_opcode == 7'h1D); // WriteBackFull

endmodule
