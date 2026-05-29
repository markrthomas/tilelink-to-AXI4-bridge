import cocotb
from cocotb.clock import Clock
from env_chi import (reset_dut, CHIHN, TLMasterCHI,
                     TL_OP_AcqBlock, TL_OP_AcqPerm,
                     TL_OP_Release, TL_OP_ReleaseData)


@cocotb.test()
async def test_acquire_mixed(dut):
    """Sequence of ReadShared, ReadUnique, and MakeUnique acquisitions."""
    cocotb.start_soon(Clock(dut.clock, 10, units="ns").start())
    await reset_dut(dut)

    hn = CHIHN(dut)
    master = TLMasterCHI(dut)
    cocotb.start_soon(hn.run())

    # AcquireBlock(NtoB) -> ReadShared (data, toB)
    source = 1
    data = await master.acquire(opcode=TL_OP_AcqBlock, param=0, address=0x1000, source=source)
    assert len(data) == 8
    assert data[0] == 0xDEADC0DE00000000 | (source << 12) | 0

    # AcquireBlock(NtoT) -> ReadUnique (data, toT)
    source = 2
    data = await master.acquire(opcode=TL_OP_AcqBlock, param=1, address=0x2000, source=source)
    assert len(data) == 8
    assert data[0] == 0xDEADC0DE00000000 | (source << 12) | 0

    # AcquirePerm(NtoT) -> MakeUnique
    source = 3
    data = await master.acquire(opcode=TL_OP_AcqPerm, param=1, address=0x3000, source=source)
    assert len(data) == 0

    # AcquireBlock(BtoT) -> MakeUnique
    source = 4
    data = await master.acquire(opcode=TL_OP_AcqBlock, param=2, address=0x4000, source=source)
    assert len(data) == 0

    dut._log.info("test_acquire_mixed passed")


@cocotb.test()
async def test_release_mixed(dut):
    """Sequence of Evict and WriteBack/WriteClean releases."""
    cocotb.start_soon(Clock(dut.clock, 10, units="ns").start())
    await reset_dut(dut)

    hn = CHIHN(dut)
    master = TLMasterCHI(dut)
    cocotb.start_soon(hn.run())

    # Release(TtoN) -> Evict (no data)
    await master.release(opcode=TL_OP_Release, param=1, address=0x5000, source=5)

    # Release(BtoN) -> Evict (no data)
    await master.release(opcode=TL_OP_Release, param=2, address=0x6000, source=6)

    # ReleaseData(TtoN) -> WriteBackFull
    wb = [0xCAFEBABE00000000 | i for i in range(8)]
    await master.release(opcode=TL_OP_ReleaseData, param=1, address=0x7000, source=7, data=wb)
    assert 0x87 in hn.released_data, "missing released data for tid 0x87"
    assert hn.released_data[0x87] == wb, "WriteBack data mismatch"

    # ReleaseData(TtoB) -> WriteCleanFull
    wc = [0xFEEDF00D00000000 | i for i in range(8)]
    await master.release(opcode=TL_OP_ReleaseData, param=0, address=0x8000, source=8, data=wc)
    assert 0x88 in hn.released_data, "missing released data for tid 0x88"
    assert hn.released_data[0x88] == wc, "WriteClean data mismatch"

    dut._log.info("test_release_mixed passed")
