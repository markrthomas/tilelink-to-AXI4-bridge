# TileLink-UL → AXI4-Lite Bridge — Design Specification

This document defines the contract of the `TLULToAXILite` bridge: signal
interfaces, opcode mapping, FSM behavior, and the set of intentional
restrictions.  The Chisel source
(`src/main/scala/tlbridge/TLULToAXILite.scala`) is the implementation;
this spec is the reference behavior.  Where they disagree, this document
wins and the source must be brought into line.

The sibling [`DESIGN_SPEC.md`](DESIGN_SPEC.md) documents the larger
TL-UH → AXI4 bridge; this file is the equivalent contract for the
control-plane TL-UL → AXI4-Lite variant.

## Overview

```
+---------+   Channel A   +-----------------+    AW / W   +-------------+
|  TL-UL  | ------------> |                 | ----------> | AXI4-Lite   |
|  HOST   |               |  TLULToAXILite  |     B       | SUBORDINATE |
| (Mgr.)  | <------------ |     (this)      | <---------- |             |
|         |   Channel D   |                 |    AR / R   |             |
+---------+               +-----------------+ <---------> +-------------+
```

The bridge is a TileLink **slave** (it sinks `A`, sources `D`) and an
AXI4-Lite **master** (it sources `AW`/`W`/`AR`, sinks `B`/`R`).  It runs
three independent engines (read, write, hint) plus a one-deep local-error
slot; a read, a write, and a hint can be in flight simultaneously
(peak observed concurrency = 3 in the regression workload).

TL-UL itself is the lightweight, single-beat profile of TileLink: no
bursts, no atomics, no probe/release.  AXI4-Lite is the corresponding
control-plane subset of AXI4: no bursts, no IDs, no LOCK, no CACHE.  The
mapping is therefore much tighter than the TL-UH → AXI4 case.

## Parameters

All parameters live in `ULBridgeParams`
(`src/main/scala/tlbridge/TLULToAXILite.scala`).  Default values match
the elaborated SV at `generated/ulite/TLULToAXILite.sv` and the
testbenches:

| Parameter | Default | Derived | Notes |
|-----------|---------|---------|-------|
| `addrBits` | 32 | — | TL `a_address` / AXI `Ax_addr` width |
| `dataBits` | 32 | `beatBytes = 4`, `strbBits = 4`, `beatSizeLg = 2`, `sizeBits = 2` | AXI4-Lite permits **only** 32 or 64; the bridge enforces at elaboration |
| `sourceBits` | 4 | — | TL `a_source` width.  AXI4-Lite has no ID; the bridge holds source locally and echoes it on D. |
| `respBits` | 2 | — | AXI `?RESP` width |
| `protBits` | 3 | — | AXI `AxPROT` width |

`sizeBits` is sized just large enough to express the legal range
`0 ≤ a.size ≤ log2(beatBytes)` plus headroom; the bridge uses
`a.size > log2(beatBytes)` as one of its local-error triggers.

Generation: `circt.stage.ChiselStage` via
`src/main/scala/tlbridge/Main.scala` emits to `generated/ulite/`.  The
TL-UH bridge and decoder variant continue to emit to `generated/` and
`generated/decoder/` respectively, so consumers (C++ TB, formal wrapper,
cocotb env) can pick the right top without collision.

## TileLink-UL interface

Two channels are exposed (`TLULSlaveIO`,
`src/main/scala/tlbridge/TLULToAXILite.scala`).  Names below match the
elaborated ports in `generated/ulite/TLULToAXILite.sv`.

### Channel A (host → bridge)

| Signal | Width (default) | Dir (slave) | Meaning |
|--------|-----------------|-------------|---------|
| `io_tl_a_valid` | 1 | in | A-beat available |
| `io_tl_a_ready` | 1 | out | Bridge accepts the current A-beat |
| `io_tl_a_bits_opcode` | 3 | in | `Get`=4, `PutFullData`=0, `PutPartialData`=1, `Hint`=5; others → local-error |
| `io_tl_a_bits_param` | 3 | in | Ignored (zero for the supported opcodes) |
| `io_tl_a_bits_size` | 2 | in | `log2(transaction bytes)`; must be ≤ `log2(beatBytes)` |
| `io_tl_a_bits_source` | 4 | in | Master-supplied transaction ID; echoed back on D |
| `io_tl_a_bits_address` | 32 | in | Byte address of the transaction |
| `io_tl_a_bits_mask` | 4 | in | Active-bytes mask (single beat) |
| `io_tl_a_bits_data` | 32 | in | Write data; ignored on Get/Hint |
| `io_tl_a_bits_corrupt` | 1 | in | Ignored — bridge does not propagate corrupt-in |

### Channel D (bridge → host)

