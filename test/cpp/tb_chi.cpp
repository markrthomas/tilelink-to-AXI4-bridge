// TLCToCHI Stage 3 Verilator testbench
//   - Drives TileLink-C (A + E) on the bridge slave port
//   - Models a CHI Home Node (HN) for ReadShared, ReadUnique, MakeUnique
//
// Default DUT params: addrBits=48, dataBits=64, sourceBits=4, txnIDBits=8

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
static constexpr int REQ_ReadUnique = 0x07;
static constexpr int REQ_MakeUnique = 0x0C;
// CHI RSP opcodes
static constexpr int RSP_Comp       = 0x04;
static constexpr int RSP_CompAck    = 0x02;
// CHI DAT opcodes
static constexpr int DAT_CompData   = 0x04;
// CHI Cache States
static constexpr int CHI_SC         = 0x1;
static constexpr int CHI_UC         = 0x2;

// TL A opcodes
static constexpr int OP_AcqBlock    = 6;
static constexpr int OP_AcqPerm     = 7;
// TL D opcodes
static constexpr int D_GrantData     = 5;
static constexpr int D_Grant         = 4;
// TL params
static constexpr int P_NtoB = 0, P_NtoT = 1, P_BtoT = 2;
static constexpr int P_toT  = 0, P_toB  = 1;

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
    int param;
    std::vector<uint64_t> data;
};

class TLMaster {
public:
    std::deque<TLReq>  aQ;
    std::deque<TLResp> doneResps;
    std::deque<int>    pendingE;

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

        if (!pendingE.empty()) {
            dut->io_tl_e_valid = 1;
        } else {
            dut->io_tl_e_valid = 0;
        }
        dut->io_tl_d_ready = 1;
    }

    void sample(VTLCToCHI* dut) {
        if (aActive && dut->io_tl_a_valid && dut->io_tl_a_ready) {
            std::printf("  A.fire: op=%d param=%d source=%d time=%ld\n", aCur.opcode, aCur.param, aCur.source, main_time);
            aActive = false;
        }
        if (dut->io_tl_d_valid && dut->io_tl_d_ready) {
            if (!dActive) {
                dActive = true;
                dCur.opcode = dut->io_tl_d_bits_opcode;
                dCur.source = dut->io_tl_d_bits_source;
                dCur.param  = dut->io_tl_d_bits_param;
                dCur.data.clear();
                dBeatIdx = 0;
            }
            if (dCur.opcode == D_GrantData) dCur.data.push_back(dut->io_tl_d_bits_data);
            dBeatIdx++;
            std::printf("  D.fire #%d: opcode=%d source=%d param=%d time=%ld\n", dBeatIdx, dCur.opcode, dCur.source, dCur.param, main_time);

            int totalBeats = (dCur.opcode == D_GrantData) ? ((1 << dut->io_tl_d_bits_size) / BEAT_BYTES) : 1;
            if (totalBeats < 1) totalBeats = 1;
            if (dBeatIdx == totalBeats) {
                doneResps.push_back(dCur);
                dActive = false;
                pendingE.push_back(dCur.source);
            }
        }
        if (dut->io_tl_e_valid && dut->io_tl_e_ready) {
            std::printf("  E.fire: source=%d time=%ld\n", pendingE.front(), main_time);
            pendingE.pop_front();
        }
    }
};

// ---------------- CHI Home Node Model ----------------
struct CHITxn {
    int txnID;
    int opcode;
    int beatsLeft = 0;
    std::vector<uint64_t> data;
};

