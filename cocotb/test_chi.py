import cocotb
from cocotb.clock import Clock
from env_chi import reset_dut, CHIHN, TLMasterCHI

@cocotb.test()
async def test_acquire_mixed(dut):
    """Sequence of ReadShared, ReadUnique, and MakeUnique acquisitions."""
    cocotb.start_soon(Clock(dut.clock, 10, units="ns").start())
    await reset_dut(dut)
    
    hn = CHIHN(dut)
    master = TLMasterCHI(dut)
    cocotb.start_soon(hn.run())
    
    # 1. AcquireBlock(NtoB) -> ReadShared
    source = 1
    data = await master.acquire(opcode=6, param=0, address=0x1000, source=source)
    assert len(data) == 8
    assert data[0] == 0xDEADC0DE00000000 | (source << 12) | 0
    
    # 2. AcquireBlock(NtoT) -> ReadUnique
    source = 2
    data = await master.acquire(opcode=6, param=1, address=0x2000, source=source)
    assert len(data) == 8
    assert data[0] == 0xDEADC0DE00000000 | (source << 12) | 0
    
    # 3. AcquirePerm(NtoT) -> MakeUnique
    source = 3
    data = await master.acquire(opcode=7, param=1, address=0x3000, source=source)
    assert len(data) == 0
    
    # 4. AcquireBlock(BtoT) -> MakeUnique (permission upgrade)
    source = 4
    data = await master.acquire(opcode=6, param=2, address=0x4000, source=source)
    assert len(data) == 0
    
    dut._log.info("test_acquire_mixed passed")
