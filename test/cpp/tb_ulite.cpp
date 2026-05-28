// TLULToAXILite Verilator testbench
//   - Drives TileLink-UL on the bridge slave port
//   - Models a behavioral AXI4-Lite memory slave on the master port
//   - Compares D-channel responses against a reference memory model
//
// Default DUT params (must match Chisel side):
//   addrBits=32, dataBits=32, sourceBits=4, beatBytes=4, sizeBits=2

#include "VTLULToAXILite.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>
#include <deque>
#include <map>
#include <cassert>
#include <string>

// ---------- Parameters ----------
static constexpr int DATA_BITS    = 32;
static constexpr int BEAT_BYTES   = DATA_BITS / 8;            // 4
static constexpr int BEAT_BYTES_M = BEAT_BYTES - 1;
static constexpr int BEAT_SIZE_LG = 2;                        // log2(4)
static constexpr uint8_t FULL_MASK = (uint8_t)((1u << BEAT_BYTES) - 1u);

// TL A opcodes
static constexpr int OP_PutFull = 0;
static constexpr int OP_PutPart = 1;
static constexpr int OP_Get     = 4;
static constexpr int OP_Hint    = 5;
static constexpr int OP_Illegal = 6;
// TL D opcodes
static constexpr int D_AccessAck     = 0;
static constexpr int D_AccessAckData = 1;
static constexpr int D_HintAck       = 2;

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static int errs = 0;
#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        std::fprintf(stderr, __VA_ARGS__); \
        std::fprintf(stderr, "\n"); \
        errs++; \
    } \
} while (0)

// ---------------- TL transactions ----------------
struct TLRequest {
    int      opcode;
    int      size;
    int      source;
    uint32_t address;
    uint32_t data = 0;   // writes only
    uint8_t  mask = 0;   // writes only
};

struct TLResponse {
    int      opcode;
    int      size;
    int      source;
    bool     denied;
    bool     corrupt;
    uint32_t data;       // AccessAckData only
};

// ---------------- TL driver / D collector ----------------
//
// TL-UL is single-beat, so the driver simply presents A.valid until A.ready
// then advances to the next request.  D responses are decoupled per engine
// (read / write / hint / local-error) by source.
class TLDriver {
public:
    std::deque<TLRequest>  reqQ;
    std::deque<TLResponse> doneResps;

    bool      reqActive = false;
    TLRequest curReq;

    int outstandingGet  = 0;
    int outstandingPut  = 0;
    int outstandingHint = 0;
    int outstandingErr  = 0;
    int peakConcurrency = 0;

    void drive(VTLULToAXILite* dut) {
        if (!reqActive && !reqQ.empty()) {
            curReq = reqQ.front();
            reqQ.pop_front();
            reqActive = true;
        }
        if (reqActive) {
            dut->io_tl_a_valid        = 1;
            dut->io_tl_a_bits_opcode  = curReq.opcode;
            dut->io_tl_a_bits_param   = 0;
            dut->io_tl_a_bits_size    = curReq.size;
            dut->io_tl_a_bits_source  = curReq.source;
            dut->io_tl_a_bits_address = curReq.address;
            dut->io_tl_a_bits_corrupt = 0;
            if (curReq.opcode == OP_PutFull || curReq.opcode == OP_PutPart) {
                dut->io_tl_a_bits_data = curReq.data;
                dut->io_tl_a_bits_mask = curReq.mask;
            } else {
                dut->io_tl_a_bits_data = 0;
                dut->io_tl_a_bits_mask = FULL_MASK;
            }
        } else {
            dut->io_tl_a_valid        = 0;
            dut->io_tl_a_bits_opcode  = 0;
            dut->io_tl_a_bits_param   = 0;
            dut->io_tl_a_bits_size    = 0;
            dut->io_tl_a_bits_source  = 0;
            dut->io_tl_a_bits_address = 0;
            dut->io_tl_a_bits_data    = 0;
            dut->io_tl_a_bits_mask    = 0;
            dut->io_tl_a_bits_corrupt = 0;
        }
        // Apply some D backpressure so the arbiter is exercised.
        int cyc = (int)(main_time >> 1);
        dut->io_tl_d_ready = (cyc % 7 == 3) ? 0 : 1;
    }

