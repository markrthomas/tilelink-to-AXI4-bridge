// TLCToCHI Stage 2 Verilator testbench
//   - Drives TileLink-C (A + E) on the bridge slave port
//   - Models a minimal CHI Home Node (HN) that handles ReadShared
//   - Compares D-channel responses against pseudo-random HN data
//
// Default DUT params (must match CHIBundles.scala):
//   addrBits=48, dataBits=64, sourceBits=4, txnIDBits=8

#include "VTLCToCHI.h"
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
#include <random>

// ---------- CHI Parameters ----------
static constexpr int DATA_BITS    = 64;
static constexpr int BEAT_BYTES   = DATA_BITS / 8;
static constexpr int LINE_BYTES   = 64;
static constexpr int BEATS_PER_LINE = LINE_BYTES / BEAT_BYTES; // 8

// CHI REQ opcodes
static constexpr int REQ_ReadShared = 0x01;
// CHI RSP opcodes
static constexpr int RSP_CompAck    = 0x02;
// CHI DAT opcodes
static constexpr int DAT_CompData   = 0x04;
// CHI Cache States
static constexpr int CHI_SC         = 0x1;

// TL A opcodes
static constexpr int OP_AcqBlock    = 6;
static constexpr int OP_AcqPerm     = 7;
// TL D opcodes
static constexpr int D_GrantData     = 5;
static constexpr int D_Grant         = 4;
// TL params
static constexpr int P_NtoB = 0;
static constexpr int P_toB  = 1;

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

// ---------------- TL driver / D collector ----------------
struct TLReq {
    int opcode;
    int param;
    int size;
    int source;
    uint64_t address;
};

struct TLResp {
    int opcode;
    int source;
    std::vector<uint64_t> data;
};

class TLMaster {
public:
    std::deque<TLReq>  aQ;
    std::deque<TLResp> doneResps;
    std::deque<int>    pendingE; // sources awaiting GrantAck

    bool aActive = false;
    TLReq aCur;

    bool dActive = false;
    TLResp dCur;
    int dBeatIdx = 0;

    void drive(VTLCToCHI* dut) {
        if (!aActive && !aQ.empty()) {
            aCur = aQ.front();
            aQ.pop_front();
            aActive = true;
        }
        if (aActive) {
            dut->io_tl_a_valid = 1;
            dut->io_tl_a_bits_opcode = aCur.opcode;
            dut->io_tl_a_bits_param = aCur.param;
            dut->io_tl_a_bits_size = aCur.size;
            dut->io_tl_a_bits_source = aCur.source;
            dut->io_tl_a_bits_address = aCur.address;
        } else {
            dut->io_tl_a_valid = 0;
        }

        // GrantAck (E)
        if (!pendingE.empty()) {
            dut->io_tl_e_valid = 1;
            dut->io_tl_e_bits_sink = 0; // bridge uses sink=0 for now
        } else {
            dut->io_tl_e_valid = 0;
        }
        
        dut->io_tl_d_ready = 1;
    }

    void sample(VTLCToCHI* dut) {
        if (aActive && dut->io_tl_a_valid && dut->io_tl_a_ready) {
            aActive = false;
        }
        if (dut->io_tl_d_valid && dut->io_tl_d_ready) {
            if (!dActive) {
                dActive = true;
                dCur.opcode = dut->io_tl_d_bits_opcode;
                dCur.source = dut->io_tl_d_bits_source;
                dCur.data.clear();
                dBeatIdx = 0;
            }
            dCur.data.push_back(dut->io_tl_d_bits_data);
            dBeatIdx++;
            
            int totalBeats = (1 << dut->io_tl_d_bits_size) / BEAT_BYTES;
            if (totalBeats < 1) totalBeats = 1;
            if (dBeatIdx == totalBeats) {
                doneResps.push_back(dCur);
                dActive = false;
                if (dCur.opcode == D_GrantData || dCur.opcode == D_Grant) {
                    pendingE.push_back(dCur.source);
                }
            }
        }
        if (dut->io_tl_e_valid && dut->io_tl_e_ready) {
            pendingE.pop_front();
        }
    }
};

// ---------------- CHI Home Node Model ----------------
struct CHITxn {
    int txnID;
    uint64_t addr;
    int beatsLeft = 0;
    std::vector<uint64_t> data;
};

