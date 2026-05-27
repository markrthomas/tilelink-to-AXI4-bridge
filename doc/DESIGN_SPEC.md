# TileLink-UH → AXI4 Bridge — Design Specification

This document defines the contract of the `TLUHToAXI4` bridge: signal
interfaces, opcode mapping, burst arithmetic, FSM behavior, and the set
of intentional restrictions. The Chisel source
(`src/main/scala/tlbridge/`) is the implementation; this spec is the
reference behavior. Where they disagree, this document wins and the
source must be brought into line.

## Overview

```
+---------+   Channel A   +---------------+    AW / W   +-------------+
|   TL    | ------------> |               | ----------> |             |
|  HOST   |               |  TLUHToAXI4   |     B       | AXI4 MEMORY |
| (Mgr.)  | <------------ |    (this)     | <---------- | SUBORDINATE |
|         |   Channel D   |               |    AR / R   |             |
+---------+               +---------------+ <---------> +-------------+
```

The bridge is a TileLink **slave** (it sinks `A`, sources `D`) and an AXI4
**master** (it sources `AW`/`W`/`AR`, sinks `B`/`R`). It serialises one
TL transaction at a time end-to-end; reads and writes do not overlap inside
the bridge even though TL would allow it via distinct `source` values.

## Parameters

All parameters live in `BridgeParams`
(`src/main/scala/tlbridge/Bundles.scala:6`). Default values match the
elaborated SV and the testbench:

| Parameter | Default | Derived | Notes |
|-----------|---------|---------|-------|
| `addrBits` | 32 | — | TL `a_address` / AXI `Ax_addr` width |
| `dataBits` | 64 | `beatBytes = 8`, `strbBits = 8`, `beatSizeLg = 3` | Must be a power of two, ≥ 8 |
| `sourceBits` | 4 | `idBits = sourceBits` | TL `a_source` / AXI `Ax_id` width |
| `sizeBits` | 6 | — | log2 of max single-transaction bytes (64 B with default) |
| `lenBits` | 8 | — | AXI `Ax_len` width (AXI4 fixed at 8) |
| `respBits` | 2 | — | AXI `?resp` width |

Generation uses `circt.stage.ChiselStage` via
`src/main/scala/tlbridge/Main.scala` and emits to `generated/`.

## TileLink-UH interface

Two channels are exposed (`TLSlaveIO`,
`src/main/scala/tlbridge/Bundles.scala:54`). Names below match the
elaborated ports in `generated/TLUHToAXI4.sv:5-24`.

### Channel A (host → bridge)

| Signal | Width | Dir (slave) | Meaning |
|--------|-------|-------------|---------|
| `io_tl_a_valid` | 1 | in | A-beat available |
| `io_tl_a_ready` | 1 | out | Bridge accepts the current A-beat |
| `io_tl_a_bits_opcode` | 3 | in | `Get`=4, `PutFullData`=0, `PutPartialData`=1, `Hint`=5 |
| `io_tl_a_bits_param` | 3 | in | Ignored (zero for the supported opcodes) |
| `io_tl_a_bits_size` | 6 | in | `log2(total transaction bytes)` |
| `io_tl_a_bits_source` | 4 | in | Master-supplied transaction ID |
| `io_tl_a_bits_address` | 32 | in | Byte address of the transaction |
| `io_tl_a_bits_mask` | 8 | in | Active-bytes mask (per beat) |
| `io_tl_a_bits_data` | 64 | in | Write data (writes), ignored on reads/hints |
| `io_tl_a_bits_corrupt` | 1 | in | Ignored — bridge does not propagate corrupt-in |

### Channel D (bridge → host)