class CHIHN {
public:
    std::map<int, CHITxn> activeReads;
    std::deque<int>       dataQueue;
    std::deque<int>       rspQueue;

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
            dut->io_chi_rxdat_bits_resp = (tx.opcode == REQ_ReadUnique) ? CHI_UC : CHI_SC;
            dut->io_chi_rxdat_bits_dataID = 8 - tx.beatsLeft;
        } else {
            dut->io_chi_rxdat_valid = 0;
        }

        if (!rspQueue.empty()) {
            int tid = rspQueue.front();
            dut->io_chi_rxrsp_valid = 1;
            dut->io_chi_rxrsp_bits_opcode = RSP_Comp;
            dut->io_chi_rxrsp_bits_txnID = tid;
            dut->io_chi_rxrsp_bits_resp = CHI_UC;
        } else {
            dut->io_chi_rxrsp_valid = 0;
        }
        
        dut->io_chi_rxsnp_valid = 0;
    }

    void sample(VTLCToCHI* dut) {
        if (dut->io_chi_txreq_valid && dut->io_chi_txreq_ready) {
            int tid = dut->io_chi_txreq_bits_txnID;
            int op  = dut->io_chi_txreq_bits_opcode;
            std::printf("  REQ.fire: op=%d tid=%d time=%ld\n", op, tid, main_time);
            CHITxn tx; tx.txnID = tid; tx.opcode = op;
            if (op == REQ_ReadShared || op == REQ_ReadUnique) {
                tx.beatsLeft = BEATS_PER_LINE;
                for (int i=0; i<8; i++) tx.data.push_back(0xDEADC0DE00000000ULL | (tid << 12) | i);
                activeReads[tid] = tx;
                dataQueue.push_back(tid);
            } else if (op == REQ_MakeUnique) {
                activeReads[tid] = tx;
                rspQueue.push_back(tid);
            }
        }
        if (dut->io_chi_rxdat_valid && dut->io_chi_rxdat_ready) {
            int tid = dataQueue.front();
            if (--activeReads[tid].beatsLeft == 0) dataQueue.pop_front();
        }
        if (dut->io_chi_rxrsp_valid && dut->io_chi_rxrsp_ready) {
            rspQueue.pop_front();
        }
        if (dut->io_chi_txrsp_valid && dut->io_chi_txrsp_ready) {
            CHECK(dut->io_chi_txrsp_bits_opcode == RSP_CompAck, "Expected CompAck");
            std::printf("  CompAck.fire: tid=%d time=%ld\n", (int)dut->io_chi_txrsp_bits_txnID, main_time);
            activeReads.erase(dut->io_chi_txrsp_bits_txnID);
        }
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    VTLCToCHI* dut = new VTLCToCHI;
    VerilatedVcdC* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("sim_chi.vcd");
    TLMaster master; CHIHN hn;
    auto tick = [&]() {
        dut->clock = 0;
        master.drive(dut); hn.drive(dut);
        dut->eval();
        master.sample(dut); hn.sample(dut);
        tfp->dump(main_time++);
        dut->clock = 1;
        dut->eval();
        tfp->dump(main_time++);
    };
    dut->reset = 1; for (int i=0; i<20; i++) tick(); dut->reset = 0;

    auto run_test = [&](int op, int param, int source, int exp_op, int exp_param) {
        std::printf("Running test: op=%d param=%d source=%d\n", op, param, source);
        TLReq req; req.opcode = op; req.param = param; req.size = 6; req.source = source; req.address = 0x1000 * source;
        master.aQ.push_back(req);
        uint64_t start_time = main_time;
        while (master.doneResps.empty()) {
            tick();
            if (main_time - start_time > 100) {
                std::printf("TIMEOUT waiting for response (time=%ld)\n", main_time);
                errs++;
                break;
            }
        }
        if (!master.doneResps.empty()) {
            TLResp res = master.doneResps.front(); master.doneResps.pop_front();
            CHECK(res.opcode == exp_op, "Op mismatch: exp %d got %d", exp_op, res.opcode);
            CHECK(res.param == exp_param, "Param mismatch: exp %d got %d", exp_param, res.param);
        }
        start_time = main_time;
        while (!master.pendingE.empty() || !hn.activeReads.empty()) {
            tick();
            if (main_time - start_time > 100) {
                std::printf("TIMEOUT waiting for cleanup (time=%ld)\n", main_time);
                errs++;
                break;
            }
        }
    };

    run_test(OP_AcqBlock, P_NtoB, 1, D_GrantData, P_toB);
    run_test(OP_AcqBlock, P_NtoT, 2, D_GrantData, P_toT);
    run_test(OP_AcqBlock, P_BtoT, 3, D_Grant,     P_toT);
    run_test(OP_AcqPerm,  P_NtoT, 4, D_Grant,     P_toT);

    tfp->close();
    delete dut;
    if (errs > 0) { std::printf("FAILED with %d errors\n", errs); return 1; }
    std::printf("CHI Stage 3 TB: PASS\n"); return 0;
}