class CHIHN {
public:
    std::map<int, CHITxn> activeReads;
    std::deque<int>       dataQueue; // txnIDs ready to send data

    void drive(VTLCToCHI* dut) {
        dut->io_chi_txreq_ready = 1;
        dut->io_chi_txrsp_ready = 1;
        dut->io_chi_txdat_ready = 1;

        if (!dataQueue.empty()) {
            int tid = dataQueue.front();
            CHITxn &tx = activeReads[tid];
            dut->io_chi_rxdat_valid = 1;
            dut->io_chi_rxdat_bits_opcode = DAT_CompData;
            dut->io_chi_rxdat_bits_txnID = tid;
            dut->io_chi_rxdat_bits_data = tx.data[8 - tx.beatsLeft];
            dut->io_chi_rxdat_bits_resp = CHI_SC;
            dut->io_chi_rxdat_bits_dataID = 8 - tx.beatsLeft;
        } else {
            dut->io_chi_rxdat_valid = 0;
        }
        
        dut->io_chi_rxrsp_valid = 0;
        dut->io_chi_rxsnp_valid = 0;
    }

    void sample(VTLCToCHI* dut) {
        if (dut->io_chi_txreq_valid && dut->io_chi_txreq_ready) {
            int tid = dut->io_chi_txreq_bits_txnID;
            CHITxn tx;
            tx.txnID = tid;
            tx.addr = dut->io_chi_txreq_bits_addr;
            tx.beatsLeft = BEATS_PER_LINE;
            for (int i=0; i<8; i++) tx.data.push_back(0xDEADC0DE00000000ULL | (tid << 12) | i);
            activeReads[tid] = tx;
            dataQueue.push_back(tid);
        }
        if (dut->io_chi_rxdat_valid && dut->io_chi_rxdat_ready) {
            int tid = dataQueue.front();
            CHITxn &tx = activeReads[tid];
            tx.beatsLeft--;
            if (tx.beatsLeft == 0) {
                dataQueue.pop_front();
            }
        }
        if (dut->io_chi_txrsp_valid && dut->io_chi_txrsp_ready) {
            CHECK(dut->io_chi_txrsp_bits_opcode == RSP_CompAck, "Expected CompAck");
            int tid = dut->io_chi_txrsp_bits_txnID;
            activeReads.erase(tid);
        }
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    VTLCToCHI* dut = new VTLCToCHI;

    VerilatedVcdC* tfp = nullptr;
    const char* vcd_path = std::getenv("VCD_PATH");
    if (vcd_path) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC;
        dut->trace(tfp, 99);
        tfp->open(vcd_path);
    }

    TLMaster master;
    CHIHN hn;

    auto tick = [&]() {
        dut->clock = 0; dut->eval();
        if (tfp) tfp->dump(main_time); main_time++;
        master.drive(dut);
        hn.drive(dut);
        dut->clock = 1; dut->eval();
        master.sample(dut);
        hn.sample(dut);
        if (tfp) tfp->dump(main_time); main_time++;
    };

    dut->reset = 1;
    for (int i=0; i<10; i++) tick();
    dut->reset = 0;

    // Test: AcquireBlock(NtoB)
    TLReq req;
    req.opcode = OP_AcqBlock;
    req.param = P_NtoB;
    req.size = 6; // 64B
    req.source = 5;
    req.address = 0x1000;
    master.aQ.push_back(req);

    while (master.doneResps.empty() || !master.pendingE.empty() || !hn.activeReads.empty()) {
        tick();
        if (main_time > 1000) break;
    }

    CHECK(!master.doneResps.empty(), "No response received");
    if (!master.doneResps.empty()) {
        TLResp res = master.doneResps.front();
        CHECK(res.opcode == D_GrantData, "Expected GrantData");
        CHECK(res.source == 5, "Source mismatch");
        CHECK(res.data.size() == 8, "Data size mismatch");
        for (int i=0; i<8; i++) {
            uint64_t expected = 0xDEADC0DE00000000ULL | (5 << 12) | i;
            CHECK(res.data[i] == expected, "Data mismatch at beat %d: expected %lx, got %lx", i, expected, res.data[i]);
        }
    }

    if (tfp) tfp->close();
    delete dut;

    if (errs > 0) {
        std::printf("FAILED with %d errors\n", errs);
        return 1;
    }
    std::printf("CHI Stage 2 TB: PASS\n");
    return 0;
}