| Signal | Width | Dir (slave) | Meaning |
|--------|-------|-------------|---------|
| `io_tl_d_valid` | 1 | out | D-beat available |
| `io_tl_d_ready` | 1 | in | Master accepts the current D-beat |
| `io_tl_d_bits_opcode` | 3 | out | `AccessAck`=0, `AccessAckData`=1, `HintAck`=2 |
| `io_tl_d_bits_param` | 3 | out | Tied to 0 |
| `io_tl_d_bits_size` | 6 | out | Echoes the request `a_size` |
| `io_tl_d_bits_source` | 4 | out | Echoes the request `a_source` |
| `io_tl_d_bits_sink` | 1 | out | Tied to 0 (single-sink bridge) |
| `io_tl_d_bits_denied` | 1 | out | `AXI ?RESP != OKAY` lifts this bit |
| `io_tl_d_bits_data` | 64 | out | Beat payload for `AccessAckData` |
| `io_tl_d_bits_corrupt` | 1 | out | Set on read paths when `RRESP != OKAY` |

Channel B (probe) and Channel C (release) of the full TL specification are
**not** present — this is a TL-UH bridge.

## AXI4 interface

Five channels (`AxiMasterIO`,
`src/main/scala/tlbridge/Bundles.scala:88`). Names below match
`generated/TLUHToAXI4.sv:25-54`.

### Write address (`AW`)

| Signal | Width | Notes |
|--------|-------|-------|
| `io_axi_aw_valid` / `_ready` | 1 / 1 | Standard handshake |
| `io_axi_aw_bits_id` | 4 | = request `a_source` |
| `io_axi_aw_bits_addr` | 32 | = `a_address` with low `beatSizeLg` bits cleared (bus-aligned per AXI4 spec for `AxSIZE = log2(beatBytes)` INCR bursts). Sub-beat positioning rides on `WSTRB`. |
| `io_axi_aw_bits_len` | 8 | `beats − 1` (see *Burst calculation*) |
| `io_axi_aw_bits_size` | 3 | **Tied to 3** (`log2(beatBytes)`) |
| `io_axi_aw_bits_burst` | 2 | **Tied to `INCR`** (`2'b01`) |

Not modeled: `AWLOCK`, `AWCACHE`, `AWPROT`, `AWQOS`, `AWREGION`. Add them
as tied-zero outputs if the downstream subordinate requires them.

### Write data (`W`)

| Signal | Width | Notes |
|--------|-------|-------|
| `io_axi_w_valid` / `_ready` | 1 / 1 | Coupled to `A` handshake in the data state |
| `io_axi_w_bits_data` | 64 | = TL `a_data` of the current beat |
| `io_axi_w_bits_strb` | 8 | = TL `a_mask` of the current beat |
| `io_axi_w_bits_last` | 1 | Asserted on the final beat of the burst |

### Write response (`B`)

| Signal | Width | Notes |
|--------|-------|-------|
| `io_axi_b_valid` / `_ready` | 1 / 1 | Coupled to `D` handshake while in `sWriteResp` |
| `io_axi_b_bits_id` | 4 | Echoed back as `D.source` |
| `io_axi_b_bits_resp` | 2 | Non-zero → `D.denied` |

### Read address (`AR`)

Same fields as `AW` with identical semantics (id = source, addr bus-aligned,
`len = beats − 1`, `size = 3`, `burst = INCR`). For sub-bus reads the TL
master recovers byte position from its own `a_address[beatSizeLg-1:0]`.

### Read data (`R`)

| Signal | Width | Notes |
|--------|-------|-------|
| `io_axi_r_valid` / `_ready` | 1 / 1 | Forwarded beat-for-beat to `D` |
| `io_axi_r_bits_id` | 4 | Not forwarded; bridge uses latched `source` instead |
| `io_axi_r_bits_data` | 64 | = `D.data` |
| `io_axi_r_bits_resp` | 2 | Non-zero → `D.denied`; bit 1 set (`SLVERR`/`DECERR`) → `D.corrupt` (so `EXOKAY` only raises `denied`) |
| `io_axi_r_bits_last` | 1 | Marks the final read beat (bridge returns to `sIdle`) |

