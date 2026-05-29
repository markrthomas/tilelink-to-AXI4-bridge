// TLUCToAXI4 Verilator testbench
//   - Drives TileLink-C (A + C + E) on the bridge slave port
//   - Accepts B (always ready; bridge never issues Probe)
//   - Models a behavioral AXI4 memory slave on the master port
//   - Compares D-channel responses against a reference memory model
//
// Default DUT params (must match Chisel side):
//   addrBits=32, dataBits=64, sourceBits=4, sizeBits=6

#include "VTLUCToAXI4.h"
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
static constexpr int DATA_BITS    = 64;
static constexpr int BEAT_BYTES   = DATA_BITS / 8;            // 8
static constexpr int BEAT_BYTES_M = BEAT_BYTES - 1;
static constexpr int BEAT_SIZE_LG = 3;
static constexpr uint8_t FULL_MASK = (uint8_t)((1u << BEAT_BYTES) - 1u);

// TL A opcodes
static constexpr int OP_PutFull     = 0;
static constexpr int OP_PutPart     = 1;
static constexpr int OP_Arithmetic  = 2;
static constexpr int OP_Logical     = 3;
static constexpr int OP_Get         = 4;
static constexpr int OP_Hint        = 5;
static constexpr int OP_AcqBlock    = 6;
static constexpr int OP_AcqPerm     = 7;

// TL C opcodes (master->slave)
static constexpr int OP_Release     = 6;
static constexpr int OP_ReleaseData = 7;

// TL D opcodes
static constexpr int D_AccessAck     = 0;
static constexpr int D_AccessAckData = 1;
static constexpr int D_HintAck       = 2;
static constexpr int D_Grant         = 4;
static constexpr int D_GrantData     = 5;
static constexpr int D_ReleaseAck    = 6;

// TL params
static constexpr int P_NtoB = 0, P_NtoT = 1, P_BtoT = 2;
static constexpr int P_TtoB = 0, P_TtoN = 1, P_BtoN = 2;
static constexpr int P_toT  = 0, P_toB  = 1, P_toN  = 2;

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
//
// One Job covers a single TL request → TL response pair.  For
// AcquireBlock and AcquirePerm the test also sends GrantAck on E once
// the Grant/GrantData arrives.
struct TLReq {
    int channel;                     // 'A' or 'C'
    int opcode;
    int param = 0;
    int size;
    int source;
    uint32_t address;
    std::vector<uint64_t> data;       // writes / release-data only
    std::vector<uint8_t>  mask;
};

struct TLResp {
    int opcode;
    int param = 0;
    int size;
    int source;
    int sink = 0;
    bool denied;
    bool corrupt;
    std::vector<uint64_t> data;       // data-bearing D opcodes only
};

// ---------------- TL driver / D collector ----------------
class TLDriver {
public:
    std::deque<TLReq>  aQ, cQ;
    std::deque<TLResp> doneResps;
    std::deque<int>    pendingGrantAck;  // sinks awaiting E

    // Active A
    bool   aActive = false;
    TLReq  aCur;
    int    aBeatIdx = 0;

    // Active C
    bool   cActive = false;
    TLReq  cCur;
    int    cBeatIdx = 0;
    bool   cPeekHeld = false;

    // In-progress response assembly
    bool   respActive = false;
    TLResp respCur;
    int    respBeats = 1;
    int    respBeatIdx = 0;

    // Concurrency tracking
    int outstanding = 0;
    int peakConcurrency = 0;

