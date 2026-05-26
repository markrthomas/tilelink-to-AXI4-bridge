// TLUHToAXI4 Verilator testbench
//   - Drives TileLink-UH on the bridge slave port
//   - Models a behavioral AXI4 memory slave on the master port
//   - Compares D-channel responses against a reference memory model
//
// Default DUT params (must match Chisel side):
//   addrBits=32, dataBits=64, sourceBits=4, sizeBits=6

#include "VTLUHToAXI4.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>
#include <deque>
#include <map>
#include <random>
#include <cassert>
#include <string>

// ---------- Parameters ----------
static constexpr int DATA_BITS    = 64;
static constexpr int BEAT_BYTES   = DATA_BITS / 8;            // 8
static constexpr int BEAT_BYTES_M = BEAT_BYTES - 1;
static constexpr int BEAT_SIZE_LG = 3;                        // log2(8)
static constexpr uint8_t FULL_MASK = (uint8_t)((1u << BEAT_BYTES) - 1u);

// TL A opcodes
static constexpr int OP_PutFull = 0;
static constexpr int OP_PutPart = 1;
static constexpr int OP_Get     = 4;
static constexpr int OP_Hint    = 5;
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

static int computeBeats(int size) {
    int totalBytes = 1 << size;
    return (totalBytes <= BEAT_BYTES) ? 1 : (totalBytes / BEAT_BYTES);
}

// ---------------- TL transactions ----------------
struct TLRequest {
    int opcode;
    int size;
    int source;
    uint32_t address;
    std::vector<uint64_t> data;   // beats (writes only)
    std::vector<uint8_t>  mask;   // beats (writes only)
    // For Get/Hint: bookkeeping (expected response opcode/size/etc.)
};

struct TLResponse {
    int opcode;
    int size;
    int source;
    bool denied;
    bool corrupt;
    std::vector<uint64_t> data;   // beats (AccessAckData only)
};

// ---------------- TL driver / D collector ----------------
class TLDriver {
public:
    std::deque<TLRequest>  reqQ;
    std::deque<TLResponse> doneResps;

    // Active outbound request
    bool      reqActive = false;
    TLRequest curReq;
    int       beatIdx = 0;

    // In-progress response assembly
    bool       respActive = false;
    TLResponse curResp;
    int        respBeats = 1;
    int        respBeatIdx = 0;

    void drive(VTLUHToAXI4* dut) {
        if (!reqActive && !reqQ.empty()) {
            curReq = reqQ.front();
            reqQ.pop_front();
            reqActive = true;
            beatIdx = 0;
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
                dut->io_tl_a_bits_data = curReq.data[beatIdx];
                dut->io_tl_a_bits_mask = curReq.mask[beatIdx];
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
        dut->io_tl_d_ready = 1; // always accept
    }

    void sample(VTLUHToAXI4* dut) {
        // A handshake
        if (reqActive && dut->io_tl_a_valid && dut->io_tl_a_ready) {
            bool isPut = (curReq.opcode == OP_PutFull) || (curReq.opcode == OP_PutPart);
            if (isPut) {
                int beats = computeBeats(curReq.size);
                beatIdx++;
                if (beatIdx >= beats) reqActive = false;
            } else {
                reqActive = false;
            }
        }
        // D handshake
        if (dut->io_tl_d_valid && dut->io_tl_d_ready) {
            if (!respActive) {
                curResp.opcode  = dut->io_tl_d_bits_opcode;
                curResp.size    = dut->io_tl_d_bits_size;
                curResp.source  = dut->io_tl_d_bits_source;
                curResp.denied  = dut->io_tl_d_bits_denied;
                curResp.corrupt = dut->io_tl_d_bits_corrupt;
                curResp.data.clear();
                respBeats = (curResp.opcode == D_AccessAckData)
                                ? computeBeats(curResp.size) : 1;
                respBeatIdx = 0;
                respActive = true;
            }
            if (dut->io_tl_d_bits_opcode == D_AccessAckData) {
                curResp.data.push_back(dut->io_tl_d_bits_data);
            }
            respBeatIdx++;
            if (respBeatIdx >= respBeats) {
                doneResps.push_back(curResp);
                respActive = false;
            }
        }
    }
};

// ---------------- Behavioral AXI4 slave ----------------
class AXISlave {
public:
    std::map<uint32_t, uint8_t> mem;

