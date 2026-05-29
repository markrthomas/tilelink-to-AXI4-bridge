import cocotb
from cocotb.triggers import RisingEdge

# CHI opcodes (Issue-E)
REQ_ReadOnce       = 0x03
REQ_ReadShared     = 0x01
REQ_ReadUnique     = 0x07
REQ_CleanShared    = 0x08
REQ_CleanInvalid   = 0x09
REQ_MakeUnique     = 0x0C
REQ_Evict          = 0x0D
REQ_WriteCleanFull = 0x19
REQ_WriteUniquePtl = 0x1A
REQ_WriteUniqueFull= 0x1B
REQ_WriteBackFull  = 0x1D
REQ_AtomicLoadAdd  = 0x48
REQ_AtomicLoadClr  = 0x49
REQ_AtomicLoadEor  = 0x4A
REQ_AtomicLoadSet  = 0x4B
REQ_AtomicSwap     = 0x50

RSP_SnpResp        = 0x01
RSP_CompAck        = 0x02
RSP_Comp           = 0x04
RSP_CompDBIDResp   = 0x05
RSP_DBIDResp       = 0x06

DAT_SnpRespData    = 0x01
DAT_CopyBackWrData = 0x02
DAT_NonCopyBackWr  = 0x03
DAT_CompData       = 0x04

SNP_SnpShared      = 0x01
SNP_SnpUnique      = 0x07

CHI_I  = 0x0
CHI_SC = 0x1
CHI_UC = 0x2

# TL opcodes
TL_OP_PutFull       = 0
TL_OP_PutPartial    = 1
TL_OP_Arith         = 2
TL_OP_Logical       = 3
TL_OP_Get           = 4
TL_OP_Hint          = 5
TL_OP_AcqBlock      = 6
TL_OP_AcqPerm       = 7
TL_OP_ProbeAck      = 4
TL_OP_ProbeAckData  = 5
TL_OP_Release       = 6
TL_OP_ReleaseData   = 7
TL_D_AccessAck      = 0
TL_D_AccessAckData  = 1
TL_D_HintAck        = 2
TL_D_Grant          = 4
TL_D_GrantData      = 5
TL_D_ReleaseAck     = 6
# TL atomic params
A_ADD = 4
L_AND = 2


async def reset_dut(dut, cycles: int = 8):
    dut._log.info("Resetting DUT...")
    dut.reset.value = 1

    def set_safe(name, val):
        if hasattr(dut, name):
            getattr(dut, name).value = val

    # TL inputs
    for n in ("io_tl_a_valid", "io_tl_a_bits_opcode", "io_tl_a_bits_param",
              "io_tl_a_bits_size", "io_tl_a_bits_source",
              "io_tl_a_bits_address", "io_tl_a_bits_mask", "io_tl_a_bits_data",
              "io_tl_a_bits_corrupt",
              "io_tl_b_ready",
              "io_tl_c_valid", "io_tl_c_bits_opcode", "io_tl_c_bits_param",
              "io_tl_c_bits_size", "io_tl_c_bits_source",
              "io_tl_c_bits_address", "io_tl_c_bits_data",
              "io_tl_c_bits_corrupt",
              "io_tl_d_ready",
              "io_tl_e_valid", "io_tl_e_bits_sink"):
        set_safe(n, 0)

    # CHI: tx ready always, rx valid low
    set_safe("io_chi_txreq_ready", 1)
    set_safe("io_chi_txrsp_ready", 1)
    set_safe("io_chi_txdat_ready", 1)
    set_safe("io_chi_rxrsp_valid", 0)
    set_safe("io_chi_rxdat_valid", 0)
    set_safe("io_chi_rxsnp_valid", 0)

    for _ in range(cycles):
        await RisingEdge(dut.clock)
    dut.reset.value = 0
    await RisingEdge(dut.clock)
    dut._log.info("Reset complete")


