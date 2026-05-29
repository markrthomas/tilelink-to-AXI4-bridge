import cocotb
from cocotb.clock import Clock
from env_chi import reset_dut, CHIHN, TLMasterCHI

@cocotb.test()
async def test_acquire_ntob(dut):
    """AcquireBlock(NtoB) — 64-byte line, returns GrantData(toB)."""
    cocotb.start_soon(Clock(dut.clock, 10, units="ns").start())
    await reset_dut(dut)
    
    hn = CHIHN(dut)
    master = TLMasterCHI(dut)
    
    cocotb.start_soon(hn.run())
    
    source = 0xA
    address = 0x2000
    data = await master.acquire_block_ntob(address, source)
    
    assert len(data) == 8, f"Expected 8 beats, got {len(data)}"
    for i in range(8):
        expected = 0xDEADC0DE00000000 | (source << 12) | i
        assert data[i] == expected, f"Data mismatch at beat {i}: expected {hex(expected)}, got {hex(data[i])}"
    
    dut._log.info("test_acquire_ntob passed")