    void sample(VTLULToAXILite* dut) {
        if (reqActive && dut->io_tl_a_valid && dut->io_tl_a_ready) {
            bool legal = (curReq.size <= BEAT_SIZE_LG);
            bool supported = (curReq.opcode == OP_Get  ||
                              curReq.opcode == OP_PutFull ||
                              curReq.opcode == OP_PutPart ||
                              curReq.opcode == OP_Hint);
            if (!supported || !legal) {
                outstandingErr++;
            } else if (curReq.opcode == OP_Get) {
                outstandingGet++;
            } else if (curReq.opcode == OP_Hint) {
                outstandingHint++;
            } else {
                outstandingPut++;
            }
            reqActive = false;
            int now = outstandingGet + outstandingPut + outstandingHint + outstandingErr;
            if (now > peakConcurrency) peakConcurrency = now;
        }
        if (dut->io_tl_d_valid && dut->io_tl_d_ready) {
            TLResponse r;
            r.opcode  = dut->io_tl_d_bits_opcode;
            r.size    = dut->io_tl_d_bits_size;
            r.source  = dut->io_tl_d_bits_source;
            r.denied  = dut->io_tl_d_bits_denied;
            r.corrupt = dut->io_tl_d_bits_corrupt;
            r.data    = dut->io_tl_d_bits_data;
            doneResps.push_back(r);
            if (r.opcode == D_AccessAckData) {
                if (outstandingGet > 0) outstandingGet--;
            } else if (r.opcode == D_HintAck) {
                if (outstandingHint > 0) outstandingHint--;
            } else if (r.opcode == D_AccessAck) {
                // Either a successful Put response or a local-error denied
                // AccessAck.  Drain Put first, then Err — matches the bridge's
                // arbiter order (W > R > H > E) so a Put always precedes a
                // local-error response when both happen to be queued.
                if (r.denied && outstandingErr > 0) outstandingErr--;
                else if (outstandingPut > 0)        outstandingPut--;
                else if (outstandingErr > 0)        outstandingErr--;
            }
        }
    }
};

// ---------------- Behavioral AXI4-Lite slave ----------------
//
// No bursts, no IDs, no ordering across channels — AW and W may arrive in
// either order.  We accept whichever arrives first into a pending slot then
// commit when both are present and emit B; AR fires R immediately on the
// next handshake.  Error injection: address 0xD00 returns RRESP=SLVERR (2)
// on reads; address 0xD80 returns BRESP=DECERR (3) on writes.
class AxiLiteSlave {
public:
    std::map<uint32_t, uint8_t> mem;

    // Outstanding write: AW + W collected before B is emitted.
    bool     awCaptured = false;
    bool     wCaptured  = false;
    uint32_t awAddr = 0;
    uint32_t wData  = 0;
    uint8_t  wStrb  = 0;
    bool     bPending = false;
    int      bResp = 0;

    // Outstanding read.
    bool     arActive = false;
    uint32_t arAddr   = 0;
    bool     rPending = false;
    uint32_t rData    = 0;
    int      rResp    = 0;

    void drive(VTLULToAXILite* dut) {
        int cyc = (int)(main_time >> 1);
        dut->io_axi_aw_ready = (!awCaptured && !bPending && (cyc % 5 != 1)) ? 1 : 0;
        dut->io_axi_w_ready  = (!wCaptured  && !bPending && (cyc % 7 != 2)) ? 1 : 0;

        dut->io_axi_b_valid    = bPending ? 1 : 0;
        dut->io_axi_b_bits_resp = bPending ? bResp : 0;

        dut->io_axi_ar_ready = (!arActive && !rPending && (cyc % 6 != 3)) ? 1 : 0;

        if (rPending) {
            dut->io_axi_r_valid     = 1;
            dut->io_axi_r_bits_data = rData;
            dut->io_axi_r_bits_resp = rResp;
        } else {
            dut->io_axi_r_valid     = 0;
            dut->io_axi_r_bits_data = 0;
            dut->io_axi_r_bits_resp = 0;
        }
    }