class CHIHN:
    """CHI Home Node model covering acquire/release/snoop paths."""
    def __init__(self, dut):
        self.dut = dut
        self.dut.io_chi_txreq_ready.value = 1
        self.dut.io_chi_txrsp_ready.value = 1
        self.dut.io_chi_txdat_ready.value = 1
        self.dut.io_chi_rxdat_valid.value = 0
        self.dut.io_chi_rxrsp_valid.value = 0
        self.dut.io_chi_rxsnp_valid.value = 0
        self.released_data = {}  # txnID -> list[int]
        self.snp_results = {}    # txnID -> {"opcode", "resp", "data", "complete"}
        self.unc_req = {}        # txnID -> observed CHI REQ opcode
        self.unc_wdata = {}      # txnID -> NonCopyBackWrData beats (write/operand)
        self.next_dbid = 1

    async def _send_rxdat(self, tid, beat, total_beats, data, resp):
        self.dut.io_chi_rxdat_valid.value = 1
        self.dut.io_chi_rxdat_bits_opcode.value = DAT_CompData
        self.dut.io_chi_rxdat_bits_txnID.value = tid
        self.dut.io_chi_rxdat_bits_data.value = data
        self.dut.io_chi_rxdat_bits_resp.value = resp
        self.dut.io_chi_rxdat_bits_dataID.value = beat
        while True:
            await RisingEdge(self.dut.clock)
            if self.dut.io_chi_rxdat_ready.value == 1:
                break
        self.dut.io_chi_rxdat_valid.value = 0

    async def _send_rxrsp(self, tid, opcode, resp, dbid=0):
        self.dut.io_chi_rxrsp_valid.value = 1
        self.dut.io_chi_rxrsp_bits_opcode.value = opcode
        self.dut.io_chi_rxrsp_bits_txnID.value = tid
        self.dut.io_chi_rxrsp_bits_resp.value = resp
        self.dut.io_chi_rxrsp_bits_dbID.value = dbid
        while True:
            await RisingEdge(self.dut.clock)
            if self.dut.io_chi_rxrsp_ready.value == 1:
                break
        self.dut.io_chi_rxrsp_valid.value = 0

    async def _collect_txdat(self, dbid, beats):
        """Collect <beats> txdat beats with matching dbid."""
        data = []
        seen = 0
        while seen < beats:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_chi_txdat_valid.value) == 1 \
                    and int(self.dut.io_chi_txdat_ready.value) == 1 \
                    and int(self.dut.io_chi_txdat_bits_txnID.value) == dbid:
                data.append(int(self.dut.io_chi_txdat_bits_data.value))
                seen += 1
        return data

    async def run(self):
        while True:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_chi_txreq_valid.value) != 1:
                continue
            opcode = int(self.dut.io_chi_txreq_bits_opcode.value)
            tid    = int(self.dut.io_chi_txreq_bits_txnID.value)

            if opcode in (REQ_ReadShared, REQ_ReadUnique):
                resp = CHI_UC if opcode == REQ_ReadUnique else CHI_SC
                for i in range(8):
                    data = 0xDEADC0DE00000000 | (tid << 12) | i
                    await self._send_rxdat(tid, i, 8, data, resp)
            elif opcode == REQ_MakeUnique:
                await self._send_rxrsp(tid, RSP_Comp, CHI_UC)
            elif opcode == REQ_Evict:
                await self._send_rxrsp(tid, RSP_Comp, CHI_I)
            elif opcode in (REQ_WriteBackFull, REQ_WriteCleanFull):
                dbid = self.next_dbid
                self.next_dbid += 1
                # Send CompDBIDResp, then consume 8 beats of CopyBackWrData
                await self._send_rxrsp(tid, RSP_CompDBIDResp, CHI_I, dbid)
                self.released_data[tid] = await self._collect_txdat(dbid, 8)
            else:
                # ---- Uncached / atomic REQs ----
                size  = int(self.dut.io_chi_txreq_bits_size.value)
                beats = max(1, (1 << size) // 8)
                self.unc_req[tid] = opcode
                if opcode == REQ_ReadOnce:
                    for i in range(beats):
                        await self._send_rxdat(tid, i, beats,
                                               0x600D0000 | (tid << 8) | i, CHI_UC)
                elif opcode in (REQ_WriteUniqueFull, REQ_WriteUniquePtl):
                    dbid = self.next_dbid; self.next_dbid += 1
                    await self._send_rxrsp(tid, RSP_CompDBIDResp, CHI_I, dbid)
                    self.unc_wdata[tid] = await self._collect_txdat(dbid, beats)
                elif opcode in (REQ_CleanShared, REQ_CleanInvalid):
                    await self._send_rxrsp(tid, RSP_Comp, CHI_I)
                elif 0x40 <= opcode <= 0x51:
                    # Atomic: DBIDResp -> collect operand -> CompData(old value)
                    dbid = self.next_dbid; self.next_dbid += 1
                    await self._send_rxrsp(tid, RSP_DBIDResp, CHI_I, dbid)
                    self.unc_wdata[tid] = await self._collect_txdat(dbid, 1)
                    await self._send_rxdat(tid, 0, 1,
                                           0x0DDBA11A70000000 | tid, CHI_UC)

    async def inject_snoop(self, opcode, tid, src_id, addr):
        """Drive an rxsnp transaction and collect the corresponding SnpResp
        or SnpRespData.  Returns the result dict once complete."""
        self.snp_results[tid] = {"opcode": 0, "resp": 0,
                                  "data": [], "complete": False}
        # Drive rxsnp
        self.dut.io_chi_rxsnp_valid.value = 1
        self.dut.io_chi_rxsnp_bits_opcode.value = opcode
        self.dut.io_chi_rxsnp_bits_txnID.value = tid
        self.dut.io_chi_rxsnp_bits_srcID.value = src_id
        self.dut.io_chi_rxsnp_bits_addr.value = addr >> 3
        while True:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_chi_rxsnp_ready.value) == 1:
                break
        self.dut.io_chi_rxsnp_valid.value = 0

        # Collect SnpResp on txrsp OR SnpRespData on txdat
        result = self.snp_results[tid]
        while not result["complete"]:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_chi_txrsp_valid.value) == 1 \
                    and int(self.dut.io_chi_txrsp_ready.value) == 1:
                rsp_tid = int(self.dut.io_chi_txrsp_bits_txnID.value)
                rsp_op  = int(self.dut.io_chi_txrsp_bits_opcode.value)
                if rsp_op == RSP_SnpResp and rsp_tid == tid:
                    result["opcode"] = RSP_SnpResp
                    result["resp"]   = int(self.dut.io_chi_txrsp_bits_resp.value)
                    result["complete"] = True
            if int(self.dut.io_chi_txdat_valid.value) == 1 \
                    and int(self.dut.io_chi_txdat_ready.value) == 1:
                dat_tid = int(self.dut.io_chi_txdat_bits_txnID.value)
                dat_op  = int(self.dut.io_chi_txdat_bits_opcode.value)
                if dat_op == DAT_SnpRespData and dat_tid == tid:
                    result["opcode"] = DAT_SnpRespData
                    result["resp"]   = int(self.dut.io_chi_txdat_bits_resp.value)
                    result["data"].append(int(self.dut.io_chi_txdat_bits_data.value))
                    if len(result["data"]) == 8:
                        result["complete"] = True
        return result


