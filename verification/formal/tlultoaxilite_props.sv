// tlultoaxilite_props.sv — SymbiYosys formal wrapper for TLULToAXILite
//
// Instantiates the elaborated SV bridge with unconstrained inputs.  Adds:
//   - TL master compliance assumptions (irrevocable A, valid opcodes/sizes)
//   - AXI-Lite subordinate compliance assumptions (B/R stability while !ready)
//   - Safety assertions (`bmc` task)
//   - Cover goals      (`cover` task)
//
// Properties (mirroring the TL-UH bridge's "F" labels where they apply):
//   F2     : D.source equals the source of the in-flight transaction
//            (per-engine: read, write, hint, local-error)
//   F3     : D.size equals the size of the corresponding request
//   F-UL-1 : AR/AW address is aligned to beatBytes (low log2(beatBytes) zero)
//   F-UL-2 : AXI4-Lite has NO burst/len/size/id/lock fields — verified
//            structurally by emitted port list (top-level lint check, not
//            a runtime assertion)
//
// Cover goals:
//   C1 : write transaction completes (D = AccessAck)
//   C2 : read  transaction completes (D = AccessAckData)
//   C3 : hint  transaction completes (D = HintAck)
//   C4 : local-error transaction completes (D = AccessAck with denied=1)
//
// Defaults match ULBridgeParams():  addrBits=32, dataBits=32, sourceBits=4,
// sizeBits=2, beatSizeLg=2.

`default_nettype none
`timescale 1ns/1ps