    // AW/W
    bool     awCaptured = false;
    uint32_t awAddr = 0;
    int      awLen  = 0;
    int      awSize = 0;
    int      awId   = 0;
    int      wBeats = 0;

    bool bPending = false;
    int  bId      = 0;

    // AR/R
    bool     arActive  = false;
    uint32_t arAddr    = 0;
    int      arLen     = 0;
    int      arSize    = 0;
    int      arId      = 0;
    int      rBeats    = 0;

    void drive(VTLUHToAXI4* dut) {
        dut->io_axi_aw_ready = (!awCaptured && !bPending) ? 1 : 0;
        dut->io_axi_w_ready  = (awCaptured) ? 1 : 0;

        dut->io_axi_b_valid    = bPending ? 1 : 0;
        dut->io_axi_b_bits_id  = bPending ? bId : 0;
        dut->io_axi_b_bits_resp = 0;

        dut->io_axi_ar_ready = (!arActive) ? 1 : 0;

        if (arActive) {
            dut->io_axi_r_valid = 1;
            uint64_t d = 0;
            uint32_t baseAddr = arAddr & ~(uint32_t)BEAT_BYTES_M;
            uint32_t beatAddr = baseAddr + (uint32_t)rBeats * BEAT_BYTES;
            for (int b = 0; b < BEAT_BYTES; b++) {
                auto it = mem.find(beatAddr + b);
                uint8_t byte = (it == mem.end()) ? 0 : it->second;
                d |= ((uint64_t)byte) << (8*b);
            }
            dut->io_axi_r_bits_data  = d;
            dut->io_axi_r_bits_id    = arId;
            dut->io_axi_r_bits_resp  = 0;
            dut->io_axi_r_bits_last  = (rBeats == arLen) ? 1 : 0;
        } else {
            dut->io_axi_r_valid     = 0;
            dut->io_axi_r_bits_data = 0;
            dut->io_axi_r_bits_id   = 0;
            dut->io_axi_r_bits_resp = 0;
            dut->io_axi_r_bits_last = 0;
        }
    }

    void sample(VTLUHToAXI4* dut) {
        // AW
        if (dut->io_axi_aw_valid && dut->io_axi_aw_ready && !awCaptured) {
            awAddr     = dut->io_axi_aw_bits_addr;
            awLen      = dut->io_axi_aw_bits_len;
            awSize     = dut->io_axi_aw_bits_size;
            awId       = dut->io_axi_aw_bits_id;
            awCaptured = true;
            wBeats     = 0;
        }
        // W
        if (dut->io_axi_w_valid && dut->io_axi_w_ready && awCaptured) {
            uint64_t wd  = dut->io_axi_w_bits_data;
            uint8_t  ws  = dut->io_axi_w_bits_strb;
            uint32_t base = awAddr & ~(uint32_t)BEAT_BYTES_M;
            uint32_t beatAddr = base + (uint32_t)wBeats * BEAT_BYTES;
            for (int b = 0; b < BEAT_BYTES; b++) {
                if (ws & (1u << b)) {
                    mem[beatAddr + b] = (uint8_t)((wd >> (8*b)) & 0xFFu);
                }
            }
            bool wlast = dut->io_axi_w_bits_last;
            if (wlast && wBeats != awLen) {
                std::fprintf(stderr, "[AXIslave] WLAST/AWLEN mismatch: wlast at beat %d, awLen=%d\n",
                             wBeats, awLen);
                errs++;
            }
            wBeats++;
            if (wlast) {
                awCaptured = false;
                bPending   = true;
                bId        = awId;
            }
        }
        // B
        if (dut->io_axi_b_valid && dut->io_axi_b_ready && bPending) {
            bPending = false;
        }
        // AR
        if (dut->io_axi_ar_valid && dut->io_axi_ar_ready && !arActive) {
            arAddr   = dut->io_axi_ar_bits_addr;
            arLen    = dut->io_axi_ar_bits_len;
            arSize   = dut->io_axi_ar_bits_size;
            arId     = dut->io_axi_ar_bits_id;
            arActive = true;
            rBeats   = 0;
        }
        // R
        if (dut->io_axi_r_valid && dut->io_axi_r_ready && arActive) {
            if (rBeats == arLen) {
                arActive = false;
            } else {
                rBeats++;
            }
        }
    }
};

// ---------------- Reference memory ----------------
class RefMem {
public:
    std::map<uint32_t, uint8_t> bytes;