## Opcode mapping

| TL A opcode | AXI traffic | D response | Notes |
|-------------|-------------|------------|-------|
| `Get` (4) | `AR` + `R` | `AccessAckData` | Read; bridge passes R beats to D unchanged |
| `PutFullData` (0) | `AW` + `W` | `AccessAck` | Full mask expected from master |
| `PutPartialData` (1) | `AW` + `W` (`mask → WSTRB`) | `AccessAck` | Any mask subset OK |
| `Hint` (5) | *(none)* | `HintAck` | Bridge handles locally; no AXI activity |
| `ArithmeticData` (2) | *(none)* | — | **Unsupported.** Master must not issue. |
| `LogicalData` (3) | *(none)* | — | **Unsupported.** Master must not issue. |

The string constants are defined in `TLOpcode`
(`src/main/scala/tlbridge/Bundles.scala:96`) and applied by the FSM
in `src/main/scala/tlbridge/TLUHToAXI4.scala:79-91` (opcode decode in
`sIdle`).

## Burst calculation

```
totalBytes = 1 << a_size
beats      = max(1, totalBytes / beatBytes)
AxLEN      = beats - 1                       // (sent on both AW and AR)
AxSIZE     = log2(beatBytes) = 3             // tied, see above
AxBURST    = INCR                            // 2'b01
```

Implementation: `aBytes` / `aBeats` in
`src/main/scala/tlbridge/TLUHToAXI4.scala:40-41`.

Sub-bus transfers (`a_size < log2(beatBytes)`) collapse to a single beat
with `AxLEN = 0`. Selected bytes are conveyed through `WSTRB` on writes;
on reads, the master is expected to disregard non-selected bytes (the
bridge does not zero them).

## State machine

The bridge is split into three independent engines that share TL-A by
opcode and TL-D via a fixed-priority arbiter.  All three may have one
transaction in flight simultaneously (peak observed concurrency = 3 in
the regression workload).  Engine state registers are declared at
`src/main/scala/tlbridge/TLUHToAXI4.scala:53-79`.

### Read engine — 3 states

```
                                    AR fire           r_fire && r.last
   sRIdle --(a.fire isGet)--> sRAR ---------> sRResp -----------------+
       ^                                                              |
       +------------------------- sIdle on last R --------------------+
```

### Write engine — 4 states

```
                              AW fire           w.fire & last         d.fire
   sWIdle --(a.valid Put, peek)--> sWAW ------> sWData -----------> sWResp --+
       ^                                                                     |
       +----------------------- sIdle on AccessAck D --------------------- --+
```

### Hint slot — single-bit pending flag

```
   !hPending --(a.fire isHint)--> hPending=1 ----d.fire HintAck----> hPending=0
```

### D-channel arbiter

Three sources may be valid simultaneously: AXI `B` (write resp), AXI `R`
(read resp), `hPending` (hint).  Fixed priority `W > R > H`, but a
sticky `rBurstLock` flag locks the arbiter to R between the first
non-last R beat and the last R beat so a multi-beat `AccessAckData`
burst is never interrupted by a subsequently-arriving B or hint.

### Notes on the transitions

- **`sWIdle` peek-don't-fire.** TL guarantees the master holds an A-beat
  valid until handshake. The bridge samples `opcode`/`size`/`address`/
  `source` from a valid A-beat *without asserting `a_ready`* and
  transitions to `sWAW`. The first write beat is therefore consumed
  later in `sWData`, not in `sWIdle`, so its `data`/`mask` are not lost.
  See `isGet`/`isHint`/`isPut` decoding in
  `src/main/scala/tlbridge/TLUHToAXI4.scala:37-44`.
- **`sRIdle` for `Get`.** A single A-beat carries the entire request;
  `a_ready` is asserted in `sRIdle` (gated by `rState === sRIdle`) and
  the beat fires immediately.