module tlultoaxilite_props (
    input wire clock
);

    // ----------------------------------------------------------------------
    // Reset is constrained via a phase counter so the design always sees a
    // clean reset pulse before any assertion fires.
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
    // Free inputs — environment surfaces the formal engine may pick.
    // ----------------------------------------------------------------------
    (* anyseq *) wire        io_tl_a_valid;
    (* anyseq *) wire [2:0]  io_tl_a_bits_opcode;
    (* anyseq *) wire [2:0]  io_tl_a_bits_param;
    (* anyseq *) wire [1:0]  io_tl_a_bits_size;
    (* anyseq *) wire [3:0]  io_tl_a_bits_source;
    (* anyseq *) wire [31:0] io_tl_a_bits_address;
    (* anyseq *) wire [3:0]  io_tl_a_bits_mask;
    (* anyseq *) wire [31:0] io_tl_a_bits_data;
    (* anyseq *) wire        io_tl_a_bits_corrupt;
    (* anyseq *) wire        io_tl_d_ready;

    (* anyseq *) wire        io_axi_aw_ready;
    (* anyseq *) wire        io_axi_w_ready;
    (* anyseq *) wire        io_axi_b_valid;
    (* anyseq *) wire [1:0]  io_axi_b_bits_resp;
    (* anyseq *) wire        io_axi_ar_ready;
    (* anyseq *) wire        io_axi_r_valid;
    (* anyseq *) wire [31:0] io_axi_r_bits_data;
    (* anyseq *) wire [1:0]  io_axi_r_bits_resp;

    // ----------------------------------------------------------------------
    // DUT outputs
    // ----------------------------------------------------------------------
    wire        io_tl_a_ready;
    wire        io_tl_d_valid;
    wire [2:0]  io_tl_d_bits_opcode;
    wire [2:0]  io_tl_d_bits_param;
    wire [1:0]  io_tl_d_bits_size;
    wire [3:0]  io_tl_d_bits_source;
    wire        io_tl_d_bits_sink;
    wire        io_tl_d_bits_denied;
    wire [31:0] io_tl_d_bits_data;
    wire        io_tl_d_bits_corrupt;

    wire        io_axi_aw_valid;
    wire [31:0] io_axi_aw_bits_addr;
    wire [2:0]  io_axi_aw_bits_prot;

    wire        io_axi_w_valid;
    wire [31:0] io_axi_w_bits_data;
    wire [3:0]  io_axi_w_bits_strb;

    wire        io_axi_b_ready;

    wire        io_axi_ar_valid;
    wire [31:0] io_axi_ar_bits_addr;
    wire [2:0]  io_axi_ar_bits_prot;

    wire        io_axi_r_ready;

    TLULToAXILite dut (
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
        .io_axi_aw_bits_addr(io_axi_aw_bits_addr),
        .io_axi_aw_bits_prot(io_axi_aw_bits_prot),

        .io_axi_w_ready(io_axi_w_ready),
        .io_axi_w_valid(io_axi_w_valid),
        .io_axi_w_bits_data(io_axi_w_bits_data),
        .io_axi_w_bits_strb(io_axi_w_bits_strb),

        .io_axi_b_ready(io_axi_b_ready),
        .io_axi_b_valid(io_axi_b_valid),
        .io_axi_b_bits_resp(io_axi_b_bits_resp),

        .io_axi_ar_ready(io_axi_ar_ready),
        .io_axi_ar_valid(io_axi_ar_valid),
        .io_axi_ar_bits_addr(io_axi_ar_bits_addr),
        .io_axi_ar_bits_prot(io_axi_ar_bits_prot),

        .io_axi_r_ready(io_axi_r_ready),
        .io_axi_r_valid(io_axi_r_valid),
        .io_axi_r_bits_data(io_axi_r_bits_data),
        .io_axi_r_bits_resp(io_axi_r_bits_resp)
    );

    // ======================================================================
    // ENVIRONMENT ASSUMPTIONS
    // ======================================================================

    // ---- TL master: nothing during reset.
    always @(posedge clock) if (reset) assume (!io_tl_a_valid);

    // ---- TL master: opcode must be one of TL-UL's supported set plus the
    //      reserved/atomic values (which route to the local-error slot).
    //      Restrict to 0..5 (opcodes the TL spec defines for A); reserved
    //      6/7 stay out so we don't add un-modelled behavior.
    always @(*) if (io_tl_a_valid)
        assume (io_tl_a_bits_opcode <= 3'd5);

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
            assume (io_axi_b_bits_resp == $past(io_axi_b_bits_resp));
        end
    end

    // ---- AXI subordinate: R-channel stability while valid && !ready.
    always @(posedge clock) begin
        if (!reset && $past(io_axi_r_valid) && !$past(io_axi_r_ready)) begin
            assume (io_axi_r_valid);
            assume (io_axi_r_bits_data == $past(io_axi_r_bits_data));
            assume (io_axi_r_bits_resp == $past(io_axi_r_bits_resp));
        end
    end

    // ======================================================================
    // GHOST STATE — one in-flight transaction per bridge engine.
    //
    // Four parallel engines, each holding one outstanding TL transaction:
    //   READ  : Get  → AR + R → AccessAckData
    //   WRITE : Put  → AW + W → AccessAck
    //   HINT  : Hint → (none) → HintAck
    //   ERR   : unsupported/oversized → AccessAck (denied)
    //
    // Each engine snapshots (source, size) on its admitting A.fire and
    // clears its pending flag on the matching D.fire.
    // ======================================================================
    wire isGetA  = (io_tl_a_bits_opcode == 3'd4);
    wire isPutA  = (io_tl_a_bits_opcode == 3'd0) ||
                   (io_tl_a_bits_opcode == 3'd1);
    wire isHintA = (io_tl_a_bits_opcode == 3'd5);
    // TL-UL local-error: unsupported opcode (2/3) OR oversized (size > 2).
    wire isSupported = isGetA || isPutA || isHintA;
    wire sizeLegal   = (io_tl_a_bits_size <= 2'd2);
    wire isErrA      = !isSupported || !sizeLegal;

    wire a_fire = io_tl_a_valid && io_tl_a_ready;
    wire d_fire = io_tl_d_valid && io_tl_d_ready;

    // Disambiguate D-channel arbiter selection.  The bridge ties
    //   io_axi_b_ready := tl.d.ready  only in the dSelW branch
    //   io_axi_r_ready := tl.d.ready  only in the dSelR branch
    // Defaults are 0 elsewhere — so these signals identify which engine
    // drove the current D beat, independent of opcode/denied bits.
    wire d_from_w = d_fire && io_axi_b_ready;
    wire d_from_r = d_fire && io_axi_r_ready;
    wire d_from_he = d_fire && !io_axi_b_ready && !io_axi_r_ready;

    // ---- READ engine ghost ----
    reg       r_pending;
    reg [3:0] r_xact_source;
    reg [1:0] r_xact_size;
    initial r_pending     = 1'b0;
    initial r_xact_source = 4'd0;
    initial r_xact_size   = 2'd0;

    wire r_begin = !r_pending && a_fire && isGetA && !isErrA;
    wire r_done  = r_pending && d_from_r;

    always @(posedge clock) begin
        if (reset) begin
            r_pending     <= 1'b0;
            r_xact_source <= 4'd0;
            r_xact_size   <= 2'd0;
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
    reg       w_pending;
    reg [3:0] w_xact_source;
    reg [1:0] w_xact_size;
    initial w_pending     = 1'b0;
    initial w_xact_source = 4'd0;
    initial w_xact_size   = 2'd0;

    wire w_begin = !w_pending && a_fire && isPutA && !isErrA;
    // W path is the only one that asserts io_axi_b_ready, so d_from_w
    // unambiguously identifies a Write engine response — even when the
    // AccessAck carries denied=1 due to BRESP error.
    wire w_done  = w_pending && d_from_w;

    always @(posedge clock) begin
        if (reset) begin
            w_pending     <= 1'b0;
            w_xact_source <= 4'd0;
            w_xact_size   <= 2'd0;
        end else begin
            if (w_begin) begin
                w_pending     <= 1'b1;
                w_xact_source <= io_tl_a_bits_source;
                w_xact_size   <= io_tl_a_bits_size;
            end
            if (w_done) w_pending <= 1'b0;
        end
    end

    // ---- HINT engine ghost ----
    reg       h_pending_g;
    reg [3:0] h_xact_source;
    reg [1:0] h_xact_size;
    initial h_pending_g   = 1'b0;
    initial h_xact_source = 4'd0;
    initial h_xact_size   = 2'd0;

    wire h_begin = !h_pending_g && a_fire && isHintA && !isErrA;
    // H path doesn't touch b.ready or r.ready; HintAck opcode further
    // distinguishes from a potential E response on the same cycle.
    wire h_done  = h_pending_g && d_from_he &&
                   (io_tl_d_bits_opcode == 3'd2) /* HintAck */;

    always @(posedge clock) begin
        if (reset) begin
            h_pending_g   <= 1'b0;
            h_xact_source <= 4'd0;
            h_xact_size   <= 2'd0;
        end else begin
            if (h_begin) begin
                h_pending_g   <= 1'b1;
                h_xact_source <= io_tl_a_bits_source;
                h_xact_size   <= io_tl_a_bits_size;
            end
            if (h_done) h_pending_g <= 1'b0;
        end
    end

    // ---- ERROR engine ghost ----
    reg       e_pending;
    reg [3:0] e_xact_source;
    reg [1:0] e_xact_size;
    initial e_pending     = 1'b0;
    initial e_xact_source = 4'd0;
    initial e_xact_size   = 2'd0;

    wire e_begin = !e_pending && a_fire && isErrA;
    // E response is AccessAck with denied=1 emitted from the local-error
    // slot — neither b.ready nor r.ready is asserted in dSelE.
    wire e_done  = e_pending && d_from_he &&
                   (io_tl_d_bits_opcode == 3'd0) /* AccessAck */ &&
                   io_tl_d_bits_denied;

    always @(posedge clock) begin
        if (reset) begin
            e_pending     <= 1'b0;
            e_xact_source <= 4'd0;
            e_xact_size   <= 2'd0;
        end else begin
            if (e_begin) begin
                e_pending     <= 1'b1;
                e_xact_source <= io_tl_a_bits_source;
                e_xact_size   <= io_tl_a_bits_size;
            end
            if (e_done) e_pending <= 1'b0;
        end
    end

    // ======================================================================
    // ENVIRONMENT ASSUMPTIONS — single-outstanding-per-engine
    // ======================================================================

    // Each engine has one slot; master may not issue a second transaction of
    // the same opcode kind until the first one's D has fired.
    always @(*) if (chk && r_pending && io_tl_a_valid)
        assume (!isGetA  || isErrA);
    always @(*) if (chk && w_pending && io_tl_a_valid)
        assume (!isPutA  || isErrA);
    always @(*) if (chk && h_pending_g && io_tl_a_valid)
        assume (!isHintA || isErrA);
    always @(*) if (chk && e_pending && io_tl_a_valid)
        assume (!isErrA);

    // AXI subordinate: B/R responses are bounded by the bridge's engine
    // state.  No need to differentiate by ID — AXI-Lite carries none.
    always @(*) if (chk && io_axi_b_valid) assume (w_pending);
    always @(*) if (chk && io_axi_r_valid) assume (r_pending);

    // ======================================================================
    // SAFETY ASSERTIONS — all gated on `chk` so they only fire post-reset.
    // ======================================================================

    // F-UL-1 — AW/AR addresses are aligned to beatBytes (low 2 bits zero
    // for dataBits=32).
    always @(*) if (chk && io_axi_aw_valid)
        assert (io_axi_aw_bits_addr[1:0] == 2'd0);
    always @(*) if (chk && io_axi_ar_valid)
        assert (io_axi_ar_bits_addr[1:0] == 2'd0);

    // F2 — D source matches the corresponding engine's snapshot.  The
    //       d_from_{w,r,he} signals identify which engine the arbiter
    //       selected, independent of opcode/denied combinations.
    always @(*) if (chk && d_from_r && r_pending)
        assert (io_tl_d_bits_source == r_xact_source);

    always @(*) if (chk && d_from_w && w_pending)
        assert (io_tl_d_bits_source == w_xact_source);

    always @(*) if (chk && d_from_he && h_pending_g &&
                    io_tl_d_bits_opcode == 3'd2 /* HintAck */)
        assert (io_tl_d_bits_source == h_xact_source);

    always @(*) if (chk && d_from_he && e_pending &&
                    io_tl_d_bits_opcode == 3'd0 /* AccessAck */ &&
                    io_tl_d_bits_denied)
        assert (io_tl_d_bits_source == e_xact_source);

    // F3 — D size matches the corresponding engine's snapshot.
    always @(*) if (chk && d_from_r && r_pending)
        assert (io_tl_d_bits_size == r_xact_size);

    always @(*) if (chk && d_from_w && w_pending)
        assert (io_tl_d_bits_size == w_xact_size);

    always @(*) if (chk && d_from_he && h_pending_g &&
                    io_tl_d_bits_opcode == 3'd2)
        assert (io_tl_d_bits_size == h_xact_size);

    always @(*) if (chk && d_from_he && e_pending &&
                    io_tl_d_bits_opcode == 3'd0 && io_tl_d_bits_denied)
        assert (io_tl_d_bits_size == e_xact_size);

    // Bonus — writes / hints / errors never set D.corrupt.  Only an
    // AccessAckData carrying SLVERR/DECERR may set corrupt.
    always @(*) if (chk && io_tl_d_valid &&
                    (io_tl_d_bits_opcode == 3'd0 || io_tl_d_bits_opcode == 3'd2))
        assert (io_tl_d_bits_corrupt == 1'b0);

    // ======================================================================
    // COVER GOALS
    // ======================================================================

    // C1 — write transaction completes (AccessAck, not denied).
    always @(*) cover (chk && d_from_w && w_pending && !io_tl_d_bits_denied);

    // C2 — read transaction completes (AccessAckData).
    always @(*) cover (chk && d_from_r && r_pending);

    // C3 — hint transaction completes (HintAck).
    always @(*) cover (chk && d_from_he && h_pending_g &&
                       io_tl_d_bits_opcode == 3'd2);

    // C4 — local-error transaction completes (denied AccessAck).
    always @(*) cover (chk && d_from_he && e_pending &&
                       io_tl_d_bits_opcode == 3'd0 && io_tl_d_bits_denied);

endmodule
