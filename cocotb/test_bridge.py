"""Directed cocotb tests for TLUHToAXI4.

Mirrors a subset of the C++ TB's directed jobs.  Verifier model: each TL
request expects a specific D opcode/source/size and (for Get) per-beat
data drawn from a Python-side reference memory updated by Put requests.
"""

import cocotb
from cocotb.clock import Clock

from env import (
    AxiSlave, TLMaster, beats_for_size, reset_dut,
    BEAT_BYTES, FULL_MASK,
    D_ACCESS_ACK, D_ACCESS_ACK_DATA, D_HINT_ACK,
)


def _ref_beat(ref_mem: dict[int, int], address: int, beat_idx: int) -> int:
    """Reconstruct a beat from the byte-addressable reference memory."""
    base = address & ~(BEAT_BYTES - 1)
    a    = base + beat_idx * BEAT_BYTES
    data = 0
    for b in range(BEAT_BYTES):
        data |= (ref_mem.get(a + b, 0) & 0xFF) << (8 * b)
    return data


def _apply_put(ref_mem: dict[int, int], address: int, size: int,
               data: list[int], masks: list[int]):
    """Update the reference memory with a Put burst."""
    beats = beats_for_size(size)
    base  = address & ~(BEAT_BYTES - 1)
    for beat in range(beats):
        d = data[beat]
        m = masks[beat]
        for b in range(BEAT_BYTES):
            if m & (1 << b):
                ref_mem[base + beat * BEAT_BYTES + b] = (d >> (8 * b)) & 0xFF


async def _setup(dut):
    cocotb.start_soon(Clock(dut.clock, 10, units="ns").start())
    await reset_dut(dut)
    axi = AxiSlave(dut)
    axi.start()
    tl = TLMaster(dut)
    return tl, axi


@cocotb.test()
async def test_aligned_put_get(dut):
    """64-bit aligned PutFull + Get round-trip at 0x100."""
    tl, _ = await _setup(dut)
    WDATA = 0xDEADBEEFCAFEBABE
    r = await tl.put_full(0x100, 3, 1, [WDATA])
    assert r.opcode == D_ACCESS_ACK
    assert not r.denied
    r = await tl.get(0x100, 3, 2)
    assert r.opcode == D_ACCESS_ACK_DATA
    assert r.source == 2 and r.size == 3
    assert r.data == [WDATA], f"expected [{WDATA:#018x}], got {[hex(x) for x in r.data]}"


@cocotb.test()
async def test_sub_bus_halves(dut):
    """32-bit writes at the low and high halves of an 8-byte beat."""
    tl, _ = await _setup(dut)
    ref = {}
    addr_lo, addr_hi = 0x200, 0x204
    lo_data = 0x00000000A5A5A5A5
    hi_data = 0xC3C3C3C300000000

    masks_lo = [((1 << 4) - 1) << 0]
    masks_hi = [((1 << 4) - 1) << 4]
    _apply_put(ref, addr_lo, 2, [lo_data], masks_lo)
    _apply_put(ref, addr_hi, 2, [hi_data], masks_hi)

    await tl.put_full(addr_lo, 2, 3, [lo_data])
    await tl.put_full(addr_hi, 2, 3, [hi_data])

    r = await tl.get(addr_lo, 2, 4)
    assert r.data == [_ref_beat(ref, addr_lo, 0)]
    r = await tl.get(addr_hi, 2, 4)
    assert r.data == [_ref_beat(ref, addr_hi, 0)]


@cocotb.test()
async def test_4beat_burst(dut):
    """32-byte burst (size=5, 4 beats) write + read at 0x400."""
    tl, _ = await _setup(dut)
    payload = [
        0x1111111111111111, 0x2222222222222222,
        0x3333333333333333, 0x4444444444444444,
    ]
    await tl.put_full(0x400, 5, 5, payload)
    r = await tl.get(0x400, 5, 6)
    assert r.opcode == D_ACCESS_ACK_DATA
    assert r.data == payload, f"burst readback mismatch: {[hex(x) for x in r.data]}"


@cocotb.test()
async def test_2beat_partial(dut):
    """PutPartialData burst (2 beats), per-beat WSTRB pattern, then Get."""
    tl, _ = await _setup(dut)
    addr = 0x600
    data = [0x1010101010101010, 0x2020202020202020]
    masks = [0xF0, 0x0F]
    ref = {}
    _apply_put(ref, addr, 4, data, masks)

    await tl.put_partial(addr, 4, 11, data, masks)
    r = await tl.get(addr, 4, 12)
    expect = [_ref_beat(ref, addr, b) for b in range(2)]
    assert r.data == expect, f"partial readback: got={[hex(x) for x in r.data]} want={[hex(x) for x in expect]}"


@cocotb.test()
async def test_hint(dut):
    """Hint -> HintAck."""
    tl, _ = await _setup(dut)
    r = await tl.hint(0x700, 3, 13)
    assert r.opcode == D_HINT_ACK
    assert r.source == 13


@cocotb.test()
async def test_byte_at_offset(dut):
    """Single-byte (size=0) write+read at offset 3 of a beat."""
    tl, _ = await _setup(dut)
    addr = 0x803
    val  = 0xEE << (8 * 3)
    await tl.put_full(addr, 0, 14, [val])
    r = await tl.get(addr, 0, 15)
    assert r.opcode == D_ACCESS_ACK_DATA
    # The Get returns the full 8-byte beat at the aligned base; only the
    # target byte should be non-zero.
    assert r.data == [val], f"byte readback: {[hex(x) for x in r.data]}"