    void sample(VTLULToAXILite* dut) {
        // AW
        if (dut->io_axi_aw_valid && dut->io_axi_aw_ready && !awCaptured) {
            awAddr     = dut->io_axi_aw_bits_addr;
            awCaptured = true;
        }
        // W
        if (dut->io_axi_w_valid && dut->io_axi_w_ready && !wCaptured) {
            wData     = dut->io_axi_w_bits_data;
            wStrb     = dut->io_axi_w_bits_strb;
            wCaptured = true;
        }
        // Both AW and W in hand — commit to memory and stage the B response.
        if (awCaptured && wCaptured && !bPending) {
            uint32_t base = awAddr & ~(uint32_t)BEAT_BYTES_M;
            for (int b = 0; b < BEAT_BYTES; b++) {
                if (wStrb & (1u << b)) {
                    mem[base + b] = (uint8_t)((wData >> (8*b)) & 0xFFu);
                }
            }
            bResp = ((awAddr & 0xFFFu) == 0xD80u) ? 3 : 0;
            bPending   = true;
            awCaptured = false;
            wCaptured  = false;
        }
        // B
        if (dut->io_axi_b_valid && dut->io_axi_b_ready && bPending) {
            bPending = false;
        }
        // AR
        if (dut->io_axi_ar_valid && dut->io_axi_ar_ready && !arActive) {
            arAddr   = dut->io_axi_ar_bits_addr;
            arActive = true;
        }
        // Materialize the R response.
        if (arActive && !rPending) {
            uint32_t base = arAddr & ~(uint32_t)BEAT_BYTES_M;
            uint32_t d = 0;
            for (int b = 0; b < BEAT_BYTES; b++) {
                auto it = mem.find(base + b);
                uint8_t byte = (it == mem.end()) ? 0 : it->second;
                d |= ((uint32_t)byte) << (8*b);
            }
            rData    = d;
            rResp    = ((arAddr & 0xFFFu) == 0xD00u) ? 2 : 0;
            rPending = true;
        }
        // R
        if (dut->io_axi_r_valid && dut->io_axi_r_ready && rPending) {
            rPending = false;
            arActive = false;
        }
    }
};

// ---------------- Reference memory ----------------
class RefMem {
public:
    std::map<uint32_t, uint8_t> bytes;

    void apply(const TLRequest& r) {
        if (r.opcode != OP_PutFull && r.opcode != OP_PutPart) return;
        uint32_t base = r.address & ~(uint32_t)BEAT_BYTES_M;
        for (int b = 0; b < BEAT_BYTES; b++) {
            if (r.mask & (1u << b)) {
                bytes[base + b] = (uint8_t)((r.data >> (8*b)) & 0xFFu);
            }
        }
    }

    uint32_t beat(uint32_t address) const {
        uint32_t d = 0;
        uint32_t base = address & ~(uint32_t)BEAT_BYTES_M;
        for (int b = 0; b < BEAT_BYTES; b++) {
            auto it = bytes.find(base + b);
            uint8_t byte = (it == bytes.end()) ? 0 : it->second;
            d |= ((uint32_t)byte) << (8*b);
        }
        return d;
    }
};

// ---------------- Request helpers ----------------
static TLRequest mkPutFull(uint32_t addr, int size, int src, uint32_t data) {
    TLRequest r;
    r.opcode = OP_PutFull;
    r.size = size; r.source = src; r.address = addr;
    r.data = data;
    if ((1 << size) < BEAT_BYTES) {
        int nbytes = 1 << size;
        int off    = addr & BEAT_BYTES_M;
        r.mask = (uint8_t)(((1u << nbytes) - 1u) << off);
    } else {
        r.mask = FULL_MASK;
    }
    return r;
}

static TLRequest mkPutPart(uint32_t addr, int size, int src,
                            uint32_t data, uint8_t mask) {
    TLRequest r;
    r.opcode = OP_PutPart;
    r.size = size; r.source = src; r.address = addr;
    r.data = data; r.mask = mask;
    return r;
}

static TLRequest mkGet(uint32_t addr, int size, int src) {
    TLRequest r;
    r.opcode = OP_Get;
    r.size = size; r.source = src; r.address = addr;
    return r;
}

