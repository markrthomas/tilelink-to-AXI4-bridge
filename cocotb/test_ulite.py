"""Directed cocotb tests for TLULToAXILite.

Mirrors a subset of the C++ TB's directed jobs.  TL-UL is single-beat —
each TL request expects a single D response with the matching opcode,
source, size, and (for Get) data drawn from a Python-side reference
memory updated by Put requests.
"""

import cocotb
from cocotb.clock import Clock

from env_ulite import (
    AxiLiteSlave, TLULMaster, reset_dut,
    BEAT_BYTES, FULL_MASK,
    D_ACCESS_ACK, D_ACCESS_ACK_DATA, D_HINT_ACK,
)


def _ref_beat(ref_mem: dict[int, int], address: int) -> int:
    base = address & ~(BEAT_BYTES - 1)
    data = 0
    for b in range(BEAT_BYTES):
        data |= (ref_mem.get(base + b, 0) & 0xFF) << (8 * b)
    return data


def _apply_put(ref_mem: dict[int, int], address: int, data: int, mask: int):
    base = address & ~(BEAT_BYTES - 1)
    for b in range(BEAT_BYTES):
        if mask & (1 << b):
            ref_mem[base + b] = (data >> (8 * b)) & 0xFF


async def _setup(dut):
    cocotb.start_soon(Clock(dut.clock, 10, units="ns").start())
    await reset_dut(dut)
    axi = AxiLiteSlave(dut)
    axi.start()
    tl = TLULMaster(dut)
    return tl, axi


@cocotb.test()
async def test_aligned_put_get(dut):
    """32-bit aligned PutFull + Get round-trip at 0x100."""
    tl, _ = await _setup(dut)
    wdata = 0xDEADBEEF
    r = await tl.put_full(0x100, 2, 1, wdata)
    assert r.opcode == D_ACCESS_ACK and not r.denied
    r = await tl.get(0x100, 2, 2)
    assert r.opcode == D_ACCESS_ACK_DATA and r.source == 2 and r.size == 2
    assert r.data == wdata, f"expected {wdata:#010x}, got {r.data:#010x}"


@cocotb.test()
async def test_byte_lanes(dut):
    """Single-byte (size=0) write+read at each lane of the 32-bit beat."""
    tl, _ = await _setup(dut)
    ref: dict[int, int] = {}
    for off in range(BEAT_BYTES):
        addr = 0x200 + off
        val = (0xA0 + off) << (8 * off)
        # Drive the byte data with the matching mask bit on.
        mask = 1 << off
        _apply_put(ref, addr, val, mask)
        await tl.put_full(addr, 0, 3, val)
        r = await tl.get(addr, 2, 4)
        expect = _ref_beat(ref, addr)
        assert r.data == expect, f"lane {off}: got {r.data:#010x} want {expect:#010x}"


@cocotb.test()
async def test_half_word(dut):
    """16-bit (size=1) writes at both halves of a beat, then full-beat Get."""
    tl, _ = await _setup(dut)
    ref: dict[int, int] = {}
    addr_lo, addr_hi = 0x300, 0x302
    lo_data = 0x0000BEEF
    hi_data = 0xCAFE0000

    _apply_put(ref, addr_lo, lo_data, 0b0011)
    _apply_put(ref, addr_hi, hi_data, 0b1100)
    await tl.put_full(addr_lo, 1, 5, lo_data)
    await tl.put_full(addr_hi, 1, 5, hi_data)

    r = await tl.get(addr_lo, 2, 6)
    assert r.data == _ref_beat(ref, addr_lo)


@cocotb.test()
async def test_partial_put(dut):
    """PutPartialData with a custom mask — only bytes 1 and 2 written."""
    tl, _ = await _setup(dut)
    ref: dict[int, int] = {}
    addr = 0x400
    data = 0xAABBCCDD
    mask = 0b0110
    _apply_put(ref, addr, data, mask)

    r = await tl.put_partial(addr, 2, 7, data, mask)
    assert r.opcode == D_ACCESS_ACK and not r.denied
    r = await tl.get(addr, 2, 8)
    assert r.data == _ref_beat(ref, addr), \
        f"partial readback: got {r.data:#010x} want {_ref_beat(ref, addr):#010x}"


@cocotb.test()
async def test_hint(dut):
    """Hint -> HintAck."""
    tl, _ = await _setup(dut)
    r = await tl.hint(0x500, 2, 9)
    assert r.opcode == D_HINT_ACK and r.source == 9