    void drive(VTLUCToAXI4* dut) {
        // ---- A ----
        if (!aActive && !aQ.empty()) {
            aCur = aQ.front();
            aQ.pop_front();
            aActive = true;
            aBeatIdx = 0;
        }
        if (aActive) {
            dut->io_tl_a_valid        = 1;
            dut->io_tl_a_bits_opcode  = aCur.opcode;
            dut->io_tl_a_bits_param   = aCur.param;
            dut->io_tl_a_bits_size    = aCur.size;
            dut->io_tl_a_bits_source  = aCur.source;
            dut->io_tl_a_bits_address = aCur.address;
            dut->io_tl_a_bits_corrupt = 0;
            bool isWr = (aCur.opcode == OP_PutFull || aCur.opcode == OP_PutPart ||
                         aCur.opcode == OP_Arithmetic || aCur.opcode == OP_Logical);
            dut->io_tl_a_bits_data = isWr ? aCur.data[aBeatIdx] : 0;
            dut->io_tl_a_bits_mask = isWr ? aCur.mask[aBeatIdx] : FULL_MASK;
        } else {
            dut->io_tl_a_valid = 0;
            dut->io_tl_a_bits_opcode = 0;
            dut->io_tl_a_bits_param = 0;
            dut->io_tl_a_bits_size = 0;
            dut->io_tl_a_bits_source = 0;
            dut->io_tl_a_bits_address = 0;
            dut->io_tl_a_bits_data = 0;
            dut->io_tl_a_bits_mask = 0;
            dut->io_tl_a_bits_corrupt = 0;
        }

        // ---- C ----
        if (!cActive && !cQ.empty()) {
            cCur = cQ.front();
            cQ.pop_front();
            cActive = true;
            cBeatIdx = 0;
            cPeekHeld = false;
        }
        if (cActive) {
            dut->io_tl_c_valid        = 1;
            dut->io_tl_c_bits_opcode  = cCur.opcode;
            dut->io_tl_c_bits_param   = cCur.param;
            dut->io_tl_c_bits_size    = cCur.size;
            dut->io_tl_c_bits_source  = cCur.source;
            dut->io_tl_c_bits_address = cCur.address;
            dut->io_tl_c_bits_corrupt = 0;
            bool isRelData = (cCur.opcode == OP_ReleaseData);
            dut->io_tl_c_bits_data = isRelData ? cCur.data[cBeatIdx] : 0;
        } else {
            dut->io_tl_c_valid = 0;
            dut->io_tl_c_bits_opcode = 0;
            dut->io_tl_c_bits_param = 0;
            dut->io_tl_c_bits_size = 0;
            dut->io_tl_c_bits_source = 0;
            dut->io_tl_c_bits_address = 0;
            dut->io_tl_c_bits_data = 0;
            dut->io_tl_c_bits_corrupt = 0;
        }

        // ---- E ---- send GrantAck whenever we have one queued AND
        //            the bridge is ready (acqState===sAcqAck → e.ready=1).
        if (!pendingGrantAck.empty()) {
            dut->io_tl_e_valid     = 1;
            dut->io_tl_e_bits_sink = pendingGrantAck.front();
        } else {
            dut->io_tl_e_valid     = 0;
            dut->io_tl_e_bits_sink = 0;
        }

        // ---- B always-ready (bridge ties it off; never fires) ----
        dut->io_tl_b_ready = 1;

        // D backpressure
        int cyc = (int)(main_time >> 1);
        dut->io_tl_d_ready = (cyc % 9 == 4) ? 0 : 1;
    }

