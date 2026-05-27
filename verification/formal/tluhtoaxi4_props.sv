// tluhtoaxi4_props.sv — SymbiYosys formal wrapper for TLUHToAXI4
//
// Instantiates the elaborated SV bridge with unconstrained inputs.  Adds:
//   - TL master compliance assumptions (irrevocable A, valid opcodes/sizes)
//   - AXI subordinate compliance assumptions (B/R stability while !ready)
//   - Safety assertions  (covered in the `bmc` task)
//   - Cover goals       (covered in the `cover` task)
//
// Properties (matching doc/PLAN.md "F" labels):
//   F6  : AW/AR.burst == INCR and AW/AR.size == log2(beatBytes) = 3
//   F8  : AW/AR address aligned to beatBytes
//   F2  : D.source equals the source of the most recent A.fire transaction
//
// Cover goals (each in its own cover point so the engine produces a witness):
//   C1  : a write transaction completes (D = AccessAck)
//   C2  : a read transaction completes  (D = AccessAckData)
//   C3  : a hint transaction completes  (D = HintAck)

`default_nettype none
`timescale 1ns/1ps

module tluhtoaxi4_props (
    input wire clock
);

    // ----------------------------------------------------------------------
    // Reset is constrained via a phase counter so the design always sees a
    // clean reset pulse before any assertion fires.
    // ----------------------------------------------------------------------
    reg [2:0] ph;
    initial ph = 3'd0;
    always @(posedge clock) if (ph != 3'd7) ph <= ph + 3'd1;

    // Phase 0..3: reset asserted. Phase 4..7+: reset deasserted.
    wire reset = (ph < 3'd4);

    // f_past_valid: 0 at step 0, 1 forever after the first posedge.  Gate
    // assertions with this to skip the meaningless pre-reset cycle.
    reg f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge clock) f_past_valid <= 1'b1;

    // ----------------------------------------------------------------------
    // Free inputs — environment surfaces that the formal engine can choose.
    // ----------------------------------------------------------------------
    (* anyseq *) wire        io_tl_a_valid;
    (* anyseq *) wire [2:0]  io_tl_a_bits_opcode;
    (* anyseq *) wire [2:0]  io_tl_a_bits_param;
    (* anyseq *) wire [5:0]  io_tl_a_bits_size;
    (* anyseq *) wire [3:0]  io_tl_a_bits_source;
    (* anyseq *) wire [31:0] io_tl_a_bits_address;
    (* anyseq *) wire [7:0]  io_tl_a_bits_mask;
    (* anyseq *) wire [63:0] io_tl_a_bits_data;
    (* anyseq *) wire        io_tl_a_bits_corrupt;
    (* anyseq *) wire        io_tl_d_ready;

    (* anyseq *) wire        io_axi_aw_ready;
    (* anyseq *) wire        io_axi_w_ready;
    (* anyseq *) wire        io_axi_b_valid;
    (* anyseq *) wire [3:0]  io_axi_b_bits_id;
    (* anyseq *) wire [1:0]  io_axi_b_bits_resp;
    (* anyseq *) wire        io_axi_ar_ready;
    (* anyseq *) wire        io_axi_r_valid;
    (* anyseq *) wire [3:0]  io_axi_r_bits_id;
    (* anyseq *) wire [63:0] io_axi_r_bits_data;
    (* anyseq *) wire [1:0]  io_axi_r_bits_resp;
    (* anyseq *) wire        io_axi_r_bits_last;

    // ----------------------------------------------------------------------
    // DUT outputs
    // ----------------------------------------------------------------------
    wire        io_tl_a_ready;
    wire        io_tl_d_valid;
    wire [2:0]  io_tl_d_bits_opcode;
    wire [2:0]  io_tl_d_bits_param;
    wire [5:0]  io_tl_d_bits_size;
    wire [3:0]  io_tl_d_bits_source;
    wire        io_tl_d_bits_sink;
    wire        io_tl_d_bits_denied;
    wire [63:0] io_tl_d_bits_data;
    wire        io_tl_d_bits_corrupt;

    wire        io_axi_aw_valid;
    wire [3:0]  io_axi_aw_bits_id;
    wire [31:0] io_axi_aw_bits_addr;
    wire [7:0]  io_axi_aw_bits_len;
    wire [2:0]  io_axi_aw_bits_size;
    wire [1:0]  io_axi_aw_bits_burst;

    wire        io_axi_w_valid;
    wire [63:0] io_axi_w_bits_data;
    wire [7:0]  io_axi_w_bits_strb;
    wire        io_axi_w_bits_last;

    wire        io_axi_b_ready;

    wire        io_axi_ar_valid;
    wire [3:0]  io_axi_ar_bits_id;
    wire [31:0] io_axi_ar_bits_addr;
    wire [7:0]  io_axi_ar_bits_len;
    wire [2:0]  io_axi_ar_bits_size;
    wire [1:0]  io_axi_ar_bits_burst;

    wire        io_axi_r_ready;

    TLUHToAXI4 dut (
        .clock(clock),
        .reset(reset),

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

        .io_axi_aw_ready(io_axi_aw_ready),
        .io_axi_aw_valid(io_axi_aw_valid),
        .io_axi_aw_bits_id(io_axi_aw_bits_id),
        .io_axi_aw_bits_addr(io_axi_aw_bits_addr),
        .io_axi_aw_bits_len(io_axi_aw_bits_len),
        .io_axi_aw_bits_size(io_axi_aw_bits_size),
        .io_axi_aw_bits_burst(io_axi_aw_bits_burst),

        .io_axi_w_ready(io_axi_w_ready),
        .io_axi_w_valid(io_axi_w_valid),
        .io_axi_w_bits_data(io_axi_w_bits_data),
        .io_axi_w_bits_strb(io_axi_w_bits_strb),
        .io_axi_w_bits_last(io_axi_w_bits_last),

        .io_axi_b_ready(io_axi_b_ready),
        .io_axi_b_valid(io_axi_b_valid),
        .io_axi_b_bits_id(io_axi_b_bits_id),
        .io_axi_b_bits_resp(io_axi_b_bits_resp),

        .io_axi_ar_ready(io_axi_ar_ready),
        .io_axi_ar_valid(io_axi_ar_valid),
        .io_axi_ar_bits_id(io_axi_ar_bits_id),
        .io_axi_ar_bits_addr(io_axi_ar_bits_addr),
        .io_axi_ar_bits_len(io_axi_ar_bits_len),
        .io_axi_ar_bits_size(io_axi_ar_bits_size),
        .io_axi_ar_bits_burst(io_axi_ar_bits_burst),

        .io_axi_r_ready(io_axi_r_ready),
        .io_axi_r_valid(io_axi_r_valid),
        .io_axi_r_bits_id(io_axi_r_bits_id),
        .io_axi_r_bits_data(io_axi_r_bits_data),
        .io_axi_r_bits_resp(io_axi_r_bits_resp),
        .io_axi_r_bits_last(io_axi_r_bits_last)
    );

    // ======================================================================
    // ENVIRONMENT ASSUMPTIONS
    // ======================================================================

    // ---- TL master: nothing during reset.
    always @(posedge clock) if (reset) assume (!io_tl_a_valid);

    // ---- TL master: opcode must be one of the supported set (0,1,4,5).
    //      Atomics (2,3) and reserved (6,7) are out of bridge scope.
    always @(*) if (io_tl_a_valid)
        assume (io_tl_a_bits_opcode == 3'd0 ||
                io_tl_a_bits_opcode == 3'd1 ||
                io_tl_a_bits_opcode == 3'd4 ||
                io_tl_a_bits_opcode == 3'd5);

    // ---- TL master: size must be within the parameter envelope (≤ 6).
    always @(*) if (io_tl_a_valid)
        assume (io_tl_a_bits_size <= 6'd6);

    // ---- TL master: A irrevocability — bits stable while valid && !ready.
    always @(posedge clock) begin
        if (!reset && $past(io_tl_a_valid) && !$past(io_tl_a_ready)) begin
            assume (io_tl_a_valid);
            assume (io_tl_a_bits_opcode  == $past(io_tl_a_bits_opcode));
            assume (io_tl_a_bits_size    == $past(io_tl_a_bits_size));
            assume (io_tl_a_bits_source  == $past(io_tl_a_bits_source));
            assume (io_tl_a_bits_address == $past(io_tl_a_bits_address));
            assume (io_tl_a_bits_mask    == $past(io_tl_a_bits_mask));
            assume (io_tl_a_bits_data    == $past(io_tl_a_bits_data));
        end
    end

    // ---- AXI subordinate: B-channel stability while valid && !ready.
    always @(posedge clock) begin
        if (!reset && $past(io_axi_b_valid) && !$past(io_axi_b_ready)) begin
            assume (io_axi_b_valid);
            assume (io_axi_b_bits_id   == $past(io_axi_b_bits_id));
            assume (io_axi_b_bits_resp == $past(io_axi_b_bits_resp));
        end
    end

    // ---- AXI subordinate: R-channel stability while valid && !ready.
    always @(posedge clock) begin
        if (!reset && $past(io_axi_r_valid) && !$past(io_axi_r_ready)) begin
            assume (io_axi_r_valid);
            assume (io_axi_r_bits_id   == $past(io_axi_r_bits_id));
            assume (io_axi_r_bits_data == $past(io_axi_r_bits_data));
            assume (io_axi_r_bits_resp == $past(io_axi_r_bits_resp));
            assume (io_axi_r_bits_last == $past(io_axi_r_bits_last));
        end
    end

    // ======================================================================
    // GHOST STATE — track the in-flight transaction so we can check F2.
    //
    // A transaction begins on the first cycle the master asserts A.valid
    // with no transaction outstanding.  For Get/Hint the bridge fires A in
    // the same cycle; for Put the bridge "peeks" A in sIdle (no fire) but
    // still commits to that source for the whole burst (latched into
    // regSource).  The snapshot of (source, opcode, size) at that first
    // cycle is what the eventual D response must carry.
    //
    // The transaction ends on the LAST D-channel beat:
    //   AccessAckData : d.fire && r.fire && r.last     (read burst tail)
    //   AccessAck     : d.fire                          (single-beat ack)
    //   HintAck       : d.fire                          (single-beat ack)
    // ======================================================================
    reg        pending_xact;
    reg [3:0]  xact_source;
    reg [2:0]  xact_opcode;
    reg [5:0]  xact_size;

    initial pending_xact = 1'b0;
    initial xact_source  = 4'd0;
    initial xact_opcode  = 3'd0;
    initial xact_size    = 6'd0;

    wire d_fire = io_tl_d_valid && io_tl_d_ready;
    wire r_fire = io_axi_r_valid && io_axi_r_ready;

    wire xact_done_read  = pending_xact && d_fire &&
                           (io_tl_d_bits_opcode == 3'd1) /* AccessAckData */ &&
                           r_fire && io_axi_r_bits_last;
    wire xact_done_other = pending_xact && d_fire &&
                           (io_tl_d_bits_opcode != 3'd1);
    wire xact_begin      = !pending_xact && io_tl_a_valid && !reset;

    always @(posedge clock) begin
        if (reset) begin
            pending_xact <= 1'b0;
            xact_source  <= 4'd0;
            xact_opcode  <= 3'd0;
            xact_size    <= 6'd0;
        end else begin
            if (xact_begin) begin
                pending_xact <= 1'b1;
                xact_source  <= io_tl_a_bits_source;
                xact_opcode  <= io_tl_a_bits_opcode;
                xact_size    <= io_tl_a_bits_size;
            end
            if (xact_done_read || xact_done_other) begin
                pending_xact <= 1'b0;
            end
        end
    end

    // ---- TL master: multi-beat burst stability.  Per-beat irrevocability
    //      (above) covers (valid && !ready); this extends source/opcode/size
    //      stability across the full A burst of a Put transaction.
    always @(*) if (chk && pending_xact && io_tl_a_valid) begin
        assume (io_tl_a_bits_source == xact_source);
        assume (io_tl_a_bits_opcode == xact_opcode);
        assume (io_tl_a_bits_size   == xact_size);
    end

    // ======================================================================
    // SAFETY ASSERTIONS — all gated on f_past_valid && !reset so they only
    // fire after the design has seen a complete reset.
    // ======================================================================

    wire chk = f_past_valid && !reset;

    // F6 — AW/AR burst is INCR and size is bus-width (3).
    always @(*) if (chk && io_axi_aw_valid) begin
        assert (io_axi_aw_bits_burst == 2'b01);
        assert (io_axi_aw_bits_size  == 3'b011);
    end
    always @(*) if (chk && io_axi_ar_valid) begin
        assert (io_axi_ar_bits_burst == 2'b01);
        assert (io_axi_ar_bits_size  == 3'b011);
    end

    // F8 — AW/AR address is aligned to beatBytes (low 3 bits zero).
    always @(*) if (chk && io_axi_aw_valid)
        assert (io_axi_aw_bits_addr[2:0] == 3'd0);
    always @(*) if (chk && io_axi_ar_valid)
        assert (io_axi_ar_bits_addr[2:0] == 3'd0);

    // F2 — every D beat of an in-flight transaction carries the source
    //      snapshotted at the first A.valid of that transaction.
    always @(*) if (chk && pending_xact && io_tl_d_valid && io_tl_d_ready)
        assert (io_tl_d_bits_source == xact_source);

    // Bonus — writes / hints never set D.corrupt.
    always @(*) if (chk && io_tl_d_valid && (io_tl_d_bits_opcode == 3'd0 ||
                                              io_tl_d_bits_opcode == 3'd2))
        assert (io_tl_d_bits_corrupt == 1'b0);

    // ======================================================================
    // COVER GOALS
    // ======================================================================

    // C1 — write transaction completes (AccessAck on D).
    always @(*) cover (chk && io_tl_d_valid && io_tl_d_ready &&
                       io_tl_d_bits_opcode == 3'd0);

    // C2 — read transaction completes (AccessAckData on D).
    always @(*) cover (chk && io_tl_d_valid && io_tl_d_ready &&
                       io_tl_d_bits_opcode == 3'd1);

    // C3 — hint transaction completes (HintAck on D).
    always @(*) cover (chk && io_tl_d_valid && io_tl_d_ready &&
                       io_tl_d_bits_opcode == 3'd2);

endmodule