static TLRequest mkHint(uint32_t addr, int size, int src) {
    TLRequest r;
    r.opcode = OP_Hint;
    r.size = size; r.source = src; r.address = addr;
    return r;
}

static TLRequest mkUnsupported(uint32_t addr, int size, int src) {
    TLRequest r;
    r.opcode = OP_Illegal;
    r.size = size; r.source = src; r.address = addr;
    return r;
}

static TLRequest mkOversize(uint32_t addr, int src) {
    // TL-UL only permits size <= log2(beatBytes) = 2; size=3 triggers the
    // local-error slot.  Treat it as a Get so opcode is supported but size
    // is rejected.
    TLRequest r;
    r.opcode = OP_Get;
    r.size = BEAT_SIZE_LG + 1; r.source = src; r.address = addr;
    return r;
}

// ---------------- Main ----------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* dut = new VTLULToAXILite;

    Verilated::traceEverOn(true);
    auto* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("sim_ulite.vcd");

    TLDriver     tl;
    AxiLiteSlave axi;
    RefMem       ref;

    auto step = [&]() {
        // Sampling between the two evals — same ordering rule as tb_main.cpp.
        dut->clock = 0;
        tl.drive(dut);
        axi.drive(dut);
        dut->eval();
        tl.sample(dut);
        axi.sample(dut);
        tfp->dump(main_time++);
        dut->clock = 1;
        dut->eval();
        tfp->dump(main_time++);
    };

    // Reset
    dut->reset = 1;
    dut->clock = 0;
    dut->eval();
    for (int i = 0; i < 8; i++) step();
    dut->reset = 0;

    // ---------- Build a job list ----------
    struct Job {
        TLRequest req;
        bool      expectAckData;
        int       expectOpcode;
        bool      expectDenied;
        bool      expectCorrupt;
        uint32_t  expectData;
    };
    std::vector<Job> jobs;
    std::map<int, std::deque<size_t>> jobIdxBySource;

    auto enqueue = [&](TLRequest req, bool expectDenied = false,
                       bool expectCorrupt = false, bool expectLocalError = false) {
        Job j;
        j.req = req;
        j.expectDenied = expectDenied;
        j.expectCorrupt = expectCorrupt;
        j.expectData = 0;
        if (expectLocalError) {
            j.expectAckData = false;
            j.expectOpcode = D_AccessAck;
            j.expectDenied = true;
        } else if (req.opcode == OP_PutFull || req.opcode == OP_PutPart) {
            ref.apply(req);
            j.expectAckData = false;
            j.expectOpcode = D_AccessAck;
        } else if (req.opcode == OP_Get) {
            j.expectAckData = true;
            j.expectOpcode = D_AccessAckData;
            j.expectData = ref.beat(req.address);
        } else if (req.opcode == OP_Hint) {
            j.expectAckData = false;
            j.expectOpcode = D_HintAck;
        } else {
            j.expectAckData = false;
            j.expectOpcode = D_AccessAck;
            j.expectDenied = true;
        }
        jobIdxBySource[req.source].push_back(jobs.size());
        jobs.push_back(std::move(j));
        tl.reqQ.push_back(req);
    };

    auto wait_all = [&]() {
        const int TIMEOUT = 5000;
        int start = main_time;
        while (main_time - start < TIMEOUT) {
            step();
            if (tl.reqQ.empty() && !tl.reqActive &&
                tl.outstandingGet == 0 && tl.outstandingPut == 0 &&
                tl.outstandingHint == 0 && tl.outstandingErr == 0) return;
        }
        std::fprintf(stderr, "wait_all: TIMEOUT\n");
        errs++;
    };

    // Test 1: 32-bit aligned write + read
    enqueue(mkPutFull(0x100, 2, 1, 0xDEADBEEFu));
    enqueue(mkGet    (0x100, 2, 2));
    wait_all();

    // Test 2: byte (size=0) write+read at each lane
    for (int off = 0; off < BEAT_BYTES; off++) {
        uint32_t a = 0x200u + off;
        uint32_t v = ((uint32_t)(0xA0u + off)) << (8*off);
        enqueue(mkPutFull(a, 0, 3, v));
        enqueue(mkGet    (a, 0, 4));
        wait_all();
    }

    // Test 3: 16-bit (size=1) writes at low and high half
    enqueue(mkPutFull(0x300, 1, 5, 0x0000BEEFu));
    enqueue(mkPutFull(0x302, 1, 5, 0xCAFE0000u));
    enqueue(mkGet    (0x300, 2, 6));
    wait_all();

    // Test 4: PutPartialData — keep bytes 1 and 2 only.
    enqueue(mkPutPart(0x400, 2, 7, 0xAABBCCDDu, (uint8_t)0b0110));
    enqueue(mkGet    (0x400, 2, 8));
    wait_all();

    // Test 5: Hint round-trip.
    enqueue(mkHint(0x500, 2, 9));
    wait_all();

    // Test 6: explicit concurrency — Put + Get + Hint with distinct sources.
    enqueue(mkPutFull(0x600, 2, 0, 0x55AA55AAu));
    enqueue(mkGet    (0x700, 2, 1));
    enqueue(mkHint   (0x800, 2, 2));
    enqueue(mkGet    (0x600, 2, 3));  // verify the Put landed
    wait_all();

    // Test 7: AXI read error injection (RRESP=SLVERR at 0xD00).
    enqueue(mkGet(0xD00, 2, 4), /*denied=*/true, /*corrupt=*/true);
    wait_all();

    // Test 8: AXI write error injection (BRESP=DECERR at 0xD80).
    enqueue(mkPutFull(0xD80, 2, 5, 0xFEEDFACEu), /*denied=*/true);
    wait_all();

    // Test 9: unsupported opcode → local-error slot.
    enqueue(mkUnsupported(0xE00, 2, 6), /*denied=*/false, /*corrupt=*/false,
            /*expectLocalError=*/true);
    wait_all();

    // Test 10: oversized request → local-error slot.
    enqueue(mkOversize(0xE40, 7), /*denied=*/false, /*corrupt=*/false,
            /*expectLocalError=*/true);
    wait_all();

    // Drain a few extra cycles in case anything is still settling.
    for (int i = 0; i < 50; i++) step();

    // ---------- Verify ----------
    for (auto& resp : tl.doneResps) {
        auto& q = jobIdxBySource[resp.source];
        if (q.empty()) {
            std::fprintf(stderr, "FAIL: D source=%d with no pending job\n", resp.source);
            errs++; continue;
        }
        size_t idx = q.front();
        q.pop_front();
        const Job& j = jobs[idx];
        CHECK(resp.opcode  == j.expectOpcode,
              "job %zu source=%d: opcode got=%d want=%d", idx, resp.source,
              resp.opcode, j.expectOpcode);
        CHECK(resp.size    == j.req.size,
              "job %zu source=%d: size got=%d want=%d", idx, resp.source,
              resp.size, j.req.size);
        CHECK(resp.denied  == j.expectDenied,
              "job %zu source=%d: denied got=%d want=%d", idx, resp.source,
              (int)resp.denied, (int)j.expectDenied);
        CHECK(resp.corrupt == j.expectCorrupt,
              "job %zu source=%d: corrupt got=%d want=%d", idx, resp.source,
              (int)resp.corrupt, (int)j.expectCorrupt);
        if (j.expectAckData && !j.expectDenied) {
            CHECK(resp.data == j.expectData,
                  "job %zu source=%d: data got=0x%08x want=0x%08x",
                  idx, resp.source, resp.data, j.expectData);
        }
    }

    // Any leftover jobs that never got a response?
    for (auto& kv : jobIdxBySource) {
        for (size_t idx : kv.second) {
            std::fprintf(stderr, "FAIL: source=%d job %zu never received D\n",
                         kv.first, idx);
            errs++;
        }
    }

    tfp->close();
    delete dut;

    std::printf("ulite TB: %zu jobs, %d errors, peakConcurrency=%d, ticks=%llu\n",
                jobs.size(), errs, tl.peakConcurrency,
                (unsigned long long)(main_time / 2));
    return (errs == 0) ? 0 : 1;
}
