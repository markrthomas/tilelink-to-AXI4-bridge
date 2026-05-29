import cocotb
from cocotb.triggers import RisingEdge

async def reset_dut(dut, cycles: int = 8):
    dut._log.info("Resetting DUT...")
    dut.reset.value = 1
    
    def set_safe(name, val):
        if hasattr(dut, name):
            getattr(dut, name).value = val

    # TL inputs
    set_safe("io_tl_a_valid", 0)
    set_safe("io_tl_a_bits_opcode", 0)
    set_safe("io_tl_a_bits_param", 0)
    set_safe("io_tl_a_bits_size", 0)
    set_safe("io_tl_a_bits_source", 0)
    set_safe("io_tl_a_bits_address", 0)
    set_safe("io_tl_a_bits_mask", 0)
    set_safe("io_tl_a_bits_data", 0)
    set_safe("io_tl_a_bits_corrupt", 0)
    
    set_safe("io_tl_b_ready", 0)
    set_safe("io_tl_c_valid", 0)
    set_safe("io_tl_d_ready", 0)
    set_safe("io_tl_e_valid", 0)
    set_safe("io_tl_e_bits_sink", 0)
    
    # CHI inputs (RN rx side)
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
    """CHI Home Node model supporting ReadShared, ReadUnique, MakeUnique."""
    def __init__(self, dut):
        self.dut = dut
        self.dut.io_chi_txreq_ready.value = 1
        self.dut.io_chi_txrsp_ready.value = 1
        self.dut.io_chi_txdat_ready.value = 1
        self.dut.io_chi_rxdat_valid.value = 0
        self.dut.io_chi_rxrsp_valid.value = 0
        self.dut.io_chi_rxsnp_valid.value = 0

    async def run(self):
        while True:
            await RisingEdge(self.dut.clock)
            if self.dut.io_chi_txreq_valid.value == 1:
                opcode = int(self.dut.io_chi_txreq_bits_opcode.value)
                tid = int(self.dut.io_chi_txreq_bits_txnID.value)
                if opcode in [0x01, 0x07]: # ReadShared, ReadUnique
                    # Send 8 beats of CompData
                    resp_state = 0x2 if opcode == 0x07 else 0x1 # UC vs SC
                    for i in range(8):
                        self.dut.io_chi_rxdat_valid.value = 1
                        self.dut.io_chi_rxdat_bits_opcode.value = 0x4 # CompData
                        self.dut.io_chi_rxdat_bits_txnID.value = tid
                        self.dut.io_chi_rxdat_bits_data.value = 0xDEADC0DE00000000 | (tid << 12) | i
                        self.dut.io_chi_rxdat_bits_resp.value = resp_state
                        self.dut.io_chi_rxdat_bits_dataID.value = i
                        while True:
                            await RisingEdge(self.dut.clock)
                            if self.dut.io_chi_rxdat_ready.value == 1:
                                break
                    self.dut.io_chi_rxdat_valid.value = 0
                elif opcode == 0x0C: # MakeUnique
                    # Send Comp(UC) on rxrsp
                    self.dut.io_chi_rxrsp_valid.value = 1
                    self.dut.io_chi_rxrsp_bits_opcode.value = 0x4 # Comp
                    self.dut.io_chi_rxrsp_bits_txnID.value = tid
                    self.dut.io_chi_rxrsp_bits_resp.value = 0x2 # UC
                    while True:
                        await RisingEdge(self.dut.clock)
                        if self.dut.io_chi_rxrsp_ready.value == 1:
                            break
                    self.dut.io_chi_rxrsp_valid.value = 0

class TLMasterCHI:
    """Drives TL-C A/E and consumes D."""
    def __init__(self, dut):
        self.dut = dut
        self.dut.io_tl_d_ready.value = 1
        self.dut.io_tl_e_valid.value = 0

    async def acquire(self, opcode, param, address, source, size=6):
        # 1. Drive Acquire
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
        
        # 2. Collect D
        data = []
        needs_data = (opcode == 6) and (param in [0, 1]) # AcqBlock and NtoB/NtoT
        # Wait, my RTL says acqNeedsData is true for NtoB and NtoT.
        
        beats = 8 if needs_data else 1
        for _ in range(beats):
            while True:
                if self.dut.io_tl_d_valid.value == 1:
                    if needs_data: data.append(int(self.dut.io_tl_d_bits_data.value))
                    await RisingEdge(self.dut.clock)
                    break
                await RisingEdge(self.dut.clock)
        
        # 3. Drive GrantAck
        self.dut.io_tl_e_valid.value = 1
        self.dut.io_tl_e_bits_sink.value = 0
        while True:
            await RisingEdge(self.dut.clock)
            if self.dut.io_tl_e_ready.value == 1:
                break
        self.dut.io_tl_e_valid.value = 0
        return data
