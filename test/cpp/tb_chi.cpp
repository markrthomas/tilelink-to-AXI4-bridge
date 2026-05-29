// TLCToCHI Stage 4 Verilator testbench
//   - Drives TileLink-C (A + C + E) on the bridge slave port
//   - Models a CHI Home Node (HN) for ReadShared/ReadUnique/MakeUnique
//     (acquire path) and Evict/WriteBackFull/WriteCleanFull (release).
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
static constexpr int REQ_ReadShared     = 0x01;
static constexpr int REQ_ReadUnique     = 0x07;
static constexpr int REQ_MakeUnique     = 0x0C;
static constexpr int REQ_Evict          = 0x0D;
static constexpr int REQ_WriteCleanFull = 0x19;
static constexpr int REQ_WriteBackFull  = 0x1D;
// CHI RSP opcodes
static constexpr int RSP_SnpResp        = 0x01;
static constexpr int RSP_CompAck        = 0x02;
static constexpr int RSP_Comp           = 0x04;
static constexpr int RSP_CompDBIDResp   = 0x05;
static constexpr int RSP_DBIDResp       = 0x06;
// CHI DAT opcodes
static constexpr int DAT_CopyBackWrData = 0x02;
static constexpr int DAT_CompData       = 0x04;
// CHI Cache States
static constexpr int CHI_I              = 0x0;
static constexpr int CHI_SC             = 0x1;
static constexpr int CHI_UC             = 0x2;

// TL A opcodes
static constexpr int OP_AcqBlock    = 6;
static constexpr int OP_AcqPerm     = 7;
// TL C opcodes
static constexpr int OP_Release     = 6;
static constexpr int OP_ReleaseData = 7;
// TL D opcodes
static constexpr int D_GrantData     = 5;
static constexpr int D_Grant         = 4;
static constexpr int D_ReleaseAck    = 6;
// TL A params (acquire)
static constexpr int P_NtoB = 0, P_NtoT = 1, P_BtoT = 2;
// TL C params (release)
static constexpr int P_TtoB = 0, P_TtoN = 1, P_BtoN = 2;
// TL D params (grant)
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
struct TLAReq {
    int opcode;
    int param;
    int size;
    int source;
    uint64_t address;
};

struct TLCReq {
    int opcode;
    int param;
    int size;
    int source;
    uint64_t address;
    std::vector<uint64_t> data; // empty for Release (no data)
};

struct TLResp {
    int opcode;
    int source;
    int param;
    std::vector<uint64_t> data;
};

class TLMaster {
public:
    std::deque<TLAReq> aQ;
    std::deque<TLCReq> cQ;
    std::deque<TLResp> doneResps;
    std::deque<int>    pendingE;

    bool aActive = false;
    TLAReq aCur;

    bool cActive = false;
    TLCReq cCur;
    int  cBeatIdx = 0;

    bool dActive = false;
    TLResp dCur;
    int dBeatIdx = 0;

    void drive(VTLCToCHI* dut) {
        // ---- A ----
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

        // ---- C ----
        if (!cActive && !cQ.empty()) {
            cCur = cQ.front();
            cQ.pop_front();
            cActive = true;
            cBeatIdx = 0;
        }
        if (cActive) {
            dut->io_tl_c_valid = 1;
            dut->io_tl_c_bits_opcode = cCur.opcode;
            dut->io_tl_c_bits_param = cCur.param;
            dut->io_tl_c_bits_size = cCur.size;
            dut->io_tl_c_bits_source = cCur.source;
            dut->io_tl_c_bits_address = cCur.address;
            uint64_t bd = cCur.data.empty() ? 0 : cCur.data[cBeatIdx];
            dut->io_tl_c_bits_data = bd;
        } else {
            dut->io_tl_c_valid = 0;
        }

        // ---- E ----
        dut->io_tl_e_valid = pendingE.empty() ? 0 : 1;
        dut->io_tl_d_ready = 1;
    }