    void apply(const TLRequest& r) {
        if (r.opcode != OP_PutFull && r.opcode != OP_PutPart) return;
        int beats = computeBeats(r.size);
        uint32_t base = r.address & ~(uint32_t)BEAT_BYTES_M;
        for (int beat = 0; beat < beats; beat++) {
            uint64_t d = r.data[beat];
            uint8_t  m = r.mask[beat];
            for (int b = 0; b < BEAT_BYTES; b++) {
                if (m & (1u << b)) {
                    bytes[base + beat*BEAT_BYTES + b] = (uint8_t)((d >> (8*b)) & 0xFFu);
                }
            }
        }
    }

    uint64_t beat(uint32_t address, int beatIdx) const {
        uint64_t d = 0;
        uint32_t base = address & ~(uint32_t)BEAT_BYTES_M;
        uint32_t a = base + (uint32_t)beatIdx * BEAT_BYTES;
        for (int b = 0; b < BEAT_BYTES; b++) {
            auto it = bytes.find(a + b);
            uint8_t byte = (it == bytes.end()) ? 0 : it->second;
            d |= ((uint64_t)byte) << (8*b);
        }
        return d;
    }
};

// ---------------- Helpers to build requests ----------------
static TLRequest mkPutFull(uint32_t addr, int size, int src,
                            std::vector<uint64_t> data) {
    TLRequest r;
    r.opcode = OP_PutFull;
    r.size = size; r.source = src; r.address = addr;
    int beats = computeBeats(size);
    if ((int)data.size() != beats) {
        std::fprintf(stderr, "mkPutFull: data has %zu beats, need %d\n", data.size(), beats);
        std::exit(2);
    }
    r.data = std::move(data);
    r.mask.assign(beats, FULL_MASK);
    if ((1 << size) < BEAT_BYTES) {
        int bytes = 1 << size;
        int off   = addr & BEAT_BYTES_M;
        r.mask[0] = (uint8_t)(((1u << bytes) - 1u) << off);
    }
    return r;
}

static TLRequest mkPutPart(uint32_t addr, int size, int src,
                            std::vector<uint64_t> data,
                            std::vector<uint8_t>  mask) {
    TLRequest r;
    r.opcode = OP_PutPart;
    r.size = size; r.source = src; r.address = addr;
    r.data = std::move(data);
    r.mask = std::move(mask);
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

// ---------------- Main ----------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* dut = new VTLUHToAXI4;

    Verilated::traceEverOn(true);
    auto* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("sim.vcd");

    TLDriver tl;
    AXISlave axi;
    RefMem   ref;

    auto step = [&]() {
        // LOAD-BEARING ORDERING — do not reorder drive/sample/edge:
        //   1. clock=0; drive inputs; eval combinational outputs
        //   2. SAMPLE handshakes here (valid && ready on stable outputs,
        //      BEFORE the rising edge — these are the values the DUT's
        //      registers will latch on the next posedge)
        //   3. clock=1; eval to advance registers
        // Sampling AFTER the posedge instead sees outputs from the NEW
        // state (FSM has already transitioned), which gave 0/N responses
        // during bring-up. Keep sample between the two evals.
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
        bool expectAckData;
        std::vector<uint64_t> expectData; // snapshot for Get at enqueue time
    };
    std::vector<Job> jobs;

    auto enqueue = [&](TLRequest req) {
        Job j;
        j.req = req;
        if (req.opcode == OP_PutFull || req.opcode == OP_PutPart) {
            ref.apply(req);
            j.expectAckData = false;
        } else if (req.opcode == OP_Get) {
            j.expectAckData = true;
            int beats = computeBeats(req.size);
            j.expectData.reserve(beats);
            for (int b = 0; b < beats; b++) {
                j.expectData.push_back(ref.beat(req.address, b));
            }
        } else {
            j.expectAckData = false;
        }
        jobs.push_back(std::move(j));
        tl.reqQ.push_back(req);
    };

    // Test 1: 64-bit aligned write + read
    enqueue(mkPutFull(0x100, 3, 1, {0xDEADBEEFCAFEBABEULL}));
    enqueue(mkGet    (0x100, 3, 2));

    // Test 2: 32-bit sub-bus write + read at low half
    enqueue(mkPutFull(0x200, 2, 3, {0x00000000A5A5A5A5ULL}));
    enqueue(mkGet    (0x200, 2, 4));

    // Test 3: 32-bit sub-bus write + read at high half
    enqueue(mkPutFull(0x204, 2, 3, {0xC3C3C3C300000000ULL}));
    enqueue(mkGet    (0x204, 2, 4));

    // Test 4: 32-byte burst (size=5) write+read — 4 beats
    enqueue(mkPutFull(0x400, 5, 5, {
        0x1111111111111111ULL, 0x2222222222222222ULL,
        0x3333333333333333ULL, 0x4444444444444444ULL,
    }));
    enqueue(mkGet    (0x400, 5, 6));

    // Test 5: 16-byte burst (size=4) — 2 beats
    enqueue(mkPutFull(0x300, 4, 7, {
        0xAABBCCDDEEFF0011ULL, 0x2233445566778899ULL,
    }));
    enqueue(mkGet    (0x300, 4, 8));

    // Test 6: PutPartialData on bytes 2..5 of a single beat
    enqueue(mkPutPart(0x500, 3, 9, {0xCAFE5A5A5A5ACAFEULL},
                                   {(uint8_t)0b00111100}));
    enqueue(mkGet    (0x500, 3, 10));

    // Test 7: PutPartialData burst (2 beats), per-beat strb varies
    enqueue(mkPutPart(0x600, 4, 11,
        {0x1010101010101010ULL, 0x2020202020202020ULL},
        {(uint8_t)0xF0, (uint8_t)0x0F}));
    enqueue(mkGet    (0x600, 4, 12));

    // Test 8: Hint → HintAck
    enqueue(mkHint(0x700, 3, 13));

    // Test 9: byte (size=0) write+read at offset 3
    enqueue(mkPutFull(0x803, 0, 14, {0x00000000000000EEULL << (8*3)}));
    enqueue(mkGet    (0x803, 0, 15));

    // Randomized sweep
    std::mt19937 rng(0xC0FFEE);
    std::uniform_int_distribution<int> sizeDist(0, 5);  // up to 32B
    std::uniform_int_distribution<int> opDist(0, 2);    // 0=Put,1=Get,2=Hint
    for (int t = 0; t < 30; t++) {
        int size = sizeDist(rng);
        int bytes = 1 << size;
        uint32_t addr = (rng() & 0x0FFFu) & ~((uint32_t)bytes - 1u);
        int src = rng() & 0xF;
        int op = opDist(rng);
        if (op == 0) {
            int beats = computeBeats(size);
            std::vector<uint64_t> data(beats);
            for (auto& d : data) d = ((uint64_t)rng() << 32) | rng();
            enqueue(mkPutFull(addr, size, src, std::move(data)));
        } else if (op == 1) {
            enqueue(mkGet(addr, size, src));
        } else {
            enqueue(mkHint(addr, size, src));
        }
    }

    // ---------- Run sim ----------
    const int MAX_CYCLES = 200000;
    int cyc = 0;
    while (cyc < MAX_CYCLES) {
        step();
        cyc++;
        if (tl.reqQ.empty() && !tl.reqActive && !tl.respActive &&
            tl.doneResps.size() == jobs.size()) {
            // Allow a few extra cycles for trace flush
            for (int i = 0; i < 10; i++) step();
            break;
        }
    }

    if (tl.doneResps.size() != jobs.size()) {
        std::fprintf(stderr, "FAIL: timeout — got %zu/%zu responses\n",
                     tl.doneResps.size(), jobs.size());
        errs++;
    }

    // ---------- Verify ----------
    for (size_t i = 0; i < jobs.size() && i < tl.doneResps.size(); i++) {
        const auto& job  = jobs[i];
        const auto& resp = tl.doneResps[i];

        CHECK(resp.source == job.req.source,
              "job %zu: source mismatch got=%d want=%d", i, resp.source, job.req.source);
        CHECK(resp.size == job.req.size,
              "job %zu: size mismatch got=%d want=%d", i, resp.size, job.req.size);
        CHECK(!resp.denied, "job %zu: unexpected denied", i);

        if (job.req.opcode == OP_Get) {
            CHECK(resp.opcode == D_AccessAckData,
                  "job %zu Get: opcode got=%d want=AccessAckData(1)", i, resp.opcode);
            int beats = computeBeats(job.req.size);
            CHECK((int)resp.data.size() == beats,
                  "job %zu Get: got %zu beats, want %d", i, resp.data.size(), beats);
            for (int b = 0; b < beats && b < (int)resp.data.size() &&
                            b < (int)job.expectData.size(); b++) {
                uint64_t want = job.expectData[b];
                uint64_t got  = resp.data[b];
                CHECK(got == want,
                      "job %zu Get @0x%08x beat %d: got 0x%016lx want 0x%016lx",
                      i, job.req.address, b,
                      (unsigned long)got, (unsigned long)want);
            }
        } else if (job.req.opcode == OP_PutFull || job.req.opcode == OP_PutPart) {
            CHECK(resp.opcode == D_AccessAck,
                  "job %zu Put: opcode got=%d want=AccessAck(0)", i, resp.opcode);
        } else if (job.req.opcode == OP_Hint) {
            CHECK(resp.opcode == D_HintAck,
                  "job %zu Hint: opcode got=%d want=HintAck(2)", i, resp.opcode);
        }
    }

    // Compare slave memory against reference memory
    for (const auto& kv : ref.bytes) {
        auto it = axi.mem.find(kv.first);
        uint8_t got = (it == axi.mem.end()) ? 0 : it->second;
        CHECK(got == kv.second,
              "mem mismatch @0x%08x: slave=0x%02x ref=0x%02x",
              kv.first, got, kv.second);
    }

    tfp->close();
    delete tfp;
    delete dut;

#if VM_COVERAGE
    // Dump coverage points to coverage.dat in CWD; verilator_coverage will
    // convert it to lcov-format info from there.
    Verilated::threadContextp()->coveragep()->write("coverage.dat");
#endif

    if (errs) {
        std::printf("\n*** FAIL: %d error(s), %zu jobs ***\n", errs, jobs.size());
        return 1;
    }
    std::printf("\n*** PASS: %zu jobs, 0 errors, %llu sim ticks ***\n",
                jobs.size(), (unsigned long long)main_time);
    return 0;
}
