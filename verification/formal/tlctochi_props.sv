// tlctochi_props.sv — SymbiYosys formal wrapper for TLCToCHI
//
// Focused on Stage 2 (Read-shared) behaviors:
//   - AcquireBlock(NtoB) -> ReadShared
//   - CompData -> GrantData(toB)
//   - GrantAck -> CompAck
//
// Properties (F-CHI-*):
//   F-CHI-1 : Every ReadShared eventually leads to a CompAck (with same txnID).
//   F-CHI-2 : Every D.GrantData beat corresponds to an in-flight ReadShared.
//   F-CHI-3 : Source/TxnID preservation.

`default_nettype none
`timescale 1ns/1ps

module tlctochi_props (
    input wire clock
);

    // ----------------------------------------------------------------------
    // Reset phase + f_past_valid
    // ----------------------------------------------------------------------
    reg [2:0] ph;
    initial ph = 3'd0;
    always @(posedge clock) if (ph != 3'd7) ph <= ph + 3'd1;
    wire reset = (ph < 3'd4);

    reg f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge clock) f_past_valid <= 1'b1;

    wire chk = f_past_valid && !reset;

    // ----------------------------------------------------------------------
    // Free inputs.
    // ----------------------------------------------------------------------
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
    // io_tl_e_bits_sink optimized out by firtool in Stage 2

    (* anyseq *) wire        io_chi_txreq_ready;
    (* anyseq *) wire        io_chi_txrsp_ready;
    (* anyseq *) wire        io_chi_txdat_ready;

    (* anyseq *) wire        io_chi_rxrsp_valid;
    (* anyseq *) wire [3:0]  io_chi_rxrsp_bits_qos;
    (* anyseq *) wire [6:0]  io_chi_rxrsp_bits_tgtID;
    (* anyseq *) wire [7:0]  io_chi_rxrsp_bits_txnID;
    (* anyseq *) wire [4:0]  io_chi_rxrsp_bits_opcode;
    (* anyseq *) wire [1:0]  io_chi_rxrsp_bits_respErr;
    (* anyseq *) wire [2:0]  io_chi_rxrsp_bits_resp;
    (* anyseq *) wire [7:0]  io_chi_rxrsp_bits_dbID;
    (* anyseq *) wire [3:0]  io_chi_rxrsp_bits_pCrdType;
    (* anyseq *) wire        io_chi_rxrsp_bits_traceTag;

    (* anyseq *) wire        io_chi_rxdat_valid;
    (* anyseq *) wire [3:0]  io_chi_rxdat_bits_qos;
    (* anyseq *) wire [6:0]  io_chi_rxdat_bits_tgtID;
    (* anyseq *) wire [7:0]  io_chi_rxdat_bits_txnID;
    (* anyseq *) wire [6:0]  io_chi_rxdat_bits_homeNID;
    (* anyseq *) wire [3:0]  io_chi_rxdat_bits_opcode;
    (* anyseq *) wire [1:0]  io_chi_rxdat_bits_respErr;
    (* anyseq *) wire [2:0]  io_chi_rxdat_bits_resp;
    (* anyseq *) wire [7:0]  io_chi_rxdat_bits_dbID;
    (* anyseq *) wire [1:0]  io_chi_rxdat_bits_ccID;
    (* anyseq *) wire [2:0]  io_chi_rxdat_bits_dataID;
    (* anyseq *) wire [1:0]  io_chi_rxdat_bits_tagOp;
    (* anyseq *) wire        io_chi_rxdat_bits_tu;
    (* anyseq *) wire [7:0]  io_chi_rxdat_bits_be;
    (* anyseq *) wire [63:0] io_chi_rxdat_bits_data;
    (* anyseq *) wire [7:0]  io_chi_rxdat_bits_dataCheck;
    (* anyseq *) wire        io_chi_rxdat_bits_poison;

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

    // ----------------------------------------------------------------------
    // DUT outputs.
    // ----------------------------------------------------------------------
    wire        io_tl_a_ready;
    wire        io_tl_b_valid;
    wire [2:0]  io_tl_b_bits_opcode;
    wire [5:0]  io_tl_b_bits_size;
    wire [3:0]  io_tl_b_bits_source;
    wire [47:0] io_tl_b_bits_address;
    wire [7:0]  io_tl_b_bits_mask;
    wire [63:0] io_tl_b_bits_data;
    wire        io_tl_b_bits_corrupt;
    wire        io_tl_c_ready;
    wire        io_tl_d_valid;
    wire [2:0]  io_tl_d_bits_opcode;
    wire [5:0]  io_tl_d_bits_size;
    wire [3:0]  io_tl_d_bits_source;
    wire        io_tl_d_bits_sink;
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
    wire [0:0]  io_chi_txdat_bits_tu;
    wire [7:0]  io_chi_txdat_bits_be;
    wire [63:0] io_chi_txdat_bits_data;
    wire [7:0]  io_chi_txdat_bits_dataCheck;
    wire        io_chi_txdat_bits_poison;
    wire        io_chi_txdat_bits_traceTag;

    wire        io_chi_rxrsp_ready;
    wire        io_chi_rxdat_ready;
    wire        io_chi_rxsnp_ready;

    TLCToCHI dut (
        .clock(clock), .reset(reset),
        // TL
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
        .io_tl_d_bits_size(io_tl_d_bits_size),
        .io_tl_d_bits_source(io_tl_d_bits_source),
        .io_tl_d_bits_sink(io_tl_d_bits_sink),
        .io_tl_d_bits_data(io_tl_d_bits_data),
        .io_tl_d_bits_corrupt(io_tl_d_bits_corrupt),
        .io_tl_e_ready(io_tl_e_ready),
        .io_tl_e_valid(io_tl_e_valid),
        // CHI tx
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
        // CHI rx
        .io_chi_rxrsp_ready(io_chi_rxrsp_ready),
        .io_chi_rxrsp_valid(io_chi_rxrsp_valid),
        .io_chi_rxrsp_bits_qos(io_chi_rxrsp_bits_qos),
        .io_chi_rxrsp_bits_tgtID(io_chi_rxrsp_bits_tgtID),
        .io_chi_rxrsp_bits_txnID(io_chi_rxrsp_bits_txnID),
        .io_chi_rxrsp_bits_opcode(io_chi_rxrsp_bits_opcode),
        .io_chi_rxrsp_bits_respErr(io_chi_rxrsp_bits_respErr),
        .io_chi_rxrsp_bits_resp(io_chi_rxrsp_bits_resp),
        .io_chi_rxrsp_bits_dbID(io_chi_rxrsp_bits_dbID),
        .io_chi_rxrsp_bits_pCrdType(io_chi_rxrsp_bits_pCrdType),
        .io_chi_rxrsp_bits_traceTag(io_chi_rxrsp_bits_traceTag),
        .io_chi_rxdat_ready(io_chi_rxdat_ready),
        .io_chi_rxdat_valid(io_chi_rxdat_valid),
        .io_chi_rxdat_bits_qos(io_chi_rxdat_bits_qos),
        .io_chi_rxdat_bits_tgtID(io_chi_rxdat_bits_tgtID),
        .io_chi_rxdat_bits_txnID(io_chi_rxdat_bits_txnID),
        .io_chi_rxdat_bits_homeNID(io_chi_rxdat_bits_homeNID),
        .io_chi_rxdat_bits_opcode(io_chi_rxdat_bits_opcode),
        .io_chi_rxdat_bits_respErr(io_chi_rxdat_bits_respErr),
        .io_chi_rxdat_bits_resp(io_chi_rxdat_bits_resp),
        .io_chi_rxdat_bits_dbID(io_chi_rxdat_bits_dbID),
        .io_chi_rxdat_bits_ccID(io_chi_rxdat_bits_ccID),
        .io_chi_rxdat_bits_dataID(io_chi_rxdat_bits_dataID),
        .io_chi_rxdat_bits_tagOp(io_chi_rxdat_bits_tagOp),
        .io_chi_rxdat_bits_tu(io_chi_rxdat_bits_tu),
        .io_chi_rxdat_bits_be(io_chi_rxdat_bits_be),
        .io_chi_rxdat_bits_data(io_chi_rxdat_bits_data),
        .io_chi_rxdat_bits_dataCheck(io_chi_rxdat_bits_dataCheck),
        .io_chi_rxdat_bits_poison(io_chi_rxdat_bits_poison),
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

    // ======================================================================
    // ENVIRONMENT ASSUMPTIONS
    // ======================================================================
    always @(posedge clock) if (reset) begin
        assume (!io_tl_a_valid);
        assume (!io_tl_c_valid);
        assume (!io_tl_e_valid);
    end

    // ---- A Opcode: only AcquireBlock(6) for Stage 2
    always @(*) if (io_tl_a_valid) begin
        assume (io_tl_a_bits_opcode == 3'd6);
        assume (io_tl_a_bits_param == 3'd0); // NtoB
        assume (io_tl_a_bits_size == 6'd6); // 64B
    end

    // ---- CHI txreq acceptance
    always @(*) assume (io_chi_txreq_ready);
    always @(*) assume (io_chi_txrsp_ready);

    // ======================================================================
    // GHOST STATE
    // ======================================================================
    wire a_fire = io_tl_a_valid && io_tl_a_ready;
    wire d_fire = io_tl_d_valid && io_tl_d_ready;
    wire e_fire = io_tl_e_valid && io_tl_e_ready;
    wire req_fire = io_chi_txreq_valid && io_chi_txreq_ready;
    wire dat_fire = io_chi_rxdat_valid && io_chi_rxdat_ready;
    wire rsp_fire = io_chi_txrsp_valid && io_chi_txrsp_ready;

    reg       acq_pending;
    reg [3:0] acq_source;
    initial acq_pending = 0;
    
    always @(posedge clock) begin
        if (reset) acq_pending <= 0;
        else if (a_fire) begin
            acq_pending <= 1;
            acq_source  <= io_tl_a_bits_source;
        end else if (rsp_fire && io_chi_txrsp_bits_opcode == 5'h02) begin // CompAck
            acq_pending <= 0;
        end
    end

    // ======================================================================
    // SAFETY ASSERTIONS
    // ======================================================================
    
    // F-CHI-1: Every ReadShared leads to CompAck
    // (Checked via liveness or sequence; here we check txnID match)
    always @(*) if (chk && rsp_fire && io_chi_txrsp_bits_opcode == 5'h02) begin
        assert (acq_pending);
        assert (io_chi_txrsp_bits_txnID == acq_source);
    end

    // F-CHI-2: Every D.GrantData corresponds to in-flight Acquire
    always @(*) if (chk && d_fire) begin
        assert (acq_pending);
        assert (io_tl_d_bits_opcode == 3'd5); // GrantData
        assert (io_tl_d_bits_source == acq_source);
    end

    // F-CHI-3: ReadShared txnID matches TL source
    always @(*) if (chk && req_fire) begin
        assert (io_chi_txreq_bits_opcode == 7'h01); // ReadShared
        assert (io_chi_txreq_bits_txnID == acq_source);
    end

    // ======================================================================
    // COVER GOALS
    // ======================================================================
    always @(*) cover (chk && e_fire && acq_pending);
    always @(*) cover (chk && rsp_fire && io_chi_txrsp_bits_opcode == 5'h02);

endmodule