| Signal | Width (default) | Dir (slave) | Meaning |
|--------|-----------------|-------------|---------|
| `io_tl_d_valid` | 1 | out | D-beat available |
| `io_tl_d_ready` | 1 | in | Master accepts the current D-beat |
| `io_tl_d_bits_opcode` | 3 | out | `AccessAck`=0, `AccessAckData`=1, `HintAck`=2 |
| `io_tl_d_bits_param` | 3 | out | Tied to 0 |
| `io_tl_d_bits_size` | 2 | out | Echoes the request `a_size` |
| `io_tl_d_bits_source` | 4 | out | Echoes the request `a_source` |
| `io_tl_d_bits_sink` | 1 | out | Tied to 0 |
| `io_tl_d_bits_denied` | 1 | out | `AXI ?RESP != OKAY` on a Get/Put lifts this; always set for local-error AccessAck |
| `io_tl_d_bits_data` | 32 | out | Beat payload for `AccessAckData` |
| `io_tl_d_bits_corrupt` | 1 | out | Read paths only — set when `RRESP[1]` is set (SLVERR/DECERR) |

Channels B / C / E from the larger TileLink spec are **not** present.

## AXI4-Lite interface

Five channels (`AxiLiteMasterIO`).  Names below match
`generated/ulite/TLULToAXILite.sv`.  All address-bearing fields carry only
`addr` and `prot` — no len/size/burst/id/lock/cache/qos/region.

### Write address (`AW`)

| Signal | Width (default) | Notes |
|--------|-----------------|-------|
| `io_axi_aw_valid` / `_ready` | 1 / 1 | Standard handshake; bridge issues concurrently with `W` |
| `io_axi_aw_bits_addr` | 32 | = `a_address` with low `beatSizeLg = 2` bits cleared |
| `io_axi_aw_bits_prot` | 3 | Tied to `3'b000` (data, secure, unprivileged) |

### Write data (`W`)

| Signal | Width (default) | Notes |
|--------|-----------------|-------|
| `io_axi_w_valid` / `_ready` | 1 / 1 | Issued concurrently with `AW`; either may handshake first |
| `io_axi_w_bits_data` | 32 | = TL `a_data` |
| `io_axi_w_bits_strb` | 4 | = TL `a_mask` |

No `WLAST` — every AXI4-Lite W beat is implicitly the last.

### Write response (`B`)

| Signal | Width (default) | Notes |
|--------|-----------------|-------|
| `io_axi_b_valid` / `_ready` | 1 / 1 | Coupled to `D` handshake while the write engine is in `sWResp` |
| `io_axi_b_bits_resp` | 2 | Non-zero → `D.denied` |

No `BID` — single-master, single-outstanding-per-engine.

### Read address (`AR`)

Same fields as `AW`: `addr` (bus-aligned) and `prot` (tied 0).

### Read data (`R`)

| Signal | Width (default) | Notes |
|--------|-----------------|-------|
| `io_axi_r_valid` / `_ready` | 1 / 1 | Forwarded directly to `D` in the read-response state |
| `io_axi_r_bits_data` | 32 | = `D.data` |
| `io_axi_r_bits_resp` | 2 | Non-zero → `D.denied`; bit 1 set (SLVERR/DECERR) → `D.corrupt` |

No `RID`, no `RLAST` — single-beat by definition.

## Opcode mapping

| TL A opcode | AXI traffic | D response | Notes |
|-------------|-------------|------------|-------|
| `Get` (4) | `AR` + `R` | `AccessAckData` | Single beat; size ≤ `log2(beatBytes)` |
| `PutFullData` (0) | `AW` + `W` (parallel) + `B` | `AccessAck` | Full mask expected from master |
| `PutPartialData` (1) | `AW` + `W` (`mask` → `WSTRB`) + `B` | `AccessAck` | Any mask subset OK |
| `Hint` (5) | *(none — handled in-bridge)* | `HintAck` | 1-deep slot, no AXI activity |
| `ArithmeticData` (2) / `LogicalData` (3) | *(none)* | `AccessAck`, `denied=1` | Unsupported in TL-UL; consumed by the local-error slot |
| oversized (size > `log2(beatBytes)`) | *(none)* | `AccessAck`, `denied=1` | Routed to local-error slot regardless of opcode |
| reserved opcodes (6, 7) | *(none)* | `AccessAck`, `denied=1` | Local-error slot |

`TLOpcode` constants are reused from
`src/main/scala/tlbridge/Bundles.scala` (the same TL spec opcodes the
TL-UH bridge uses).

## Sub-bus access and alignment

The bridge always aligns `AW`/`AR` addresses to `beatBytes` — the low
`beatSizeLg` bits are masked off in
`alignAddr`.  Sub-bus transfers (`a.size < log2(beatBytes)`) ride a
single beat with `WSTRB` selecting the active bytes on writes.  On
reads, the master is expected to extract the active bytes from the
returned beat (the bridge does not zero unselected lanes).

For `dataBits = 32` (default), legal sizes are 0 (byte), 1 (half-word),
and 2 (word).  For `dataBits = 64`, add 3 (double-word).  Anything
larger is a local-error.

## State machine

