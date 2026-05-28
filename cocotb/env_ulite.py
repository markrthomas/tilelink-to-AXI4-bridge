"""Shared TileLink-UL master + behavioral AXI4-Lite slave for TLULToAXILite.

Pairs with the C++ Verilator TB (``test/cpp/tb_ulite.cpp``) — they exercise the
same RTL through different drivers.

* ``TLULMaster``    drives the bridge's TL-A slave port and collects D responses.
* ``AxiLiteSlave``  models an AXI4-Lite subordinate with a sparse byte-addressed
                    memory; one outstanding write (AW+W -> B) and one
                    outstanding read (AR -> R).
* ``reset_dut``     holds reset high for N cycles then releases.

Bridge ports are 32-bit data / 32-bit address / 4 bytes per beat (see
``ULBridgeParams`` in ``src/main/scala/tlbridge/TLULToAXILite.scala``).
TL-UL is single-beat — there are no bursts to assemble.
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

BEAT_BYTES   = 4
BEAT_SIZE_LG = 2
FULL_MASK    = (1 << BEAT_BYTES) - 1


async def reset_dut(dut, cycles: int = 8):
    """Hold reset high for N cycles, then release."""
    dut.reset.value = 1
    for name in (
        "io_tl_a_valid", "io_tl_a_bits_opcode", "io_tl_a_bits_param",
        "io_tl_a_bits_size", "io_tl_a_bits_source", "io_tl_a_bits_address",
        "io_tl_a_bits_mask", "io_tl_a_bits_data", "io_tl_a_bits_corrupt",
        "io_tl_d_ready",
        "io_axi_aw_ready", "io_axi_w_ready",
        "io_axi_b_valid", "io_axi_b_bits_resp",
        "io_axi_ar_ready",
        "io_axi_r_valid", "io_axi_r_bits_data", "io_axi_r_bits_resp",
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
                f"corrupt={self.corrupt}, data={self.data:#x})")


class TLULMaster:
    """Drives TL-A and consumes TL-D one transaction at a time.

    TL-UL is single-beat, so the per-request handshake is just one A.fire
    followed by a matching D.fire.  D is matched by source so concurrent
    in-flight transactions across the three engines (read / write / hint)
    can complete in any order.
    """

    def __init__(self, dut):
        self.dut = dut
        dut.io_tl_d_ready.value = 1

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
        while True:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_a_ready.value) == 1:
                return

    async def _collect_response(self, source: int) -> TLResponse:
        while True:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_d_valid.value) == 1 and \
               int(self.dut.io_tl_d_bits_source.value) == source:
                return TLResponse(
                    opcode  = int(self.dut.io_tl_d_bits_opcode.value),
                    size    = int(self.dut.io_tl_d_bits_size.value),
                    source  = source,
                    denied  = bool(int(self.dut.io_tl_d_bits_denied.value)),
                    corrupt = bool(int(self.dut.io_tl_d_bits_corrupt.value)),
                    data    = int(self.dut.io_tl_d_bits_data.value),
                )

    async def get(self, address: int, size: int, source: int) -> TLResponse:
        self._drive_a_beat(OP_GET, size, source, address, 0, FULL_MASK)
        await self._wait_a_fire()
        self._set_a_idle()
        return await self._collect_response(source)

    async def hint(self, address: int, size: int, source: int) -> TLResponse:
        self._drive_a_beat(OP_HINT, size, source, address, 0, FULL_MASK)
        await self._wait_a_fire()
        self._set_a_idle()
        return await self._collect_response(source)

    async def put_full(self, address: int, size: int, source: int,
                       data: int) -> TLResponse:
        if (1 << size) < BEAT_BYTES:
            nbytes = 1 << size
            off    = address & (BEAT_BYTES - 1)
            mask = ((1 << nbytes) - 1) << off
        else:
            mask = FULL_MASK
        self._drive_a_beat(OP_PUT_FULL, size, source, address, data, mask)
        await self._wait_a_fire()
        self._set_a_idle()
        return await self._collect_response(source)

    async def put_partial(self, address: int, size: int, source: int,
                          data: int, mask: int) -> TLResponse:
        self._drive_a_beat(OP_PUT_PART, size, source, address, data, mask)
        await self._wait_a_fire()
        self._set_a_idle()
        return await self._collect_response(source)


class AxiLiteSlave:
    """Behavioral AXI4-Lite subordinate with a sparse byte-addressed memory.

    AW and W may arrive in either order; the slave waits for both before
    committing the write to memory and emitting B.  AR/R is a simple
    1-outstanding read pipe.  No bursts, no IDs.
    """

    def __init__(self, dut):
        self.dut = dut
        self.mem: dict[int, int] = {}
        self._tasks: list = []

    def start(self):
        self._tasks.append(cocotb.start_soon(self._write_loop()))
        self._tasks.append(cocotb.start_soon(self._read_loop()))

    async def _wait_handshake(self, valid_attr: str, ready_attr: str):
        d = self.dut
        while True:
            await RisingEdge(d.clock)
            if int(getattr(d, valid_attr).value) == 1 and \
               int(getattr(d, ready_attr).value) == 1:
                return

    async def _write_loop(self):
        d = self.dut
        while True:
            # Accept AW and W in either order — including simultaneously,
            # which is the bridge's common case (it raises both valids on
            # the same cycle and waits for both readys before advancing).
            d.io_axi_aw_ready.value = 1
            d.io_axi_w_ready.value  = 1
            got_aw = False
            got_w  = False
            aw_addr = 0
            wd      = 0
            strb    = 0
            while not (got_aw and got_w):
                await RisingEdge(d.clock)
                if not got_aw and int(d.io_axi_aw_valid.value) == 1 and \
                                  int(d.io_axi_aw_ready.value) == 1:
                    aw_addr = int(d.io_axi_aw_bits_addr.value)
                    got_aw = True
                    d.io_axi_aw_ready.value = 0
                if not got_w  and int(d.io_axi_w_valid.value)  == 1 and \
                                  int(d.io_axi_w_ready.value)  == 1:
                    wd   = int(d.io_axi_w_bits_data.value)
                    strb = int(d.io_axi_w_bits_strb.value)
                    got_w = True
                    d.io_axi_w_ready.value = 0
            base = aw_addr & ~(BEAT_BYTES - 1)
            for b in range(BEAT_BYTES):
                if strb & (1 << b):
                    self.mem[base + b] = (wd >> (8 * b)) & 0xFF

            d.io_axi_b_valid.value     = 1
            d.io_axi_b_bits_resp.value = 0
            await self._wait_handshake("io_axi_b_valid", "io_axi_b_ready")
            d.io_axi_b_valid.value = 0

    async def _read_loop(self):
        d = self.dut
        while True:
            d.io_axi_ar_ready.value = 1
            await self._wait_handshake("io_axi_ar_valid", "io_axi_ar_ready")
            ar_addr = int(d.io_axi_ar_bits_addr.value)
            d.io_axi_ar_ready.value = 0

            base = ar_addr & ~(BEAT_BYTES - 1)
            data = 0
            for b in range(BEAT_BYTES):
                data |= (self.mem.get(base + b, 0) & 0xFF) << (8 * b)
            d.io_axi_r_valid.value     = 1
            d.io_axi_r_bits_data.value = data
            d.io_axi_r_bits_resp.value = 0
            await self._wait_handshake("io_axi_r_valid", "io_axi_r_ready")
            d.io_axi_r_valid.value = 0