    void sample(VTLUCToAXI4* dut) {
        // ---- A handshake ----
        if (aActive && dut->io_tl_a_valid && dut->io_tl_a_ready) {
            bool isWr = (aCur.opcode == OP_PutFull || aCur.opcode == OP_PutPart);
            if (isWr) {
                int beats = computeBeats(aCur.size);
                aBeatIdx++;
                if (aBeatIdx >= beats) {
                    outstanding++;
                    if (outstanding > peakConcurrency) peakConcurrency = outstanding;
                    aActive = false;
                }
            } else {
                outstanding++;
                if (outstanding > peakConcurrency) peakConcurrency = outstanding;
                aActive = false;
            }
        }

        // ---- C handshake ----
        if (cActive && dut->io_tl_c_valid && dut->io_tl_c_ready) {
            if (cCur.opcode == OP_ReleaseData) {
                int beats = computeBeats(cCur.size);
                cBeatIdx++;
                if (cBeatIdx >= beats) {
                    outstanding++;
                    if (outstanding > peakConcurrency) peakConcurrency = outstanding;
                    cActive = false;
                }
            } else {
                // Release single-beat
                outstanding++;
                if (outstanding > peakConcurrency) peakConcurrency = outstanding;
                cActive = false;
            }
        }

        // For ReleaseData: the bridge peeks the first C beat (capturing
        // context) WITHOUT asserting c.ready until the engine reaches
        // sRelData with AXI W ready.  We've already covered this above —
        // the handshake fires when both sides agree.

        // ---- E handshake (GrantAck consumed by bridge) ----
        if (dut->io_tl_e_valid && dut->io_tl_e_ready) {
            if (!pendingGrantAck.empty()) pendingGrantAck.pop_front();
        }

        // ---- B should never fire ----
        if (dut->io_tl_b_valid) {
            CHECK(false, "TL-B fired but bridge should never issue Probe");
        }

        // ---- D handshake ----
        if (dut->io_tl_d_valid && dut->io_tl_d_ready) {
            if (!respActive) {
                respCur.opcode  = dut->io_tl_d_bits_opcode;
                respCur.param   = dut->io_tl_d_bits_param;
                respCur.size    = dut->io_tl_d_bits_size;
                respCur.source  = dut->io_tl_d_bits_source;
                respCur.sink    = dut->io_tl_d_bits_sink;
                respCur.denied  = dut->io_tl_d_bits_denied;
                respCur.corrupt = dut->io_tl_d_bits_corrupt;
                respCur.data.clear();
                bool isMulti = (respCur.opcode == D_AccessAckData ||
                                respCur.opcode == D_GrantData);
                respBeats = isMulti ? computeBeats(respCur.size) : 1;
                respBeatIdx = 0;
                respActive = true;
            }
            if (dut->io_tl_d_bits_opcode == D_AccessAckData ||
                dut->io_tl_d_bits_opcode == D_GrantData) {
                respCur.data.push_back(dut->io_tl_d_bits_data);
            }
            respBeatIdx++;
            if (respBeatIdx >= respBeats) {
                // Queue GrantAck for Grant/GrantData responses.
                if (respCur.opcode == D_Grant || respCur.opcode == D_GrantData) {
                    pendingGrantAck.push_back(respCur.sink);
                }
                doneResps.push_back(respCur);
                respActive = false;
                if (outstanding > 0) outstanding--;
            }
        }
    }
};

// ---------------- Behavioral AXI4 slave (same as tb_main.cpp) ----------------
class AXISlave {
public:
    std::map<uint32_t, uint8_t> mem;

    bool     awCaptured = false;
    uint32_t awAddr = 0;
    int      awLen  = 0;
    int      awId   = 0;
    int      wBeats = 0;

    bool bPending = false;
    int  bId      = 0;
    int  bResp    = 0;

    bool     arActive  = false;
    uint32_t arAddr    = 0;
    int      arLen     = 0;
    int      arId      = 0;
    int      rBeats    = 0;

