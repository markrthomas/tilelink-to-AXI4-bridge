// tluctoaxi4_props.sv — SymbiYosys formal wrapper for TLUCToAXI4
//
// Focused on the NEW behaviors introduced by the TL-UC variant:
//   - Acquire flow:   AcquireBlock → GrantData(toT) ; AcquirePerm → Grant(toT)
//   - Release flow:   Release → ReleaseAck ; ReleaseData → AW+W → B → ReleaseAck
//   - GrantAck path:  TL-E drains exactly one ack per outstanding Acquire
//   - B tied off:     bridge never issues a Probe
//
// The carry-over TL-UH engines (Read/Write/Hint/Atomic/Error) reuse the
// same logic that's already proven by `tluhtoaxi4_props.sv`; we don't
// re-prove their per-engine F2/F3 here.
//
// Properties (F-UC-*):
//   F-UC-1  : `b.valid == 0` always (probes never issued)
//   F-UC-2  : every D.GrantData carries param == toT and source matches
//             the in-flight Acquire's snapshotted source
//   F-UC-3  : every D.Grant carries param == toT and source matches
//             (AcquirePerm path — no data)
//   F-UC-4  : every D.ReleaseAck source matches the in-flight Release's
//             snapshotted source
//   F-UC-5  : AcquireBlock AR/AW alignment + INCR + size = beatSizeLg
//
// Cover goals:
//   C-UC-1  : AcquireBlock completes (GrantData last beat + GrantAck)
//   C-UC-2  : AcquirePerm completes (Grant + GrantAck)
//   C-UC-3  : Release completes (ReleaseAck, no AXI traffic)
//   C-UC-4  : ReleaseData completes (ReleaseAck after AW/W/B)

`default_nettype none
`timescale 1ns/1ps

