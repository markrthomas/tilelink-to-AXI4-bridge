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

    // chk gates every assertion / assumption that fires only post-reset.
    wire chk = f_past_valid && !reset;

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
    // GHOST STATE — one in-flight transaction per bridge engine.
    //
    // The bridge has three parallel engines, each able to hold one
    // outstanding TL transaction:
    //   READ  : Get  → AR + R → AccessAckData
    //   WRITE : Put  → AW + W → AccessAck
    //   HINT  : Hint → (none) → HintAck
    //
    // For each engine we snapshot (source, size) at the cycle the engine
    // commits to the transaction:
    //   Get   : the first A.fire (single-beat A handshake in sIdle of R)
    //   Put   : the first A.valid the bridge peeks in sIdle of W
    //   Hint  : the A.fire that admits the Hint into the 1-deep slot
    //
    // Each pending flag clears on the LAST D beat of that engine's response:
    //   READ  : d.fire && d.opcode == AccessAckData && r.fire && r.last
    //   WRITE : d.fire && d.opcode == AccessAck
    //   HINT  : d.fire && d.opcode == HintAck
    // ======================================================================
    wire isGetA  = (io_tl_a_bits_opcode == 3'd4);
    wire isPutA  = (io_tl_a_bits_opcode == 3'd0) ||
                   (io_tl_a_bits_opcode == 3'd1);
    wire isHintA = (io_tl_a_bits_opcode == 3'd5);

    wire a_fire = io_tl_a_valid && io_tl_a_ready;
    wire d_fire = io_tl_d_valid && io_tl_d_ready;
    wire r_fire = io_axi_r_valid && io_axi_r_ready;

    // ---- READ engine ghost ----
    reg       r_pending;
    reg [3:0] r_xact_source;
    reg [5:0] r_xact_size;
    initial r_pending     = 1'b0;
    initial r_xact_source = 4'd0;
    initial r_xact_size   = 6'd0;

    wire r_begin = !r_pending && a_fire && isGetA;
    wire r_done  = r_pending && d_fire &&
                   (io_tl_d_bits_opcode == 3'd1) /* AccessAckData */ &&
                   r_fire && io_axi_r_bits_last;

    always @(posedge clock) begin
        if (reset) begin
            r_pending     <= 1'b0;
            r_xact_source <= 4'd0;
            r_xact_size   <= 6'd0;
        end else begin
            if (r_begin) begin
                r_pending     <= 1'b1;
                r_xact_source <= io_tl_a_bits_source;
                r_xact_size   <= io_tl_a_bits_size;
            end
            if (r_done) r_pending <= 1'b0;
        end
    end

    // ---- WRITE engine ghost ----
    //   The bridge captures wSource in sWIdle on a.valid (peek), not on
    //   a.fire — the first a.fire happens later in sWData.  Mirror that
    //   commit semantics here by capturing on first a.valid with !w_pending.
    //
    //   w_in_burst tracks "the master is still feeding the Put A burst" —
    //   from the peek cycle (inclusive) through the last a.fire of the
    //   burst.  Inside this window the master must drive Put beats matching
    //   the snapshot; outside it, the master is free to start a different
    //   engine's transaction (a Get or a Hint).
    //
    //   The window starts at the peek, NOT at the first a.fire, because the
    //   bridge is in sWAW/sWData expecting a_valid to be held until the
    //   first beat completes — without that the bridge would deadlock.
    reg       w_pending;       // a Put has begun, response not yet completed
    reg [3:0] w_xact_source;
    reg [5:0] w_xact_size;
    reg [2:0] w_xact_opcode;   // 0=PutFull, 1=PutPart
    reg       w_in_burst;      // peek seen, last a.fire not yet seen
    reg [6:0] w_a_beats_left;  // Put A beats still owed to the bridge
    initial w_pending      = 1'b0;
    initial w_xact_source  = 4'd0;
    initial w_xact_size    = 6'd0;
    initial w_xact_opcode  = 3'd0;
    initial w_in_burst     = 1'b0;
    initial w_a_beats_left = 7'd0;

    wire w_begin = !w_pending && io_tl_a_valid && isPutA && !reset;
    wire w_done  = w_pending && d_fire &&
                   (io_tl_d_bits_opcode == 3'd0) /* AccessAck */;

    // Beats for the current Put burst: max(1, (1<<size)/beatBytes).
    wire [6:0] w_total_beats =
        (((7'd1) << io_tl_a_bits_size) <= 7'd8) ? 7'd1
                                                : ((7'd1 << io_tl_a_bits_size) >> 7'd3);

    always @(posedge clock) begin
        if (reset) begin
            w_pending      <= 1'b0;
            w_xact_source  <= 4'd0;
            w_xact_size    <= 6'd0;
            w_xact_opcode  <= 3'd0;
            w_in_burst     <= 1'b0;
            w_a_beats_left <= 7'd0;
        end else begin
            if (w_begin) begin
                w_pending      <= 1'b1;
                w_xact_source  <= io_tl_a_bits_source;
                w_xact_size    <= io_tl_a_bits_size;
                w_xact_opcode  <= io_tl_a_bits_opcode;
                w_in_burst     <= 1'b1;
                w_a_beats_left <= w_total_beats;
            end else if (a_fire && isPutA && w_in_burst) begin
                w_a_beats_left <= w_a_beats_left - 7'd1;
                if (w_a_beats_left == 7'd1) w_in_burst <= 1'b0;
            end
            if (w_done) w_pending <= 1'b0;
        end
    end

    // ---- HINT engine ghost ----
    reg       h_pending_g;
    reg [3:0] h_xact_source;
    reg [5:0] h_xact_size;
    initial h_pending_g   = 1'b0;
    initial h_xact_source = 4'd0;
    initial h_xact_size   = 6'd0;

    wire h_begin = !h_pending_g && a_fire && isHintA;
    wire h_done  = h_pending_g && d_fire &&
                   (io_tl_d_bits_opcode == 3'd2) /* HintAck */;

    always @(posedge clock) begin
        if (reset) begin
            h_pending_g   <= 1'b0;
            h_xact_source <= 4'd0;
            h_xact_size   <= 6'd0;
        end else begin
            if (h_begin) begin
                h_pending_g   <= 1'b1;
                h_xact_source <= io_tl_a_bits_source;
                h_xact_size   <= io_tl_a_bits_size;
            end
            if (h_done) h_pending_g <= 1'b0;
        end
    end

    // ======================================================================
    // ENVIRONMENT ASSUMPTIONS — multi-engine refinements
    // ======================================================================

    // ---- TL master: multi-beat Put A-burst stability.  While we are
    //      inside a Put A burst (between first and last A.fire of the Put),
    //      the master must drive Put beats matching the snapshotted source/
    //      opcode/size — and only Put beats (no Get or Hint interruptions
    //      within the same burst, per TL spec).
    always @(*) if (chk && w_in_burst && io_tl_a_valid) begin
        assume (io_tl_a_bits_opcode == w_xact_opcode);
        assume (io_tl_a_bits_source == w_xact_source);
        assume (io_tl_a_bits_size   == w_xact_size);
    end

    // ---- TL master: single-outstanding-per-engine.  Each engine has one
    //      slot; the master may not issue a new Get while r_pending, a new
    //      Put while w_pending, or a new Hint while h_pending_g.
    always @(*) if (chk && r_pending && io_tl_a_valid)
        assume (!isGetA);
    always @(*) if (chk && w_pending && io_tl_a_valid && !w_in_burst)
        assume (!isPutA);
    always @(*) if (chk && h_pending_g && io_tl_a_valid)
        assume (!isHintA);

    // ---- AXI subordinate: response IDs match the single outstanding
    //      transaction on the corresponding channel.
    always @(*) if (chk && w_pending && io_axi_b_valid)
        assume (io_axi_b_bits_id == w_xact_source);
    always @(*) if (chk && r_pending && io_axi_r_valid)
        assume (io_axi_r_bits_id == r_xact_source);

    // ======================================================================
    // SAFETY ASSERTIONS — all gated on `chk` (f_past_valid && !reset) so
    // they only fire after the design has seen a complete reset.
    // ======================================================================

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

    // F2 — every D beat carries the source snapshotted by the corresponding
    //      engine when it accepted the transaction.  D.opcode selects which
    //      engine's snapshot is the source-of-truth.
    always @(*) if (chk && d_fire && r_pending &&
                    io_tl_d_bits_opcode == 3'd1 /* AccessAckData */)
        assert (io_tl_d_bits_source == r_xact_source);

    always @(*) if (chk && d_fire && w_pending &&
                    io_tl_d_bits_opcode == 3'd0 /* AccessAck */)
        assert (io_tl_d_bits_source == w_xact_source);

    always @(*) if (chk && d_fire && h_pending_g &&
                    io_tl_d_bits_opcode == 3'd2 /* HintAck */)
        assert (io_tl_d_bits_source == h_xact_source);

    // F3 — every D beat's `size` matches the corresponding request's size.
    always @(*) if (chk && d_fire && r_pending &&
                    io_tl_d_bits_opcode == 3'd1)
        assert (io_tl_d_bits_size == r_xact_size);
    always @(*) if (chk && d_fire && w_pending &&
                    io_tl_d_bits_opcode == 3'd0)
        assert (io_tl_d_bits_size == w_xact_size);
    always @(*) if (chk && d_fire && h_pending_g &&
                    io_tl_d_bits_opcode == 3'd2)
        assert (io_tl_d_bits_size == h_xact_size);

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
