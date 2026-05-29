"""Directed cocotb tests for TLUCToAXI4.

Covers the new TL-C behaviors (Acquire, Release, GrantAck) plus a
carry-over of TL-UH Get/Put/Hint to confirm the legacy engines work
through the extended bridge.
"""

import cocotb
from cocotb.clock import Clock

from env_uc import (
    AxiSlave, TLUCMaster, beats_for_size, reset_dut,
    BEAT_BYTES, FULL_MASK,
    D_ACCESS_ACK, D_ACCESS_ACK_DATA, D_HINT_ACK,
    D_GRANT, D_GRANT_DATA, D_RELEASE_ACK,
    P_NtoB, P_NtoT, P_BtoT, P_TtoB, P_TtoN, P_BtoN, P_toT,
)


async def _setup(dut):
    cocotb.start_soon(Clock(dut.clock, 10, units="ns").start())
    await reset_dut(dut)
    axi = AxiSlave(dut)
    axi.start()
    tl = TLUCMaster(dut)
    return tl, axi


@cocotb.test()
async def test_acquire_block_ntot(dut):
    """AcquireBlock(NtoT) — 64-byte cache line read, returns GrantData(toT)."""
    tl, _ = await _setup(dut)
    addr = 0x100
    payload = [
        0x0102030405060708, 0x090A0B0C0D0E0F10,
        0x1112131415161718, 0x191A1B1C1D1E1F20,
        0x2122232425262728, 0x292A2B2C2D2E2F30,
        0x3132333435363738, 0x393A3B3C3D3E3F40,
    ]
    # Prime memory via a PutFull burst.
    r = await tl.put_full(addr, 6, 0, payload)
    assert r.opcode == D_ACCESS_ACK and not r.denied

    r = await tl.acquire_block(addr, 6, 1, param=P_NtoT)
    assert r.opcode == D_GRANT_DATA
    assert r.param == P_toT
    assert r.data == payload, f"expected {[hex(x) for x in payload]}, got {[hex(x) for x in r.data]}"


@cocotb.test()
async def test_acquire_block_ntob_grants_t(dut):
    """AcquireBlock(NtoB) — bridge always grants T (more perm than asked OK)."""
    tl, _ = await _setup(dut)
    addr = 0x200
    payload = [0xAA] * 8
    payload = [0xAAAAAAAAAAAAAAAA] * 8
    await tl.put_full(addr, 6, 0, payload)

    r = await tl.acquire_block(addr, 6, 2, param=P_NtoB)
    assert r.opcode == D_GRANT_DATA
    assert r.param == P_toT, f"expected toT, got param={r.param}"
    assert r.data == payload


@cocotb.test()
async def test_acquire_perm(dut):
    """AcquirePerm(NtoT) — no AXI traffic, immediate Grant(toT)."""
    tl, _ = await _setup(dut)
    r = await tl.acquire_perm(0x300, 6, 3, param=P_NtoT)
    assert r.opcode == D_GRANT
    assert r.param == P_toT
    assert not r.denied


@cocotb.test()
async def test_release_no_data(dut):
    """Release(TtoN) — single C beat, no AXI, ReleaseAck."""
    tl, _ = await _setup(dut)
    r = await tl.release(0x400, 6, 4, param=P_TtoN)
    assert r.opcode == D_RELEASE_ACK
    assert not r.denied


@cocotb.test()
async def test_release_data(dut):
    """ReleaseData(TtoN) — dirty writeback of a full cache line."""
    tl, _ = await _setup(dut)
    addr = 0x500
    payload = [
        0xCAFEBABE00000000, 0xCAFEBABE11111111,
        0xCAFEBABE22222222, 0xCAFEBABE33333333,
        0xCAFEBABE44444444, 0xCAFEBABE55555555,
        0xCAFEBABE66666666, 0xCAFEBABE77777777,
    ]
    r = await tl.release_data(addr, 6, 5, payload, param=P_TtoN)
    assert r.opcode == D_RELEASE_ACK
    assert not r.denied

    # Verify by re-acquiring — the data must come back.
    r = await tl.acquire_block(addr, 6, 6, param=P_NtoT)
    assert r.opcode == D_GRANT_DATA
    assert r.data == payload


@cocotb.test()
async def test_tluh_carryover(dut):
    """TL-UH opcodes (Get/Put/Hint) still work through the extended bridge."""
    tl, _ = await _setup(dut)
    wdata = 0xDEADBEEFCAFEBABE
    r = await tl.put_full(0x800, 3, 7, [wdata])
    assert r.opcode == D_ACCESS_ACK
    r = await tl.get(0x800, 3, 8)
    assert r.opcode == D_ACCESS_ACK_DATA
    assert r.data == [wdata]
    r = await tl.hint(0x900, 3, 9)
    assert r.opcode == D_HINT_ACK
