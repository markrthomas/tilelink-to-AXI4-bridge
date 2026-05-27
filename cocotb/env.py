"""Shared TileLink master + behavioral AXI4 slave for the TLUHToAXI4 cocotb env.

Pairs with the C++ Verilator TB (`test/cpp/tb_main.cpp`) — they exercise the
same RTL through different drivers.

* ``TLMaster``  drives the bridge's TL-A slave port and collects D responses.
* ``AxiSlave``  models an AXI subordinate with a sparse byte-addressed
                memory, one outstanding write and one outstanding read.
* ``reset_dut`` holds reset high for N cycles then releases.

Bridge ports are 64-bit data / 32-bit address / 8 bytes per beat (see
``BridgeParams`` in ``src/main/scala/tlbridge/Bundles.scala``).
"""

import cocotb
from cocotb.triggers import RisingEdge

# TL A-channel opcodes
OP_PUT_FULL = 0
OP_PUT_PART = 1
OP_GET      = 4
OP_HINT     = 5
# TL D-channel opcodes
D_ACCESS_ACK      = 0
D_ACCESS_ACK_DATA = 1
D_HINT_ACK        = 2

BEAT_BYTES   = 8
BEAT_SIZE_LG = 3
FULL_MASK    = (1 << BEAT_BYTES) - 1


def beats_for_size(size: int) -> int:
    """TL→AXI burst beat count: max(1, (1<<size) // beat_bytes)."""
    total = 1 << size
    return 1 if total <= BEAT_BYTES else total // BEAT_BYTES


async def reset_dut(dut, cycles: int = 8):
    """Hold reset high for N cycles, then release."""
    dut.reset.value = 1
    for name in (
        "io_tl_a_valid", "io_tl_a_bits_opcode", "io_tl_a_bits_param",
        "io_tl_a_bits_size", "io_tl_a_bits_source", "io_tl_a_bits_address",
        "io_tl_a_bits_mask", "io_tl_a_bits_data", "io_tl_a_bits_corrupt",
        "io_tl_d_ready",
        "io_axi_aw_ready", "io_axi_w_ready",
        "io_axi_b_valid", "io_axi_b_bits_id", "io_axi_b_bits_resp",
        "io_axi_ar_ready",
        "io_axi_r_valid", "io_axi_r_bits_id", "io_axi_r_bits_data",
        "io_axi_r_bits_resp", "io_axi_r_bits_last",
    ):
        getattr(dut, name).value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clock)
    dut.reset.value = 0
    await RisingEdge(dut.clock)


class TLResponse:
    __slots__ = ("opcode", "size", "source", "denied", "corrupt", "data")

    def __init__(self, opcode, size, source, denied, corrupt, data):
        self.opcode  = opcode
        self.size    = size
        self.source  = source
        self.denied  = denied
        self.corrupt = corrupt
        self.data    = data

    def __repr__(self):
        return (f"TLResponse(opcode={self.opcode}, size={self.size}, "
                f"source={self.source}, denied={self.denied}, "
                f"corrupt={self.corrupt}, data={self.data})")


class TLMaster:
    """Drives TL-A and consumes TL-D one transaction at a time."""

    def __init__(self, dut):
        self.dut = dut
        dut.io_tl_d_ready.value = 1   # always accept D

    def _set_a_idle(self):
        d = self.dut
        d.io_tl_a_valid.value         = 0
        d.io_tl_a_bits_opcode.value   = 0
        d.io_tl_a_bits_param.value    = 0
        d.io_tl_a_bits_size.value     = 0
        d.io_tl_a_bits_source.value   = 0
        d.io_tl_a_bits_address.value  = 0
        d.io_tl_a_bits_mask.value     = 0
        d.io_tl_a_bits_data.value     = 0
        d.io_tl_a_bits_corrupt.value  = 0

    def _drive_a_beat(self, opcode, size, source, address, data, mask):
        d = self.dut
        d.io_tl_a_valid.value         = 1
        d.io_tl_a_bits_opcode.value   = opcode
        d.io_tl_a_bits_param.value    = 0
        d.io_tl_a_bits_size.value     = size
        d.io_tl_a_bits_source.value   = source
        d.io_tl_a_bits_address.value  = address
        d.io_tl_a_bits_mask.value     = mask
        d.io_tl_a_bits_data.value     = data
        d.io_tl_a_bits_corrupt.value  = 0

    async def _wait_a_fire(self):
        """Wait until io_tl_a_ready is high on a rising edge."""
        while True:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_a_ready.value) == 1:
                return

    async def _collect_response(self, source: int, beats: int) -> TLResponse:
        opcode = None
        size = None
        denied = False
        corrupt = False
        data_beats = []
        got = 0
        while got < beats:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_d_valid.value) == 1 and \
               int(self.dut.io_tl_d_bits_source.value) == source:
                opcode  = int(self.dut.io_tl_d_bits_opcode.value)
                size    = int(self.dut.io_tl_d_bits_size.value)
                denied  = bool(int(self.dut.io_tl_d_bits_denied.value))
                corrupt = corrupt or bool(int(self.dut.io_tl_d_bits_corrupt.value))
                if opcode == D_ACCESS_ACK_DATA:
                    data_beats.append(int(self.dut.io_tl_d_bits_data.value))
                got += 1
        return TLResponse(opcode=opcode, size=size, source=source,
                          denied=denied, corrupt=corrupt, data=data_beats)

    async def get(self, address: int, size: int, source: int) -> TLResponse:
        self._drive_a_beat(OP_GET, size, source, address, 0, FULL_MASK)
        await self._wait_a_fire()
        self._set_a_idle()
        return await self._collect_response(source, beats_for_size(size))

    async def hint(self, address: int, size: int, source: int) -> TLResponse:
        self._drive_a_beat(OP_HINT, size, source, address, 0, FULL_MASK)
        await self._wait_a_fire()
        self._set_a_idle()
        return await self._collect_response(source, 1)

    async def put_full(self, address: int, size: int, source: int,
                       data) -> TLResponse:
        beats = beats_for_size(size)
        assert len(data) == beats, f"PutFull needs {beats} beats, got {len(data)}"
        if (1 << size) < BEAT_BYTES:
            bytes_ = 1 << size
            off    = address & (BEAT_BYTES - 1)
            masks  = [((1 << bytes_) - 1) << off] + [FULL_MASK] * (beats - 1)
        else:
            masks = [FULL_MASK] * beats
        return await self._burst_put(OP_PUT_FULL, address, size, source,
                                     data, masks)

    async def put_partial(self, address: int, size: int, source: int,
                          data, masks) -> TLResponse:
        beats = beats_for_size(size)
        assert len(data) == beats and len(masks) == beats
        return await self._burst_put(OP_PUT_PART, address, size, source,
                                     data, masks)

    async def _burst_put(self, opcode, address, size, source, data, masks):
        beats = beats_for_size(size)
        for i in range(beats):
            self._drive_a_beat(opcode, size, source, address,
                               data[i], masks[i])
            await self._wait_a_fire()
        self._set_a_idle()
        return await self._collect_response(source, 1)