    void sample(VTLCToCHI* dut) {
        if (aActive && dut->io_tl_a_valid && dut->io_tl_a_ready) {
            std::printf("  A.fire: op=%d param=%d source=%d time=%ld\n",
                        aCur.opcode, aCur.param, aCur.source, main_time);
            aActive = false;
        }
        if (cActive && dut->io_tl_c_valid && dut->io_tl_c_ready) {
            cBeatIdx++;
            int totalBeats = cCur.data.empty() ? 1 : (int)cCur.data.size();
            std::printf("  C.fire #%d: op=%d param=%d source=%d time=%ld\n",
                        cBeatIdx, cCur.opcode, cCur.param, cCur.source, main_time);
            if (cBeatIdx >= totalBeats) {
                cActive = false;
            }
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
            std::printf("  D.fire #%d: opcode=%d source=%d param=%d time=%ld\n",
                        dBeatIdx, dCur.opcode, dCur.source, dCur.param, main_time);

            int totalBeats = (dCur.opcode == D_GrantData)
                ? ((1 << dut->io_tl_d_bits_size) / BEAT_BYTES)
                : 1;
            if (totalBeats < 1) totalBeats = 1;
            if (dBeatIdx == totalBeats) {
                doneResps.push_back(dCur);
                dActive = false;
                // Grant / GrantData expect GrantAck (E).  ReleaseAck does not.
                if (dCur.opcode == D_GrantData || dCur.opcode == D_Grant) {
                    pendingE.push_back(dCur.source);
                }
            }
        }
        if (dut->io_tl_e_valid && dut->io_tl_e_ready) {
            std::printf("  E.fire: source=%d time=%ld\n", pendingE.front(), main_time);
            pendingE.pop_front();
        }
    }
};

// ---------------- CHI Home Node Model ----------------
struct CHIReadTxn {
    int txnID;
    int opcode;
    int beatsLeft = 0;
    std::vector<uint64_t> data;
};

struct CHIRelTxn {
    int txnID;
    int opcode;          // REQ opcode
    int beatsExpected;   // for WriteBack / WriteClean
    int beatsSeen;
    int dbID;            // assigned by HN
    bool dbidSent;
    bool compSent;
    std::vector<uint64_t> dataReceived;
};

class CHIHN {
public:
    std::map<int, CHIReadTxn> activeReads;
    std::map<int, CHIRelTxn>  activeReleases;
    std::deque<int>           dataQueue;    // for CompData (read path)
    std::deque<int>           rxrspQueue;   // for Comp (acquire-perm path)
    std::deque<int>           rxrspRelQueue; // for CompDBIDResp / Comp (release path)
    int nextDBID = 1;

    void drive(VTLCToCHI* dut) {
        dut->io_chi_txreq_ready = 1;
        dut->io_chi_txrsp_ready = 1;
        dut->io_chi_txdat_ready = 1;

        // CompData (read)
        if (!dataQueue.empty()) {
            int tid = dataQueue.front();
            CHIReadTxn &tx = activeReads[tid];
            dut->io_chi_rxdat_valid = 1;
            dut->io_chi_rxdat_bits_opcode = DAT_CompData;
            dut->io_chi_rxdat_bits_txnID = tid;
            dut->io_chi_rxdat_bits_data = tx.data[BEATS_PER_LINE - tx.beatsLeft];
            dut->io_chi_rxdat_bits_resp = (tx.opcode == REQ_ReadUnique) ? CHI_UC : CHI_SC;
            dut->io_chi_rxdat_bits_dataID = BEATS_PER_LINE - tx.beatsLeft;
        } else {
            dut->io_chi_rxdat_valid = 0;
        }

        // rxrsp: priority to release path (CompDBIDResp / Comp), then acquire Comp
        if (!rxrspRelQueue.empty()) {
            int tid = rxrspRelQueue.front();
            CHIRelTxn &tx = activeReleases[tid];
            dut->io_chi_rxrsp_valid = 1;
            dut->io_chi_rxrsp_bits_txnID = tid;
            if (tx.opcode == REQ_Evict) {
                dut->io_chi_rxrsp_bits_opcode = RSP_Comp;
                dut->io_chi_rxrsp_bits_resp = CHI_I;
                dut->io_chi_rxrsp_bits_dbID = 0;
            } else {
                // WriteBackFull / WriteCleanFull
                dut->io_chi_rxrsp_bits_opcode = RSP_CompDBIDResp;
                dut->io_chi_rxrsp_bits_resp = CHI_I;
                dut->io_chi_rxrsp_bits_dbID = tx.dbID;
            }
        } else if (!rxrspQueue.empty()) {
            int tid = rxrspQueue.front();
            dut->io_chi_rxrsp_valid = 1;
            dut->io_chi_rxrsp_bits_opcode = RSP_Comp;
            dut->io_chi_rxrsp_bits_txnID = tid;
            dut->io_chi_rxrsp_bits_resp = CHI_UC;
            dut->io_chi_rxrsp_bits_dbID = 0;
        } else {
            dut->io_chi_rxrsp_valid = 0;
        }

        dut->io_chi_rxsnp_valid = 0;
    }

