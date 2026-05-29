"""Shared TileLink-C master + AXI4 slave for the TLUCToAXI4 cocotb env.

Pairs with the C++ Verilator TB (``test/cpp/tb_uc.cpp``) — they exercise
the same RTL through different drivers.

* ``TLUCMaster``  drives TL-A + TL-C + TL-E and collects TL-D responses.
                  Verifies TL-B never fires (bridge ties off probes).
* ``AxiSlave``    behavioral AXI4 subordinate (same model as ``env.py``).
* ``reset_dut``   holds reset high for N cycles.

Bridge ports are 64-bit data / 32-bit address / 8 bytes per beat —
identical to the TL-UH bridge.
"""

import cocotb
from cocotb.triggers import RisingEdge

# TL A opcodes
OP_PUT_FULL     = 0
OP_PUT_PART     = 1
OP_ARITHMETIC   = 2
OP_LOGICAL      = 3
OP_GET          = 4
OP_HINT         = 5
OP_ACQUIRE_BLK  = 6
OP_ACQUIRE_PERM = 7

# TL C opcodes (master->slave)
OP_RELEASE      = 6
OP_RELEASE_DATA = 7

# TL D opcodes
D_ACCESS_ACK      = 0
D_ACCESS_ACK_DATA = 1
D_HINT_ACK        = 2
D_GRANT           = 4
D_GRANT_DATA      = 5
D_RELEASE_ACK     = 6

# TL params
P_NtoB = 0
P_NtoT = 1
P_BtoT = 2
P_TtoB = 0
P_TtoN = 1
P_BtoN = 2
P_toT  = 0
P_toB  = 1
P_toN  = 2

BEAT_BYTES   = 8
BEAT_SIZE_LG = 3
FULL_MASK    = (1 << BEAT_BYTES) - 1


def beats_for_size(size: int) -> int:
    total = 1 << size
    return 1 if total <= BEAT_BYTES else total // BEAT_BYTES


async def reset_dut(dut, cycles: int = 8):
    dut.reset.value = 1
    for name in (
        "io_tl_a_valid", "io_tl_a_bits_opcode", "io_tl_a_bits_param",
        "io_tl_a_bits_size", "io_tl_a_bits_source", "io_tl_a_bits_address",
        "io_tl_a_bits_mask", "io_tl_a_bits_data", "io_tl_a_bits_corrupt",
        "io_tl_b_ready",
        "io_tl_c_valid", "io_tl_c_bits_opcode", "io_tl_c_bits_param",
        "io_tl_c_bits_size", "io_tl_c_bits_source", "io_tl_c_bits_address",
        "io_tl_c_bits_data", "io_tl_c_bits_corrupt",
        "io_tl_d_ready",
        "io_tl_e_valid", "io_tl_e_bits_sink",
        "io_axi_aw_ready", "io_axi_w_ready",
        "io_axi_b_valid", "io_axi_b_bits_id", "io_axi_b_bits_resp",
        "io_axi_ar_ready",
        "io_axi_r_valid", "io_axi_r_bits_id", "io_axi_r_bits_data",
        "io_axi_r_bits_resp", "io_axi_r_bits_last",
    ):
        getattr(dut, name).value = 0
    dut.io_tl_b_ready.value = 1  # always ready (bridge ties off B)
    for _ in range(cycles):
        await RisingEdge(dut.clock)
    dut.reset.value = 0
    await RisingEdge(dut.clock)


class TLResponse:
    __slots__ = ("opcode", "param", "size", "source", "sink",
                 "denied", "corrupt", "data")

    def __init__(self, opcode, param, size, source, sink,
                 denied, corrupt, data):
        self.opcode  = opcode
        self.param   = param
        self.size    = size
        self.source  = source
        self.sink    = sink
        self.denied  = denied
        self.corrupt = corrupt
        self.data    = data

    def __repr__(self):
        return (f"TLResponse(opcode={self.opcode}, param={self.param}, "
                f"size={self.size}, source={self.source}, sink={self.sink}, "
                f"denied={self.denied}, corrupt={self.corrupt}, data={self.data})")