class AxiSlave:
    """Behavioral AXI4 subordinate with a sparse byte-addressed memory.

    One outstanding write (AW → W → B) and one outstanding read (AR → R)
    at a time — matches the bridge's per-engine capacity.  Memory is a
    dict keyed by byte address; unwritten bytes read as zero.
    """

    def __init__(self, dut):
        self.dut = dut
        self.mem: dict[int, int] = {}
        self._tasks: list = []

    def start(self):
        self._tasks.append(cocotb.start_soon(self._write_loop()))
        self._tasks.append(cocotb.start_soon(self._read_loop()))

    async def _wait_handshake(self, valid_attr: str, ready_attr: str):
        """Wait for valid && ready on a rising edge of clock."""
        d = self.dut
        while True:
            await RisingEdge(d.clock)
            if int(getattr(d, valid_attr).value) == 1 and \
               int(getattr(d, ready_attr).value) == 1:
                return

    async def _write_loop(self):
        d = self.dut
        while True:
            # ---- AW
            d.io_axi_aw_ready.value = 1
            await self._wait_handshake("io_axi_aw_valid", "io_axi_aw_ready")
            aw_addr = int(d.io_axi_aw_bits_addr.value)
            aw_len  = int(d.io_axi_aw_bits_len.value)
            aw_id   = int(d.io_axi_aw_bits_id.value)
            d.io_axi_aw_ready.value = 0

            # ---- W beats
            d.io_axi_w_ready.value = 1
            base = aw_addr & ~(BEAT_BYTES - 1)
            beat = 0
            while True:
                await self._wait_handshake("io_axi_w_valid", "io_axi_w_ready")
                wd   = int(d.io_axi_w_bits_data.value)
                strb = int(d.io_axi_w_bits_strb.value)
                last = int(d.io_axi_w_bits_last.value) == 1
                addr = base + beat * BEAT_BYTES
                for b in range(BEAT_BYTES):
                    if strb & (1 << b):
                        self.mem[addr + b] = (wd >> (8 * b)) & 0xFF
                if last:
                    assert beat == aw_len, \
                        f"WLAST/AWLEN mismatch: wlast at beat {beat}, awLen={aw_len}"
                    break
                beat += 1
            d.io_axi_w_ready.value = 0

            # ---- B
            d.io_axi_b_valid.value     = 1
            d.io_axi_b_bits_id.value   = aw_id
            d.io_axi_b_bits_resp.value = 0
            await self._wait_handshake("io_axi_b_valid", "io_axi_b_ready")
            d.io_axi_b_valid.value = 0

    async def _read_loop(self):
        d = self.dut
        while True:
            d.io_axi_ar_ready.value = 1
            await self._wait_handshake("io_axi_ar_valid", "io_axi_ar_ready")
            ar_addr = int(d.io_axi_ar_bits_addr.value)
            ar_len  = int(d.io_axi_ar_bits_len.value)
            ar_id   = int(d.io_axi_ar_bits_id.value)
            d.io_axi_ar_ready.value = 0

            base = ar_addr & ~(BEAT_BYTES - 1)
            for beat in range(ar_len + 1):
                addr = base + beat * BEAT_BYTES
                data = 0
                for b in range(BEAT_BYTES):
                    data |= (self.mem.get(addr + b, 0) & 0xFF) << (8 * b)
                d.io_axi_r_valid.value     = 1
                d.io_axi_r_bits_data.value = data
                d.io_axi_r_bits_id.value   = ar_id
                d.io_axi_r_bits_resp.value = 0
                d.io_axi_r_bits_last.value = 1 if beat == ar_len else 0
                await self._wait_handshake("io_axi_r_valid", "io_axi_r_ready")
            d.io_axi_r_valid.value     = 0
            d.io_axi_r_bits_last.value = 0