    void drive(VTLUCToAXI4* dut) {
        int cyc = (int)(main_time >> 1);
        dut->io_axi_aw_ready = (!awCaptured && !bPending && (cyc % 5 != 1)) ? 1 : 0;
        dut->io_axi_w_ready  = (awCaptured && (cyc % 7 != 2)) ? 1 : 0;

        dut->io_axi_b_valid    = bPending ? 1 : 0;
        dut->io_axi_b_bits_id  = bPending ? bId : 0;
        dut->io_axi_b_bits_resp = bPending ? bResp : 0;

        dut->io_axi_ar_ready = (!arActive && (cyc % 6 != 3)) ? 1 : 0;

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
            dut->io_axi_r_bits_resp  = ((arAddr & 0xFFFu) == 0xD00u) ? 2 : 0;
            dut->io_axi_r_bits_last  = (rBeats == arLen) ? 1 : 0;
        } else {
            dut->io_axi_r_valid     = 0;
            dut->io_axi_r_bits_data = 0;
            dut->io_axi_r_bits_id   = 0;
            dut->io_axi_r_bits_resp = 0;
            dut->io_axi_r_bits_last = 0;
        }
    }

    void sample(VTLUCToAXI4* dut) {
        if (dut->io_axi_aw_valid && dut->io_axi_aw_ready && !awCaptured) {
            awAddr     = dut->io_axi_aw_bits_addr;
            awLen      = dut->io_axi_aw_bits_len;
            awId       = dut->io_axi_aw_bits_id;
            awCaptured = true;
            wBeats     = 0;
        }
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
            wBeats++;
            if (wlast) {
                awCaptured = false;
                bPending   = true;
                bId        = awId;
                bResp      = ((awAddr & 0xFFFu) == 0xD80u) ? 3 : 0;
            }
        }
        if (dut->io_axi_b_valid && dut->io_axi_b_ready && bPending) {
            bPending = false;
        }
        if (dut->io_axi_ar_valid && dut->io_axi_ar_ready && !arActive) {
            arAddr   = dut->io_axi_ar_bits_addr;
            arLen    = dut->io_axi_ar_bits_len;
            arId     = dut->io_axi_ar_bits_id;
            arActive = true;
            rBeats   = 0;
        }
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

    void putBeats(uint32_t address, const std::vector<uint64_t>& data,
                  const std::vector<uint8_t>& mask) {
        uint32_t base = address & ~(uint32_t)BEAT_BYTES_M;
        for (size_t beat = 0; beat < data.size(); beat++) {
            uint64_t d = data[beat];
            uint8_t  m = mask.empty() ? FULL_MASK : mask[beat];
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

// ---------------- Request helpers ----------------
static TLReq mkAcqBlock(uint32_t addr, int size, int src, int param) {
    TLReq r; r.channel = 'A';
    r.opcode = OP_AcqBlock; r.param = param;
    r.size = size; r.source = src; r.address = addr;
    return r;
}
static TLReq mkAcqPerm(uint32_t addr, int size, int src, int param) {
    TLReq r; r.channel = 'A';
    r.opcode = OP_AcqPerm; r.param = param;
    r.size = size; r.source = src; r.address = addr;
    return r;
}
static TLReq mkRelease(uint32_t addr, int size, int src, int param) {
    TLReq r; r.channel = 'C';
    r.opcode = OP_Release; r.param = param;
    r.size = size; r.source = src; r.address = addr;
    return r;
}
static TLReq mkReleaseData(uint32_t addr, int size, int src, int param,
                            std::vector<uint64_t> data) {
    TLReq r; r.channel = 'C';
    r.opcode = OP_ReleaseData; r.param = param;
    r.size = size; r.source = src; r.address = addr;
    r.data = std::move(data);
    return r;
}
static TLReq mkPutFull(uint32_t addr, int size, int src, std::vector<uint64_t> data) {
    TLReq r; r.channel = 'A';
    r.opcode = OP_PutFull;
    r.size = size; r.source = src; r.address = addr;
    int beats = computeBeats(size);
    r.data = std::move(data);
    r.mask.assign(beats, FULL_MASK);
    if ((1 << size) < BEAT_BYTES) {
        int bytes = 1 << size;
        int off   = addr & BEAT_BYTES_M;
        r.mask[0] = (uint8_t)(((1u << bytes) - 1u) << off);
    }
    return r;
}
static TLReq mkGet(uint32_t addr, int size, int src) {
    TLReq r; r.channel = 'A';
    r.opcode = OP_Get;
    r.size = size; r.source = src; r.address = addr;
    return r;
}
static TLReq mkHint(uint32_t addr, int size, int src) {
    TLReq r; r.channel = 'A';
    r.opcode = OP_Hint;
    r.size = size; r.source = src; r.address = addr;
    return r;
}

// ---------------- Main ----------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* dut = new VTLUCToAXI4;

    Verilated::traceEverOn(true);
    auto* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("sim_uc.vcd");

    TLDriver tl;
    AXISlave axi;
    RefMem   ref;

    auto step = [&]() {
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
        TLReq req;
        int      expectOpcode;
        int      expectParam;
        bool     expectDenied;
        bool     expectCorrupt;
        std::vector<uint64_t> expectData;   // snapshot for reads/grants
    };
    std::vector<Job> jobs;
    std::map<int, std::deque<size_t>> jobIdxBySource;

    auto enqueueJob = [&](TLReq req, int expectOp, int expectParam,
                          bool expectDenied = false, bool expectCorrupt = false,
                          std::vector<uint64_t> expectData = {}) {
        Job j; j.req = req;
        j.expectOpcode = expectOp;
        j.expectParam  = expectParam;
        j.expectDenied = expectDenied;
        j.expectCorrupt = expectCorrupt;
        j.expectData = std::move(expectData);
        jobIdxBySource[req.source].push_back(jobs.size());
        jobs.push_back(std::move(j));
        if (req.channel == 'A') tl.aQ.push_back(req);
        else                    tl.cQ.push_back(req);
    };

    auto wait_all = [&]() {
        const int TIMEOUT = 10000;
        int start = main_time;
        while (main_time - start < TIMEOUT) {
            step();
            if (tl.aQ.empty() && tl.cQ.empty() && !tl.aActive && !tl.cActive &&
                tl.outstanding == 0 && tl.pendingGrantAck.empty()) return;
        }
        std::fprintf(stderr, "wait_all: TIMEOUT (outstanding=%d, "
                     "aQ=%zu cQ=%zu aActive=%d cActive=%d "
                     "pendingGrantAck=%zu)\n",
                     tl.outstanding, tl.aQ.size(), tl.cQ.size(),
                     (int)tl.aActive, (int)tl.cActive,
                     tl.pendingGrantAck.size());
        errs++;
    };

    // ---- Test 1: AcquireBlock(NtoT) at 0x100, full cache line (64 B / 8 beats).
    //              Pre-load ref+slave memory with a recognizable pattern via
    //              direct AXI-slave priming so the GrantData reads the right
    //              bytes back.
    std::vector<uint64_t> line0 = {
        0x0001020304050607ULL, 0x08090A0B0C0D0E0FULL,
        0x1011121314151617ULL, 0x18191A1B1C1D1E1FULL,
        0x2021222324252627ULL, 0x28292A2B2C2D2E2FULL,
        0x3031323334353637ULL, 0x38393A3B3C3D3E3FULL,
    };
    {
        // Prime memory through a PutFull burst first.
        enqueueJob(mkPutFull(0x100, 6, 0, line0), D_AccessAck, 0);
        ref.putBeats(0x100, line0, {});
        wait_all();
    }
    enqueueJob(mkAcqBlock(0x100, 6, 1, P_NtoT), D_GrantData, P_toT,
               false, false, line0);
    wait_all();

    // ---- Test 2: AcquireBlock(NtoB) at the same line, different source.
    //              Bridge always grants toT (more permission than asked
    //              is allowed in TL-C).  Master should see toT in D.param.
    enqueueJob(mkAcqBlock(0x100, 6, 2, P_NtoB), D_GrantData, P_toT,
               false, false, line0);
    wait_all();

    // ---- Test 3: AcquirePerm(NtoT) — no AXI traffic, immediate Grant.
    enqueueJob(mkAcqPerm(0x200, 6, 3, P_NtoT), D_Grant, P_toT);
    wait_all();

    // ---- Test 4: Release(TtoN) — voluntary drop, no data, no AXI.
    enqueueJob(mkRelease(0x300, 6, 4, P_TtoN), D_ReleaseAck, 0);
    wait_all();

    // ---- Test 5: ReleaseData(TtoN) — dirty writeback of a full line.
    std::vector<uint64_t> line5 = {
        0xCAFE000000000000ULL, 0xCAFE111111111111ULL,
        0xCAFE222222222222ULL, 0xCAFE333333333333ULL,
        0xCAFE444444444444ULL, 0xCAFE555555555555ULL,
        0xCAFE666666666666ULL, 0xCAFE777777777777ULL,
    };
    enqueueJob(mkReleaseData(0x400, 6, 5, P_TtoN, line5), D_ReleaseAck, 0);
    ref.putBeats(0x400, line5, {});
    wait_all();

    // ---- Test 6: verify the ReleaseData landed by Acquiring it back.
    enqueueJob(mkAcqBlock(0x400, 6, 6, P_NtoT), D_GrantData, P_toT,
               false, false, line5);
    wait_all();

    // ---- Test 7: carry-over TL-UH opcodes still work — Put + Get + Hint.
    enqueueJob(mkPutFull(0x800, 3, 7, {0xDEADBEEFCAFEBABEULL}), D_AccessAck, 0);
    ref.putBeats(0x800, {0xDEADBEEFCAFEBABEULL}, {});
    enqueueJob(mkGet(0x800, 3, 8), D_AccessAckData, 0,
               false, false, {0xDEADBEEFCAFEBABEULL});
    enqueueJob(mkHint(0x900, 3, 9), D_HintAck, 0);
    wait_all();

    // ---- Test 8: AXI read error during AcquireBlock — RRESP=SLVERR at 0xD00.
    //              GrantData should still flow, but denied=1 and corrupt=1.
    std::vector<uint64_t> dontCare(8, 0);  // we won't check data on this one
    enqueueJob(mkAcqBlock(0xD00, 6, 10, P_NtoT), D_GrantData, P_toT,
               /*denied=*/true, /*corrupt=*/true, dontCare);
    wait_all();

    // Drain a few cycles.
    for (int i = 0; i < 30; i++) step();

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
        CHECK(resp.opcode == j.expectOpcode,
              "job %zu src=%d: opcode got=%d want=%d", idx, resp.source,
              resp.opcode, j.expectOpcode);
        // size echo only required for D opcodes that are non-zero-size by
        // construction.  Atomic / Get / AccessAck variants echo a.size; Grant*
        // echoes the AcquireBlock/AcquirePerm size.  ReleaseAck echoes c.size.
        CHECK(resp.size == j.req.size,
              "job %zu src=%d: size got=%d want=%d", idx, resp.source,
              resp.size, j.req.size);
        if (resp.opcode == D_Grant || resp.opcode == D_GrantData) {
            CHECK(resp.param == j.expectParam,
                  "job %zu src=%d: D.param got=%d want=%d", idx, resp.source,
                  resp.param, j.expectParam);
        }
        CHECK(resp.denied == j.expectDenied,
              "job %zu src=%d: denied got=%d want=%d", idx, resp.source,
              (int)resp.denied, (int)j.expectDenied);
        CHECK(resp.corrupt == j.expectCorrupt,
              "job %zu src=%d: corrupt got=%d want=%d", idx, resp.source,
              (int)resp.corrupt, (int)j.expectCorrupt);
        if (!j.expectDenied && !j.expectData.empty()) {
            if (resp.data.size() != j.expectData.size()) {
                CHECK(false, "job %zu src=%d: beat count got=%zu want=%zu",
                      idx, resp.source, resp.data.size(), j.expectData.size());
            } else {
                for (size_t i = 0; i < resp.data.size(); i++) {
                    CHECK(resp.data[i] == j.expectData[i],
                          "job %zu src=%d beat %zu: data got=0x%016llx want=0x%016llx",
                          idx, resp.source, i,
                          (unsigned long long)resp.data[i],
                          (unsigned long long)j.expectData[i]);
                }
            }
        }
    }
    for (auto& kv : jobIdxBySource) {
        for (size_t idx : kv.second) {
            std::fprintf(stderr, "FAIL: source=%d job %zu never received D\n",
                         kv.first, idx);
            errs++;
        }
    }

    tfp->close();
    delete dut;

    std::printf("uc TB: %zu jobs, %d errors, peakConcurrency=%d, ticks=%llu\n",
                jobs.size(), errs, tl.peakConcurrency,
                (unsigned long long)(main_time / 2));
    return (errs == 0) ? 0 : 1;
}