- **Hint slot.** A `Hint` fires `a` immediately when `!hPending`, the
  context is captured, and the response is emitted by the D arbiter
  whenever no higher-priority source is competing for D.
- **D-channel pipelining.** Because the read engine and write engine
  use separate context registers (`rSource`/`rSize` vs.
  `wSource`/`wSize`), the two responses can interleave on D —
  but never within an R burst (read-burst lock).

## Limitations

- **One outstanding transaction per engine.** Two reads cannot be
  in flight simultaneously, and two writes cannot.  A read + a write
  + a hint *can*.  Multi-source-per-engine parallelism (e.g. two
  outstanding reads) would need a per-source ID table.
- **No atomics.** `ArithmeticData` / `LogicalData` are not decoded; the
  FSM stays in `sIdle` and the master would hang. Future work
  (`doc/PLAN.md` mid-term) maps these to AXI read-modify-write or
  exclusive accesses.
- **`AxSIZE` tied to bus width.** Sub-bus writes use `WSTRB` to select
  the active bytes. A downstream subordinate that depends on `AxSIZE`
  for narrow-transfer behavior may need a wrapper.
- **No reordering, no interleaving.** R beats arrive in AR order; W
  beats are issued in A order. The bridge does not buffer beats.
- **Error mapping.** `RRESP ≠ OKAY` raises `D.denied`; only `SLVERR`/`DECERR`
  (resp bit 1 set) raises `D.corrupt`. `EXOKAY` does not raise `corrupt`
  because the data is valid. `BRESP ≠ OKAY` raises `D.denied` only —
  writes have no data integrity bit. `DECERR` vs. `SLVERR` are not
  distinguished on the TL side beyond the corrupt/denied split.
- **No AXI side-band signals.** `AWLOCK`, `AWCACHE`, `AWPROT`, `AWQOS`,
  `AWREGION` (and the AR equivalents) are not driven. If the
  subordinate requires them, add tie-zeros at integration.

## Verification overview

The TB in `test/cpp/tb_main.cpp` runs:

| Category | Cases |
|----------|-------|
| Directed: aligned write+read | 64-bit at `0x100` |
| Directed: sub-bus write+read | 32-bit halves at `0x200`, `0x204` |
| Directed: burst (size=5, 4 beats) | `0x400` |
| Directed: burst (size=4, 2 beats) | `0x300` |
| Directed: `PutPartialData` single | strb = `0b00111100` at `0x500` |
| Directed: `PutPartialData` burst | strb = `0xF0`, `0x0F` at `0x600` |
| Directed: `Hint` → `HintAck` | `0x700` |
| Directed: byte (size=0) at unaligned offset | `0x803` |
| Directed: explicit concurrency | 4-beat Put + Get + Hint with distinct sources at `0xA00`/`0xB00`/`0xC00` |
| Randomized | 100 jobs with `std::mt19937(0xC0FFEE)`, rotating sources, op mix Put/Get/Hint incl. `PutPartialData` with random masks |

Self-check: each `D` response is matched to a request via a per-source
FIFO (so out-of-order completion is tolerated); for `Get`, the per-beat
data is compared against a snapshot of the reference model taken at
enqueue time; finally the AXI slave's memory is compared against the
reference.  The TB also live-tracks `outstandingGet + outstandingPut +
outstandingHint` and asserts the peak floor of ≥ 2.  Last recorded
result on `main`:
`*** PASS: 121 jobs, 0 errors, 734 sim ticks, peak concurrency=3 ***`.

A SymbiYosys formal proof at `verification/formal/` covers per-engine
F2 (source preservation), F3 (size preservation), F6 (`AxBURST`/`AxSIZE`),
F8 (`AxADDR` alignment), and the no-corrupt-on-AccessAck/HintAck
discipline — all at BMC depth 30 — plus three cover witnesses (write,
read, hint completion).