module tluctoaxi4_props (
    input wire clock
);

    // ----------------------------------------------------------------------
    // Reset phase + f_past_valid (same idiom as TL-UH wrapper).
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
    (* anyseq *) wire [31:0] io_tl_a_bits_address;
    (* anyseq *) wire [7:0]  io_tl_a_bits_mask;
    (* anyseq *) wire [63:0] io_tl_a_bits_data;
    (* anyseq *) wire        io_tl_a_bits_corrupt;
    (* anyseq *) wire        io_tl_b_ready;
    (* anyseq *) wire        io_tl_c_valid;
    (* anyseq *) wire [2:0]  io_tl_c_bits_opcode;
    (* anyseq *) wire [2:0]  io_tl_c_bits_param;
    (* anyseq *) wire [5:0]  io_tl_c_bits_size;
    (* anyseq *) wire [3:0]  io_tl_c_bits_source;
    (* anyseq *) wire [31:0] io_tl_c_bits_address;
    (* anyseq *) wire [63:0] io_tl_c_bits_data;
    (* anyseq *) wire        io_tl_c_bits_corrupt;
    (* anyseq *) wire        io_tl_d_ready;
    (* anyseq *) wire        io_tl_e_valid;
    (* anyseq *) wire        io_tl_e_bits_sink;

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
    // DUT outputs.
    // ----------------------------------------------------------------------
    wire        io_tl_a_ready;
    wire        io_tl_b_valid;
    wire [2:0]  io_tl_b_bits_opcode;
    wire [2:0]  io_tl_b_bits_param;
    wire [5:0]  io_tl_b_bits_size;
    wire [3:0]  io_tl_b_bits_source;
    wire [31:0] io_tl_b_bits_address;
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

    wire        io_axi_aw_valid;
    wire [3:0]  io_axi_aw_bits_id;
    wire [31:0] io_axi_aw_bits_addr;
    wire [7:0]  io_axi_aw_bits_len;
    wire [2:0]  io_axi_aw_bits_size;
    wire [1:0]  io_axi_aw_bits_burst;
    wire        io_axi_aw_bits_lock;
    wire [3:0]  io_axi_aw_bits_cache;
    wire [2:0]  io_axi_aw_bits_prot;
    wire [3:0]  io_axi_aw_bits_qos;
    wire        io_axi_aw_bits_region;
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
    wire        io_axi_ar_bits_lock;
    wire [3:0]  io_axi_ar_bits_cache;
    wire [2:0]  io_axi_ar_bits_prot;
    wire [3:0]  io_axi_ar_bits_qos;
    wire        io_axi_ar_bits_region;
    wire        io_axi_r_ready;

    TLUCToAXI4 dut (
        .clock(clock), .reset(reset),
        // A
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
        // B
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
        // C
        .io_tl_c_ready(io_tl_c_ready),
        .io_tl_c_valid(io_tl_c_valid),
        .io_tl_c_bits_opcode(io_tl_c_bits_opcode),
        .io_tl_c_bits_param(io_tl_c_bits_param),
        .io_tl_c_bits_size(io_tl_c_bits_size),
        .io_tl_c_bits_source(io_tl_c_bits_source),
        .io_tl_c_bits_address(io_tl_c_bits_address),
        .io_tl_c_bits_data(io_tl_c_bits_data),
        .io_tl_c_bits_corrupt(io_tl_c_bits_corrupt),
        // D
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
        // E
        .io_tl_e_ready(io_tl_e_ready),
        .io_tl_e_valid(io_tl_e_valid),
        .io_tl_e_bits_sink(io_tl_e_bits_sink),
        // AXI
        .io_axi_aw_ready(io_axi_aw_ready),
        .io_axi_aw_valid(io_axi_aw_valid),
        .io_axi_aw_bits_id(io_axi_aw_bits_id),
        .io_axi_aw_bits_addr(io_axi_aw_bits_addr),
        .io_axi_aw_bits_len(io_axi_aw_bits_len),
        .io_axi_aw_bits_size(io_axi_aw_bits_size),
        .io_axi_aw_bits_burst(io_axi_aw_bits_burst),
        .io_axi_aw_bits_lock(io_axi_aw_bits_lock),
        .io_axi_aw_bits_cache(io_axi_aw_bits_cache),
        .io_axi_aw_bits_prot(io_axi_aw_bits_prot),
        .io_axi_aw_bits_qos(io_axi_aw_bits_qos),
        .io_axi_aw_bits_region(io_axi_aw_bits_region),
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
        .io_axi_ar_bits_lock(io_axi_ar_bits_lock),
        .io_axi_ar_bits_cache(io_axi_ar_bits_cache),
        .io_axi_ar_bits_prot(io_axi_ar_bits_prot),
        .io_axi_ar_bits_qos(io_axi_ar_bits_qos),
        .io_axi_ar_bits_region(io_axi_ar_bits_region),
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

    // ---- Nothing fires during reset.
    always @(posedge clock) if (reset) begin
        assume (!io_tl_a_valid);
        assume (!io_tl_c_valid);
        assume (!io_tl_e_valid);
    end

    // ---- A opcode envelope (0..7) — all TL-C A opcodes are legal here.
    always @(*) if (io_tl_a_valid)
        assume (io_tl_a_bits_size <= 6'd6);

    // ---- A irrevocability.
    always @(posedge clock) begin
        if (!reset && $past(io_tl_a_valid) && !$past(io_tl_a_ready)) begin
            assume (io_tl_a_valid);
            assume (io_tl_a_bits_opcode  == $past(io_tl_a_bits_opcode));
            assume (io_tl_a_bits_size    == $past(io_tl_a_bits_size));
            assume (io_tl_a_bits_source  == $past(io_tl_a_bits_source));
            assume (io_tl_a_bits_address == $past(io_tl_a_bits_address));
            assume (io_tl_a_bits_mask    == $past(io_tl_a_bits_mask));
            assume (io_tl_a_bits_data    == $past(io_tl_a_bits_data));
            assume (io_tl_a_bits_param   == $past(io_tl_a_bits_param));
        end
    end

    // ---- C opcode envelope: only Release(6) or ReleaseData(7).  ProbeAck
    //      should never arrive because the bridge never issues a Probe; if
    //      a master misbehaves we don't model it.
    always @(*) if (io_tl_c_valid) begin
        assume (io_tl_c_bits_opcode == 3'd6 || io_tl_c_bits_opcode == 3'd7);
        assume (io_tl_c_bits_size <= 6'd6);
    end

    // ---- C irrevocability.
    always @(posedge clock) begin
        if (!reset && $past(io_tl_c_valid) && !$past(io_tl_c_ready)) begin
            assume (io_tl_c_valid);
            assume (io_tl_c_bits_opcode  == $past(io_tl_c_bits_opcode));
            assume (io_tl_c_bits_size    == $past(io_tl_c_bits_size));
            assume (io_tl_c_bits_source  == $past(io_tl_c_bits_source));
            assume (io_tl_c_bits_address == $past(io_tl_c_bits_address));
            assume (io_tl_c_bits_data    == $past(io_tl_c_bits_data));
            assume (io_tl_c_bits_param   == $past(io_tl_c_bits_param));
        end
    end

    // ---- AXI subordinate B/R irrevocability.
    always @(posedge clock) begin
        if (!reset && $past(io_axi_b_valid) && !$past(io_axi_b_ready)) begin
            assume (io_axi_b_valid);
            assume (io_axi_b_bits_id   == $past(io_axi_b_bits_id));
            assume (io_axi_b_bits_resp == $past(io_axi_b_bits_resp));
        end
    end
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
    // GHOST STATE for Acquire and Release engines.
    // ======================================================================
    wire isAcqBlockA = (io_tl_a_bits_opcode == 3'd6);
    wire isAcqPermA  = (io_tl_a_bits_opcode == 3'd7);
    wire isAcquireA  = isAcqBlockA || isAcqPermA;
    wire a_fire = io_tl_a_valid && io_tl_a_ready;
    wire c_fire = io_tl_c_valid && io_tl_c_ready;
    wire d_fire = io_tl_d_valid && io_tl_d_ready;
    wire e_fire = io_tl_e_valid && io_tl_e_ready;

    // ---- Acquire ghost ----
    //   Captures (source, size, hasData) at the admitting A.fire.
    //   acq_pending stays high through GrantAck on E.
    reg       acq_pending;
    reg [3:0] acq_xact_source;
    reg [5:0] acq_xact_size;
    reg       acq_xact_hasData;   // 1 = AcquireBlock, 0 = AcquirePerm
    reg       acq_d_done;         // last D beat of the Grant/GrantData has fired
    initial acq_pending     = 1'b0;
    initial acq_xact_source = 4'd0;
    initial acq_xact_size   = 6'd0;
    initial acq_xact_hasData= 1'b0;
    initial acq_d_done      = 1'b0;

    wire acq_begin = !acq_pending && a_fire && isAcquireA;
    // Acquire D opcodes: 4 = Grant, 5 = GrantData
    wire d_is_grant       = (io_tl_d_bits_opcode == 3'd4);
    wire d_is_grant_data  = (io_tl_d_bits_opcode == 3'd5);
    wire d_is_grant_last  = d_fire &&
                            ((d_is_grant) ||
                             (d_is_grant_data && io_axi_r_valid && io_axi_r_ready &&
                              io_axi_r_bits_last));
    wire acq_end = acq_pending && e_fire;

    always @(posedge clock) begin
        if (reset) begin
            acq_pending      <= 1'b0;
            acq_xact_source  <= 4'd0;
            acq_xact_size    <= 6'd0;
            acq_xact_hasData <= 1'b0;
            acq_d_done       <= 1'b0;
        end else begin
            if (acq_begin) begin
                acq_pending      <= 1'b1;
                acq_xact_source  <= io_tl_a_bits_source;
                acq_xact_size    <= io_tl_a_bits_size;
                acq_xact_hasData <= isAcqBlockA;
                acq_d_done       <= 1'b0;
            end
            if (acq_pending && d_is_grant_last) acq_d_done <= 1'b1;
            if (acq_end) begin
                acq_pending <= 1'b0;
                acq_d_done  <= 1'b0;
            end
        end
    end

    // ---- Release ghost ----
    //   First C.fire of a Release sequence opens the slot; for plain
    //   Release that single C beat is the whole sequence (engine goes
    //   straight to sRelAck).  For ReleaseData the bridge peeks the
    //   first beat without firing C; the engine then drains C in
    //   sRelData and waits for B before D.fire ReleaseAck.
    //   For ghost purposes we treat the slot as open from the first
    //   C.valid we see (rel_begin) through D.fire ReleaseAck (rel_end).
    reg       rel_pending;
    reg [3:0] rel_xact_source;
    reg [5:0] rel_xact_size;
    reg       rel_xact_hasData;
    initial rel_pending      = 1'b0;
    initial rel_xact_source  = 4'd0;
    initial rel_xact_size    = 6'd0;
    initial rel_xact_hasData = 1'b0;

    wire isReleaseC     = (io_tl_c_bits_opcode == 3'd6);
    wire isReleaseDataC = (io_tl_c_bits_opcode == 3'd7);
    wire rel_begin = !rel_pending && io_tl_c_valid &&
                     (isReleaseC || isReleaseDataC);
    // 6 = ReleaseAck on D
    wire rel_end   = rel_pending && d_fire && (io_tl_d_bits_opcode == 3'd6);

    always @(posedge clock) begin
        if (reset) begin
            rel_pending      <= 1'b0;
            rel_xact_source  <= 4'd0;
            rel_xact_size    <= 6'd0;
            rel_xact_hasData <= 1'b0;
        end else begin
            if (rel_begin) begin
                rel_pending      <= 1'b1;
                rel_xact_source  <= io_tl_c_bits_source;
                rel_xact_size    <= io_tl_c_bits_size;
                rel_xact_hasData <= isReleaseDataC;
            end
            if (rel_end) rel_pending <= 1'b0;
        end
    end

    // ======================================================================
    // ENVIRONMENT REFINEMENTS
    // ======================================================================
    // Single-outstanding per acquire / release engine.
    always @(*) if (chk && acq_pending && io_tl_a_valid)
        assume (!isAcquireA);

    // C-channel burst stability.  While rel_pending, any c.valid is part
    // of the in-flight transaction's burst — source/size/opcode must
    // match the snapshot taken at rel_begin (data varies per beat).  This
    // permits ReleaseData multi-beat continuation while still forbidding
    // a fresh new Release on top of a pending one.
    always @(*) if (chk && rel_pending && io_tl_c_valid) begin
        assume (io_tl_c_bits_source == rel_xact_source);
        assume (io_tl_c_bits_size   == rel_xact_size);
        // Continuation beats keep the same opcode as the snapshot.
        if (rel_xact_hasData) assume (io_tl_c_bits_opcode == 3'd7);
        else                  assume (io_tl_c_bits_opcode == 3'd6);
    end

    // Need ghost state for the TL-UH atomic engine here too, so we can
    // express cross-engine source uniqueness between acquire/release and
    // atomic — otherwise the formal engine can pick aSource == acqSource
    // and produce ambiguous AR/AW/B/R counterexamples.  We snapshot the
    // atomic source at A.fire of an atomic and clear on the matching D.
    wire isAtomicA = (io_tl_a_bits_opcode == 3'd2) ||
                     (io_tl_a_bits_opcode == 3'd3);
    reg       atom_pending;
    reg [3:0] atom_xact_source;
    initial atom_pending     = 1'b0;
    initial atom_xact_source = 4'd0;
    wire atom_begin = !atom_pending && a_fire && isAtomicA &&
                      (io_tl_a_bits_size <= 6'd3);
    // Atomic's D is AccessAckData (opcode 1) without concurrent R.fire
    // (R was captured earlier in sARead; D emits from aOldData).
    wire r_fire = io_axi_r_valid && io_axi_r_ready;
    wire atom_end = atom_pending && d_fire && !r_fire &&
                    (io_tl_d_bits_opcode == 3'd1) &&
                    (io_tl_d_bits_source == atom_xact_source);
    always @(posedge clock) begin
        if (reset) begin
            atom_pending     <= 1'b0;
            atom_xact_source <= 4'd0;
        end else begin
            if (atom_begin) begin
                atom_pending     <= 1'b1;
                atom_xact_source <= io_tl_a_bits_source;
            end
            if (atom_end) atom_pending <= 1'b0;
        end
    end
    // Atomic single-outstanding.
    always @(*) if (chk && atom_pending && io_tl_a_valid)
        assume (!isAtomicA);
    // Atomic size restricted to single-beat (legal-size atomics).
    always @(*) if (chk && io_tl_a_valid && isAtomicA)
        assume (io_tl_a_bits_size <= 6'd3);

    // Cross-engine source uniqueness.  Each pair shares either AR/R or
    // AW/B on the AXI side; without distinct IDs the slave's response is
    // ambiguous.  This is a real TL master contract for any host driving
    // multiple engines concurrently.
    always @(*) if (chk && acq_pending && atom_pending)
        assume (acq_xact_source != atom_xact_source);
    always @(*) if (chk && rel_pending && atom_pending)
        assume (rel_xact_source != atom_xact_source);

    // E.valid only when bridge is in acquire-ack state (otherwise meaningless).
    // We don't need to constrain — the bridge ties e.ready := acqState===sAcqAck,
    // so a stray e.valid with !acq_d_done can't progress.  Just require sink=0.
    always @(*) if (io_tl_e_valid) assume (io_tl_e_bits_sink == 1'b0);

    // AXI subordinate: B/R IDs must correspond to a pending engine source.
    // For simplicity we assume single-master, so the acquire engine's R
    // (if AcquireBlock is pending) is the only legitimate R.id source
    // alongside Get's read engine and Atomic's exclusive read.  Constrain
    // R.id to match any of these or block it.  Same logic as TL-UH wrapper,
    // extended with acq_xact_source.

    // ======================================================================
    // SAFETY ASSERTIONS
    // ======================================================================

    // ---- F-UC-1: B is never asserted (bridge ties off probes).
    always @(*) if (chk) assert (io_tl_b_valid == 1'b0);

    // ---- F-UC-2: every D.GrantData beat carries source matching the
    //              pending Acquire and param == toT (0).
    always @(*) if (chk && d_fire && d_is_grant_data) begin
        assert (acq_pending);
        assert (io_tl_d_bits_source == acq_xact_source);
        assert (io_tl_d_bits_param  == 3'd0);
        assert (acq_xact_hasData);
    end

    // ---- F-UC-3: every D.Grant carries source matching the pending
    //              Acquire and param == toT.
    always @(*) if (chk && d_fire && d_is_grant) begin
        assert (acq_pending);
        assert (io_tl_d_bits_source == acq_xact_source);
        assert (io_tl_d_bits_param  == 3'd0);
        assert (!acq_xact_hasData);
    end

    // ---- F-UC-4: every D.ReleaseAck carries source matching the
    //              pending Release.
    always @(*) if (chk && d_fire && io_tl_d_bits_opcode == 3'd6) begin
        assert (rel_pending);
        assert (io_tl_d_bits_source == rel_xact_source);
        assert (io_tl_d_bits_size   == rel_xact_size);
    end

    // ---- F-UC-5: AcquireBlock AR alignment and burst discipline.
    //              When the acquire engine is driving AR (acq_pending,
    //              hasData, no R yet), the AR must be aligned and INCR
    //              with size = beatSizeLg.
    always @(*) if (chk && io_axi_ar_valid && io_axi_ar_bits_id == acq_xact_source && acq_pending) begin
        assert (io_axi_ar_bits_addr[2:0] == 3'd0);
        assert (io_axi_ar_bits_burst == 2'b01);
        assert (io_axi_ar_bits_size  == 3'b011);
        // Atomic engine asserts AR.lock=1; acquire engine does NOT.
        assert (io_axi_ar_bits_lock == 1'b0);
    end

    // ---- Bonus: ReleaseAck never carries corrupt or denied.  The bridge
    //              ties them to 0.
    always @(*) if (chk && io_tl_d_valid && io_tl_d_bits_opcode == 3'd6) begin
        assert (io_tl_d_bits_corrupt == 1'b0);
        assert (io_tl_d_bits_denied  == 1'b0);
    end

    // ---- Bonus: Grant (no data) never carries corrupt.
    always @(*) if (chk && io_tl_d_valid && d_is_grant)
        assert (io_tl_d_bits_corrupt == 1'b0);

    // ======================================================================
    // COVER GOALS
    // ======================================================================

    // C-UC-1 — AcquireBlock completes (last GrantData beat fires).
    always @(*) cover (chk && d_fire && d_is_grant_data &&
                       io_axi_r_valid && io_axi_r_ready && io_axi_r_bits_last);

    // C-UC-2 — AcquirePerm completes (Grant fires, no R).
    always @(*) cover (chk && d_fire && d_is_grant);

    // C-UC-3 — Release (no data) completes (ReleaseAck fires with
    //          rel_xact_hasData = 0).
    always @(*) cover (chk && d_fire && (io_tl_d_bits_opcode == 3'd6) &&
                       rel_pending && !rel_xact_hasData);

    // C-UC-4 — ReleaseData completes (ReleaseAck fires with
    //          rel_xact_hasData = 1).
    always @(*) cover (chk && d_fire && (io_tl_d_bits_opcode == 3'd6) &&
                       rel_pending && rel_xact_hasData);

    // C-UC-5 — GrantAck completes the Acquire flow (E.fire while
    //          acq_pending).
    always @(*) cover (chk && e_fire && acq_pending);

endmodule