Three independent engines share TL-A by opcode and TL-D via a
fixed-priority arbiter.  Engine state registers are declared near
[the top of `TLULToAXILite.scala`](../src/main/scala/tlbridge/TLULToAXILite.scala);
the FSM is intentionally simpler than the TL-UH bridge's (no bursts, no
atomics, no read-burst lock).

### Read engine — 3 states

```
                                    AR fire        d.fire AccessAckData
   sRIdle --(a.fire isGet)--> sRAR ---------> sRResp -----------------+
       ^                                                              |
       +------------------------- sRIdle on D.fire -------------------+
```

### Write engine — 3 states with parallel AW/W

```
                                          (awDone & wDone)     d.fire AccessAck
   sWIdle --(a.fire isPut)--> sWReq ---------------------> sWResp ---------+
       ^                       |    AW.fire latches awDone                  |
       |                       |    W.fire  latches wDone                   |
       +--------------------- sWIdle on D.fire ------------------------------+
```

The bridge raises `aw.valid` and `w.valid` together on entry to `sWReq`
and stays there until both `awDone` and `wDone` are true.  Either
handshake may fire first; the slave is free to accept them in any
order (AXI4-Lite §B1.1).

### Hint slot — 1-bit pending flag

```
   !hPending --(a.fire isHint)--> hPending=1 ----d.fire HintAck----> hPending=0
```

### Local-error slot — 1-bit pending flag

Unsupported opcode or oversized request: on `a.fire` the bridge captures
source/size and raises `eState = 1`.  The D arbiter emits a denied
`AccessAck` carrying that source/size when no higher-priority engine is
contending.  Unlike the TL-UH bridge's error slot, **no burst-drain
state is needed** — TL-UL has no bursts.

### D-channel arbiter

Five sources may be valid simultaneously: write (`B` + `sWResp`), read
(`R` + `sRResp`), hint pending, local-error pending.  Fixed priority
**`W > R > H > E`**.  No sticky burst lock — every D response is a single
beat.

Disambiguation: the bridge ties
`io_axi_b_ready := tl.d.ready` only in the `dSelW` branch, and
`io_axi_r_ready := tl.d.ready` only in `dSelR`.  Both defaults are zero
elsewhere, so the AXI ready signals identify which engine the arbiter
selected on any given D beat — this is the disambiguator the formal
wrapper uses to distinguish a denied write (`BRESP != OKAY`) from a
local-error denied response.

## Limitations

- **Single beat per transaction.**  TL-UL itself doesn't define bursts.
  `a.size > log2(beatBytes)` is consumed by the local-error slot.
- **No atomics.**  `ArithmeticData` and `LogicalData` route to local-error.
  Use the TL-UH bridge if your design needs atomics.
- **One outstanding transaction per engine.**  Two reads cannot be in
  flight at the same time, and two writes cannot.  A read + a write + a
  hint *can*.  Multi-source-per-engine parallelism is not supported
  (and is not interesting for control-plane peripherals).
- **AXI4-Lite sideband signals.**  Only `AxPROT` (tied 0) and `?RESP`
  are driven/consumed.  AXI4-Lite does not require `AxLOCK`, `AxCACHE`,
  etc.  A downstream subordinate that demands those will need a wrapper.
- **Error mapping.**  `RRESP ≠ OKAY` raises `D.denied`; only
  `SLVERR`/`DECERR` (resp bit 1 set) raises `D.corrupt`.  `BRESP ≠ OKAY`
  raises `D.denied` only.
- **Source field stays on the TL side.**  AXI4-Lite has no `BID`/`RID`,
  so the bridge holds `a_source` in a local register per engine instead
  of forwarding it through AXI.

## Verification overview

| Layer | Target | Coverage |
|-------|--------|----------|
| Lint | `make lint-ulite` | Verilator `--lint-only -Wall`, 0 warnings |
| C++ TB | `make sim-ulite` | 24 directed jobs — aligned put/get, every byte lane, half-word at both halves, partial mask, hint, three-engine concurrency, AXI SLVERR + DECERR injection, unsupported opcode (`ArithmeticData`), oversized request (`size=3` at `dataBits=32`).  **PASS** at 0 errors, peak concurrency = 3 |
| cocotb | `make cocotb-ulite` | 5 directed tests on Icarus — aligned put/get, byte lanes, half-word, partial put, hint |
| Formal | `make formal-ulite` | SymbiYosys BMC depth 20 + 4 cover witnesses — per-engine F2/F3 (source/size preservation), F-UL-1 (AW/AR alignment), no-corrupt on AccessAck/HintAck, C1–C4 (write/read/hint/local-error completion) |

The C++ TB models a behavioral AXI4-Lite slave that accepts AW and W in
either order (including simultaneously) and injects `RRESP=SLVERR` at
address `0xD00` and `BRESP=DECERR` at `0xD80`.  The cocotb env mirrors the
same model.

See [`doc/ASSERTIONS.md`](ASSERTIONS.md) for the full property catalog —
the TL-UL → AXI4-Lite properties are listed in its dedicated section.