class TLMasterCHI:
    """Drives TL-C A/C/E and consumes D and B."""
    def __init__(self, dut):
        self.dut = dut
        self.dut.io_tl_d_ready.value = 1
        self.dut.io_tl_b_ready.value = 1
        self.dut.io_tl_e_valid.value = 0
        self.dut.io_tl_c_valid.value = 0

    async def serve_probe(self, ack_opcode, ack_param, data=None):
        """Wait for a Probe on TL-B, then drive a single TL-C
        ProbeAck/ProbeAckData response back."""
        data = data or []
        # Wait for Probe
        while True:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_b_valid.value) == 1 \
                    and int(self.dut.io_tl_b_ready.value) == 1:
                addr = int(self.dut.io_tl_b_bits_address.value)
                break

        # Drive C with response
        self.dut.io_tl_c_valid.value = 1
        self.dut.io_tl_c_bits_opcode.value = ack_opcode
        self.dut.io_tl_c_bits_param.value = ack_param
        self.dut.io_tl_c_bits_size.value = 6
        self.dut.io_tl_c_bits_source.value = 0
        self.dut.io_tl_c_bits_address.value = addr
        beats = max(len(data), 1)
        self.dut.io_tl_c_bits_data.value = (data[0] if data else 0)

        beat_idx = 0
        while beat_idx < beats:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_c_ready.value) == 1:
                beat_idx += 1
                if beat_idx < beats:
                    self.dut.io_tl_c_bits_data.value = data[beat_idx]
        self.dut.io_tl_c_valid.value = 0

    async def uncached(self, opcode, param, source, size, data=None):
        """Drive a TL-A Get/Put/Hint/Atomic (multi-beat write data when
        given) and collect the D response.  Returns (d_opcode, [d_data])."""
        data = data or []
        a_beats = max(len(data), 1)
        self.dut.io_tl_a_valid.value = 1
        self.dut.io_tl_a_bits_opcode.value = opcode
        self.dut.io_tl_a_bits_param.value = param
        self.dut.io_tl_a_bits_size.value = size
        self.dut.io_tl_a_bits_source.value = source
        self.dut.io_tl_a_bits_address.value = 0x4000 + 0x100 * source
        self.dut.io_tl_a_bits_mask.value = 0xFF
        self.dut.io_tl_a_bits_data.value = (data[0] if data else 0)
        beat_idx = 0
        while beat_idx < a_beats:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_a_ready.value) == 1:
                beat_idx += 1
                if beat_idx < a_beats:
                    self.dut.io_tl_a_bits_data.value = data[beat_idx]
        self.dut.io_tl_a_valid.value = 0

        d_op = None
        d_data = []
        d_beats = max(1, (1 << size) // 8)
        while True:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_d_valid.value) == 1 \
                    and int(self.dut.io_tl_d_ready.value) == 1:
                op = int(self.dut.io_tl_d_bits_opcode.value)
                if d_op is None:
                    d_op = op
                if op == TL_D_AccessAckData:
                    d_data.append(int(self.dut.io_tl_d_bits_data.value))
                    if len(d_data) == d_beats:
                        break
                else:
                    break
        return d_op, d_data

    async def acquire(self, opcode, param, address, source, size=6):
        self.dut.io_tl_a_valid.value = 1
        self.dut.io_tl_a_bits_opcode.value = opcode
        self.dut.io_tl_a_bits_param.value = param
        self.dut.io_tl_a_bits_size.value = size
        self.dut.io_tl_a_bits_source.value = source
        self.dut.io_tl_a_bits_address.value = address

        while True:
            await RisingEdge(self.dut.clock)
            if self.dut.io_tl_a_ready.value == 1:
                break
        self.dut.io_tl_a_valid.value = 0

        needs_data = (opcode == TL_OP_AcqBlock) and (param in (0, 1))
        data = []
        beats = 8 if needs_data else 1
        for _ in range(beats):
            while True:
                if int(self.dut.io_tl_d_valid.value) == 1:
                    if needs_data:
                        data.append(int(self.dut.io_tl_d_bits_data.value))
                    await RisingEdge(self.dut.clock)
                    break
                await RisingEdge(self.dut.clock)

        # GrantAck on E
        self.dut.io_tl_e_valid.value = 1
        self.dut.io_tl_e_bits_sink.value = 0
        while True:
            await RisingEdge(self.dut.clock)
            if self.dut.io_tl_e_ready.value == 1:
                break
        self.dut.io_tl_e_valid.value = 0
        return data

    async def release(self, opcode, param, address, source, size=6, data=None):
        """Drive a TL-C Release (no data) or ReleaseData (multi-beat).
        Returns once ReleaseAck arrives on D."""
        data = data or []
        beats = max(len(data), 1)
        self.dut.io_tl_c_valid.value = 1
        self.dut.io_tl_c_bits_opcode.value = opcode
        self.dut.io_tl_c_bits_param.value = param
        self.dut.io_tl_c_bits_size.value = size
        self.dut.io_tl_c_bits_source.value = source
        self.dut.io_tl_c_bits_address.value = address
        self.dut.io_tl_c_bits_data.value = (data[0] if data else 0)

        beat_idx = 0
        while beat_idx < beats:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_c_ready.value) == 1:
                beat_idx += 1
                if beat_idx < beats:
                    self.dut.io_tl_c_bits_data.value = data[beat_idx]
        self.dut.io_tl_c_valid.value = 0

        # Wait for ReleaseAck on D
        while True:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_d_valid.value) == 1:
                op = int(self.dut.io_tl_d_bits_opcode.value)
                src = int(self.dut.io_tl_d_bits_source.value)
                if op == TL_D_ReleaseAck and src == source:
                    break