    void sample(VTLCToCHI* dut) {
        // REQ.fire
        if (dut->io_chi_txreq_valid && dut->io_chi_txreq_ready) {
            int tid = dut->io_chi_txreq_bits_txnID;
            int op  = dut->io_chi_txreq_bits_opcode;
            std::printf("  REQ.fire: op=0x%02x tid=0x%02x time=%ld\n", op, tid, main_time);
            if (op == REQ_ReadShared || op == REQ_ReadUnique) {
                CHIReadTxn tx; tx.txnID = tid; tx.opcode = op;
                tx.beatsLeft = BEATS_PER_LINE;
                for (int i = 0; i < BEATS_PER_LINE; i++)
                    tx.data.push_back(0xDEADC0DE00000000ULL | (tid << 12) | i);
                activeReads[tid] = tx;
                dataQueue.push_back(tid);
            } else if (op == REQ_MakeUnique) {
                CHIReadTxn tx; tx.txnID = tid; tx.opcode = op;
                activeReads[tid] = tx;
                rxrspQueue.push_back(tid);
            } else if (op == REQ_Evict) {
                CHIRelTxn tx{};
                tx.txnID = tid; tx.opcode = op;
                tx.beatsExpected = 0;
                activeReleases[tid] = tx;
                rxrspRelQueue.push_back(tid);
            } else if (op == REQ_WriteBackFull || op == REQ_WriteCleanFull) {
                CHIRelTxn tx{};
                tx.txnID = tid; tx.opcode = op;
                tx.beatsExpected = BEATS_PER_LINE;
                tx.dbID = nextDBID++;
                activeReleases[tid] = tx;
                rxrspRelQueue.push_back(tid);
            }
        }

        // rxdat.fire
        if (dut->io_chi_rxdat_valid && dut->io_chi_rxdat_ready) {
            int tid = dataQueue.front();
            if (--activeReads[tid].beatsLeft == 0) dataQueue.pop_front();
        }

        // rxrsp.fire — release rxrsp delivered (dbid or comp)
        if (dut->io_chi_rxrsp_valid && dut->io_chi_rxrsp_ready) {
            if (!rxrspRelQueue.empty()) {
                int tid = rxrspRelQueue.front();
                CHIRelTxn &tx = activeReleases[tid];
                if (tx.opcode == REQ_Evict) {
                    // Comp delivered, transaction done immediately
                    activeReleases.erase(tid);
                } else {
                    tx.dbidSent = true;
                }
                rxrspRelQueue.pop_front();
            } else if (!rxrspQueue.empty()) {
                rxrspQueue.pop_front();
            }
        }

        // txrsp.fire — CompAck for acquire
        if (dut->io_chi_txrsp_valid && dut->io_chi_txrsp_ready) {
            CHECK(dut->io_chi_txrsp_bits_opcode == RSP_CompAck, "Expected CompAck");
            std::printf("  CompAck.fire: tid=0x%02x time=%ld\n",
                        (int)dut->io_chi_txrsp_bits_txnID, main_time);
            activeReads.erase(dut->io_chi_txrsp_bits_txnID);
        }

        // txdat.fire — CopyBackWrData beats for release
        if (dut->io_chi_txdat_valid && dut->io_chi_txdat_ready) {
            int dbid = dut->io_chi_txdat_bits_txnID;
            uint64_t d = dut->io_chi_txdat_bits_data;
            std::printf("  TXDAT.fire: dbid=0x%02x data=0x%016lx time=%ld\n",
                        dbid, d, main_time);
            // Find the release matching this dbID
            for (auto &kv : activeReleases) {
                if (kv.second.dbID == dbid && kv.second.dbidSent) {
                    kv.second.beatsSeen++;
                    kv.second.dataReceived.push_back(d);
                    if (kv.second.beatsSeen == kv.second.beatsExpected) {
                        // transaction done
                        std::printf("  Release tid=0x%02x complete (%d beats)\n",
                                    kv.first, kv.second.beatsSeen);
                        activeReleases.erase(kv.first);
                    }
                    break;
                }
            }
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
    dut->reset = 1; for (int i = 0; i < 20; i++) tick(); dut->reset = 0;

    // ---- Acquire test ----
    auto run_acquire = [&](int op, int param, int source, int exp_op, int exp_param) {
        std::printf("Acquire: op=%d param=%d source=%d\n", op, param, source);
        TLAReq req; req.opcode = op; req.param = param; req.size = 6;
        req.source = source; req.address = 0x1000 * source;
        master.aQ.push_back(req);
        uint64_t start_time = main_time;
        while (master.doneResps.empty()) {
            tick();
            if (main_time - start_time > 200) {
                std::printf("TIMEOUT acquire response (time=%ld)\n", main_time);
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
            if (main_time - start_time > 200) {
                std::printf("TIMEOUT acquire cleanup (time=%ld)\n", main_time);
                errs++;
                break;
            }
        }
    };

    // ---- Release test ----
    auto run_release = [&](int op, int param, int source,
                           const std::vector<uint64_t>& data,
                           int expected_req_op) {
        std::printf("Release: op=%d param=%d source=%d beats=%zu\n",
                    op, param, source, data.size());
        TLCReq req; req.opcode = op; req.param = param; req.size = 6;
        req.source = source; req.address = 0x2000 * source;
        req.data = data;
        master.cQ.push_back(req);
        uint64_t start_time = main_time;
        while (master.doneResps.empty()) {
            tick();
            if (main_time - start_time > 300) {
                std::printf("TIMEOUT release response (time=%ld)\n", main_time);
                errs++;
                break;
            }
        }
        if (!master.doneResps.empty()) {
            TLResp res = master.doneResps.front(); master.doneResps.pop_front();
            CHECK(res.opcode == D_ReleaseAck, "Expected ReleaseAck got %d", res.opcode);
            CHECK(res.source == source, "ReleaseAck source mismatch");
        }
        start_time = main_time;
        while (!hn.activeReleases.empty()) {
            tick();
            if (main_time - start_time > 200) {
                std::printf("TIMEOUT release cleanup (time=%ld)\n", main_time);
                errs++;
                break;
            }
        }
        (void)expected_req_op;
    };

    // Stage 3 cases
    run_acquire(OP_AcqBlock, P_NtoB, 1, D_GrantData, P_toB);
    run_acquire(OP_AcqBlock, P_NtoT, 2, D_GrantData, P_toT);
    run_acquire(OP_AcqBlock, P_BtoT, 3, D_Grant,     P_toT);
    run_acquire(OP_AcqPerm,  P_NtoT, 4, D_Grant,     P_toT);

    // Stage 4 releases
    // 1. Release(TtoN) -> Evict (no data)
    run_release(OP_Release, P_TtoN, 5, {}, REQ_Evict);
    // 2. Release(BtoN) -> Evict (no data)
    run_release(OP_Release, P_BtoN, 6, {}, REQ_Evict);
    // 3. ReleaseData(TtoN) -> WriteBackFull (8 beats)
    std::vector<uint64_t> wb_data;
    for (int i = 0; i < BEATS_PER_LINE; i++) wb_data.push_back(0xCAFEBABE00000000ULL | i);
    run_release(OP_ReleaseData, P_TtoN, 7, wb_data, REQ_WriteBackFull);
    // 4. ReleaseData(TtoB) -> WriteCleanFull (8 beats)
    std::vector<uint64_t> wc_data;
    for (int i = 0; i < BEATS_PER_LINE; i++) wc_data.push_back(0xFEEDF00D00000000ULL | i);
    run_release(OP_ReleaseData, P_TtoB, 8, wc_data, REQ_WriteCleanFull);

    tfp->close();
    delete dut;
    if (errs > 0) { std::printf("FAILED with %d errors\n", errs); return 1; }
    std::printf("CHI Stage 4 TB: PASS\n"); return 0;
}