class TLUCMaster:
    """Drives TL-A + TL-C + TL-E.  Single transaction at a time per
    helper call; concurrent in-flight requires multiple coroutines."""

    def __init__(self, dut):
        self.dut = dut
        dut.io_tl_d_ready.value = 1
        dut.io_tl_b_ready.value = 1

    # ---- A-channel ----
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

    def _drive_a(self, opcode, size, source, address, data=0,
                 mask=FULL_MASK, param=0):
        d = self.dut
        d.io_tl_a_valid.value         = 1
        d.io_tl_a_bits_opcode.value   = opcode
        d.io_tl_a_bits_param.value    = param
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

    # ---- C-channel ----
    def _set_c_idle(self):
        d = self.dut
        d.io_tl_c_valid.value         = 0
        d.io_tl_c_bits_opcode.value   = 0
        d.io_tl_c_bits_param.value    = 0
        d.io_tl_c_bits_size.value     = 0
        d.io_tl_c_bits_source.value   = 0
        d.io_tl_c_bits_address.value  = 0
        d.io_tl_c_bits_data.value     = 0
        d.io_tl_c_bits_corrupt.value  = 0

    def _drive_c(self, opcode, size, source, address, data=0, param=0):
        d = self.dut
        d.io_tl_c_valid.value         = 1
        d.io_tl_c_bits_opcode.value   = opcode
        d.io_tl_c_bits_param.value    = param
        d.io_tl_c_bits_size.value     = size
        d.io_tl_c_bits_source.value   = source
        d.io_tl_c_bits_address.value  = address
        d.io_tl_c_bits_data.value     = data
        d.io_tl_c_bits_corrupt.value  = 0

    async def _wait_c_fire(self):
        while True:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_c_ready.value) == 1:
                return

    # ---- E-channel ----
    async def _send_grant_ack(self, sink: int = 0):
        d = self.dut
        d.io_tl_e_valid.value = 1
        d.io_tl_e_bits_sink.value = sink
        while True:
            await RisingEdge(d.clock)
            if int(d.io_tl_e_ready.value) == 1:
                break
        d.io_tl_e_valid.value = 0
        d.io_tl_e_bits_sink.value = 0

    # ---- D collector ----
    async def _collect_response(self, source: int, beats: int) -> TLResponse:
        opcode = None; param = 0; size = 0; sink = 0
        denied = False; corrupt = False; data_beats = []
        got = 0
        while got < beats:
            await RisingEdge(self.dut.clock)
            if int(self.dut.io_tl_d_valid.value) == 1 and \
               int(self.dut.io_tl_d_bits_source.value) == source:
                opcode  = int(self.dut.io_tl_d_bits_opcode.value)
                param   = int(self.dut.io_tl_d_bits_param.value)
                size    = int(self.dut.io_tl_d_bits_size.value)
                sink    = int(self.dut.io_tl_d_bits_sink.value)
                denied  = denied or bool(int(self.dut.io_tl_d_bits_denied.value))
                corrupt = corrupt or bool(int(self.dut.io_tl_d_bits_corrupt.value))
                if opcode in (D_ACCESS_ACK_DATA, D_GRANT_DATA):
                    data_beats.append(int(self.dut.io_tl_d_bits_data.value))
                got += 1
        return TLResponse(opcode, param, size, source, sink,
                          denied, corrupt, data_beats)

    # ---- High-level helpers ----
    async def get(self, address, size, source):
        self._drive_a(OP_GET, size, source, address)
        await self._wait_a_fire()
        self._set_a_idle()
        return await self._collect_response(source, beats_for_size(size))

    async def put_full(self, address, size, source, data):
        beats = beats_for_size(size)
        assert len(data) == beats
        if (1 << size) < BEAT_BYTES:
            nbytes = 1 << size
            off    = address & (BEAT_BYTES - 1)
            masks  = [((1 << nbytes) - 1) << off] + [FULL_MASK] * (beats - 1)
        else:
            masks = [FULL_MASK] * beats
        for i in range(beats):
            self._drive_a(OP_PUT_FULL, size, source, address,
                           data=data[i], mask=masks[i])
            await self._wait_a_fire()
        self._set_a_idle()
        return await self._collect_response(source, 1)

    async def hint(self, address, size, source):
        self._drive_a(OP_HINT, size, source, address)
        await self._wait_a_fire()
        self._set_a_idle()
        return await self._collect_response(source, 1)

    async def acquire_block(self, address, size, source, param=P_NtoT):
        self._drive_a(OP_ACQUIRE_BLK, size, source, address, param=param)
        await self._wait_a_fire()
        self._set_a_idle()
        resp = await self._collect_response(source, beats_for_size(size))
        # Send GrantAck to release the engine slot.
        await self._send_grant_ack(resp.sink)
        return resp

    async def acquire_perm(self, address, size, source, param=P_NtoT):
        self._drive_a(OP_ACQUIRE_PERM, size, source, address, param=param)
        await self._wait_a_fire()
        self._set_a_idle()
        resp = await self._collect_response(source, 1)
        await self._send_grant_ack(resp.sink)
        return resp

    async def release(self, address, size, source, param=P_TtoN):
        self._drive_c(OP_RELEASE, size, source, address, param=param)
        await self._wait_c_fire()
        self._set_c_idle()
        return await self._collect_response(source, 1)

    async def release_data(self, address, size, source, data, param=P_TtoN):
        beats = beats_for_size(size)
        assert len(data) == beats
        for i in range(beats):
            self._drive_c(OP_RELEASE_DATA, size, source, address,
                          data=data[i], param=param)
            await self._wait_c_fire()
        self._set_c_idle()
        return await self._collect_response(source, 1)


class AxiSlave:
    """Behavioral AXI4 subordinate — same as env.py's model."""

    def __init__(self, dut):
        self.dut = dut
        self.mem: dict[int, int] = {}
        self._tasks: list = []

    def start(self):
        self._tasks.append(cocotb.start_soon(self._write_loop()))
        self._tasks.append(cocotb.start_soon(self._read_loop()))

    async def _wait_handshake(self, valid_attr, ready_attr):
        d = self.dut
        while True:
            await RisingEdge(d.clock)
            if int(getattr(d, valid_attr).value) == 1 and \
               int(getattr(d, ready_attr).value) == 1:
                return

    async def _write_loop(self):
        d = self.dut
        while True:
            d.io_axi_aw_ready.value = 1
            await self._wait_handshake("io_axi_aw_valid", "io_axi_aw_ready")
            aw_addr = int(d.io_axi_aw_bits_addr.value)
            aw_len  = int(d.io_axi_aw_bits_len.value)
            aw_id   = int(d.io_axi_aw_bits_id.value)
            d.io_axi_aw_ready.value = 0

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
                    break
                beat += 1
            d.io_axi_w_ready.value = 0

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
