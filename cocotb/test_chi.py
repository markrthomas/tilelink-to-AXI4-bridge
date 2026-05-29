import cocotb
from cocotb.clock import Clock
from env_chi import (reset_dut, CHIHN, TLMasterCHI,
                     TL_OP_AcqBlock, TL_OP_AcqPerm,
                     TL_OP_Release, TL_OP_ReleaseData,
                     TL_OP_ProbeAck, TL_OP_ProbeAckData,
                     TL_OP_Get, TL_OP_PutFull, TL_OP_Hint,
                     TL_OP_Arith, TL_OP_Logical,
                     TL_D_AccessAck, TL_D_AccessAckData, TL_D_HintAck,
                     REQ_ReadOnce, REQ_WriteUniqueFull, REQ_CleanShared,
                     REQ_AtomicLoadAdd, REQ_AtomicLoadClr,
                     A_ADD, L_AND,
                     SNP_SnpShared, SNP_SnpUnique,
                     RSP_SnpResp, DAT_SnpRespData,
                     CHI_I, CHI_SC)


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


@cocotb.test()
async def test_snoop_mixed(dut):
    """Sequence of SnpShared / SnpUnique with ProbeAck and ProbeAckData."""
    cocotb.start_soon(Clock(dut.clock, 10, units="ns").start())
    await reset_dut(dut)

    hn = CHIHN(dut)
    master = TLMasterCHI(dut)
    cocotb.start_soon(hn.run())

    # 1. SnpShared + ProbeAck(TtoB) -> SnpResp(SC)
    cocotb.start_soon(master.serve_probe(TL_OP_ProbeAck, 0))  # TtoB
    r = await hn.inject_snoop(SNP_SnpShared, 0x10, 1, 0x9000)
    assert r["opcode"] == RSP_SnpResp, f"expected SnpResp got {r['opcode']:#x}"
    assert r["resp"] == CHI_SC, f"expected SC got {r['resp']:#x}"

    # 2. SnpUnique + ProbeAck(TtoN) -> SnpResp(I)
    cocotb.start_soon(master.serve_probe(TL_OP_ProbeAck, 1))  # TtoN
    r = await hn.inject_snoop(SNP_SnpUnique, 0x11, 1, 0xA000)
    assert r["opcode"] == RSP_SnpResp
    assert r["resp"] == CHI_I

    # 3. SnpShared + ProbeAckData(TtoB) -> SnpRespData(SC_PD=0x5)
    snp_data = [0xBADC0FFEE0000000 | i for i in range(8)]
    cocotb.start_soon(master.serve_probe(TL_OP_ProbeAckData, 0, snp_data))
    r = await hn.inject_snoop(SNP_SnpShared, 0x12, 1, 0xB000)
    assert r["opcode"] == DAT_SnpRespData
    assert r["resp"] == 0x5
    assert r["data"] == snp_data

    # 4. SnpUnique + ProbeAckData(TtoN) -> SnpRespData(I_PD=0x4)
    snp_data2 = [0xC0FFEE0000000000 | i for i in range(8)]
    cocotb.start_soon(master.serve_probe(TL_OP_ProbeAckData, 1, snp_data2))
    r = await hn.inject_snoop(SNP_SnpUnique, 0x13, 1, 0xC000)
    assert r["opcode"] == DAT_SnpRespData
    assert r["resp"] == 0x4
    assert r["data"] == snp_data2

    dut._log.info("test_snoop_mixed passed")


@cocotb.test()
async def test_uncached_mixed(dut):
    """Get / Put / Hint / Atomic over the uncached engine."""
    cocotb.start_soon(Clock(dut.clock, 10, units="ns").start())
    await reset_dut(dut)

    hn = CHIHN(dut)
    master = TLMasterCHI(dut)
    cocotb.start_soon(hn.run())

    # Get (full line) -> ReadOnce -> AccessAckData
    op, data = await master.uncached(TL_OP_Get, 0, 9, 6)
    assert op == TL_D_AccessAckData, f"Get D op {op:#x}"
    assert hn.unc_req[0x49] == REQ_ReadOnce
    assert data == [0x600D0000 | (0x49 << 8) | i for i in range(8)], data

    # PutFull (full line) -> WriteUniqueFull -> AccessAck
    wd = [0x1111000000000000 | i for i in range(8)]
    op, _ = await master.uncached(TL_OP_PutFull, 0, 11, 6, wd)
    assert op == TL_D_AccessAck, f"Put D op {op:#x}"
    assert hn.unc_req[0x4B] == REQ_WriteUniqueFull
    assert hn.unc_wdata[0x4B] == wd, hn.unc_wdata[0x4B]

    # Hint(PrefetchRead) -> CleanShared -> HintAck
    op, _ = await master.uncached(TL_OP_Hint, 0, 13, 6)
    assert op == TL_D_HintAck, f"Hint D op {op:#x}"
    assert hn.unc_req[0x4D] == REQ_CleanShared

    # Atomic ADD -> AtomicLoadAdd; operand forwarded, pre-op value returned
    op, data = await master.uncached(TL_OP_Arith, A_ADD, 1, 3, [0xAAAA0000BBBB1111])
    assert op == TL_D_AccessAckData
    assert hn.unc_req[0x41] == REQ_AtomicLoadAdd
    assert hn.unc_wdata[0x41] == [0xAAAA0000BBBB1111]
    assert data == [0x0DDBA11A70000000 | 0x41]

    # Atomic AND -> AtomicLoadClr with the operand inverted on the wire
    operand = 0x00FF00FF00FF00FF
    op, data = await master.uncached(TL_OP_Logical, L_AND, 4, 3, [operand])
    assert op == TL_D_AccessAckData
    assert hn.unc_req[0x44] == REQ_AtomicLoadClr
    assert hn.unc_wdata[0x44] == [(~operand) & ((1 << 64) - 1)], hn.unc_wdata[0x44]

    dut._log.info("test_uncached_mixed passed")
