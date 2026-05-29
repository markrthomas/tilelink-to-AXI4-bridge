# TileLink-UC → AXI4 Bridge — Design Specification

This document defines the contract of the `TLUCToAXI4` bridge: signal
interfaces, opcode mapping, FSM behavior, and the intentional
restrictions of the "TL-C wire shape without coherence" model.  The
Chisel source (`src/main/scala/tlbridge/TLUCToAXI4.scala`) is the
implementation; this spec is the reference behavior.

The sibling [`DESIGN_SPEC.md`](DESIGN_SPEC.md) covers the TL-UH bridge
this one extends from, and [`DESIGN_SPEC_ULITE.md`](DESIGN_SPEC_ULITE.md)
covers the AXI4-Lite variant.

## What "TL-UC" means here

TL-UC is not a name from the TileLink spec — it's the convention used in
this repo for **TL-C channel shape with no coherence**.  The bridge:

- exposes all five TL-C channels (A + B + C + D + E),
- accepts TL-C cached opcodes (`AcquireBlock`, `AcquirePerm`,
  `Release`, `ReleaseData`) **alongside** the full TL-UH opcode set
  (`Get`, `Put*`, `Hint`, `ArithmeticData`, `LogicalData`),
- **never issues a Probe** on TL-B (channel is tied off),
- **always grants Tip** on Acquire (`D.param = toT`) because there are
  no other sharers to invalidate,
- maps Acquire to an AXI4 read, AcquirePerm to a permission-only Grant
  (no AXI traffic), Release to a no-data `ReleaseAck`, and ReleaseData
  to an AXI4 write followed by `ReleaseAck`,
- requires the upstream master to send a matching `GrantAck` on TL-E
  after each `Grant`/`GrantData` to release the engine slot.

This is useful when an upstream master only speaks TL-C (because it
*is* a cached agent) but coherence is unnecessary — e.g., it's the only
cached master, or coherence is managed externally.  It is also the
natural stepping stone for the TL-C → CHI bridge planned in
[`CHI_PLAN.md`](CHI_PLAN.md): the channel plumbing and the
Acquire/Grant/GrantAck flow are exactly what that bridge's Stage 1
needs, just landing in a simpler downstream protocol first.

## Overview

```
+---------+  A (req)    +-----------------+  AW/W/AR    +-------------+
|  TL-C   | ----------> |                 | ----------> |             |
|  HOST   |  B (probe)  |   TLUCToAXI4    |  B/R        | AXI4 MEMORY |
| (Mgr.)  | <---------- |     (this)      | <---------- | SUBORDINATE |
|         |  C (release)|                 |             |             |
|         | ----------> |                 |             |             |
|         |  D (resp)   |                 |             |             |
|         | <---------- |                 |             |             |
|         |  E (gak)    |                 |             |             |
|         | ----------> |                 |             |             |
+---------+             +-----------------+ <---------> +-------------+
```

The bridge runs **six** parallel engines:

| Engine | TL channels | Inputs | Output |
|---|---|---|---|
| Read    | A, D       | `Get` | `AccessAckData` (multi-beat) |
| Write   | A, D       | `Put*` | `AccessAck` |
| Hint    | A, D       | `Hint` | `HintAck` |
| Atomic  | A, D       | `ArithmeticData` / `LogicalData` | `AccessAckData` (OLD value) |
| Acquire | A, D, E    | `AcquireBlock` / `AcquirePerm` | `GrantData` (multi-beat) / `Grant` |
| Release | C, D       | `Release` / `ReleaseData` | `ReleaseAck` |

Plus a 1-deep local-error slot for unsupported opcodes / oversized
requests.  Each engine has a single outstanding slot.  Multiple engines
can be in flight simultaneously (peak observed concurrency in the
directed TB is **3**).  The TL-D arbiter has priority
**`W > R > Atom > Acq > Rel > Hint > Err`** with a sticky burst lock for
multi-beat `AccessAckData` / `GrantData` responses.

## Parameters

Reuses `BridgeParams` from the TL-UH bridge —
defaults `addrBits=32`, `dataBits=64`, `sourceBits=4`, `sizeBits=6`.
The bridge is emitted to `generated/uc/TLUCToAXI4.sv`.

## TileLink-C interface

### Channel A (host → bridge) — same as TL-UH, extended opcodes

| Signal | Width | Dir (slave) | Meaning |
|---|---|---|---|
| `io_tl_a_valid` / `_ready` | 1 / 1 | in/out | A handshake |
| `io_tl_a_bits_opcode` | 3 | in | 0=PutFull, 1=PutPartial, 2=Arith, 3=Logical, 4=Get, 5=Hint, **6=AcquireBlock, 7=AcquirePerm** |
| `io_tl_a_bits_param` | 3 | in | Acquire cap: 0=NtoB, 1=NtoT, 2=BtoT.  Atomic: ALU op selector.  Ignored otherwise |
| `io_tl_a_bits_size` | 6 | in | `log2(transaction bytes)` |
| `io_tl_a_bits_source` | 4 | in | Master-supplied transaction ID |
| `io_tl_a_bits_address` | 32 | in | Byte address |
| `io_tl_a_bits_mask` | 8 | in | Active bytes (Put*) |
| `io_tl_a_bits_data` | 64 | in | Write data per beat |
| `io_tl_a_bits_corrupt` | 1 | in | Ignored |

### Channel B (bridge → host) — tied off

The bridge sets `io_tl_b_valid := 0` permanently and zeroes all
`io_tl_b_bits_*` outputs.  TL-B exists for protocol-shape parity with
TL-C masters but is never used because the bridge issues no probes.

### Channel C (host → bridge) — Release / ReleaseData

| Signal | Width | Dir (slave) | Meaning |
|---|---|---|---|
| `io_tl_c_valid` / `_ready` | 1 / 1 | in/out | C handshake |
| `io_tl_c_bits_opcode` | 3 | in | **6=Release, 7=ReleaseData**.  ProbeAck (4) / ProbeAckData (5) should never arrive (no probes) |
| `io_tl_c_bits_param` | 3 | in | Permission shrink: 0=TtoB, 1=TtoN, 2=BtoN |
| `io_tl_c_bits_size` | 6 | in | Same envelope as A |
| `io_tl_c_bits_source` | 4 | in | Master-supplied transaction ID |
| `io_tl_c_bits_address` | 32 | in | Byte address (cache-line aligned for ReleaseData) |
| `io_tl_c_bits_data` | 64 | in | Per-beat writeback data (ReleaseData only) |
| `io_tl_c_bits_corrupt` | 1 | in | Ignored |

### Channel D (bridge → host) — extended opcodes

| Signal | Width | Dir (slave) | Meaning |
|---|---|---|---|
| `io_tl_d_valid` / `_ready` | 1 / 1 | out/in | D handshake |
| `io_tl_d_bits_opcode` | 3 | out | 0=AccessAck, 1=AccessAckData, 2=HintAck, **4=Grant, 5=GrantData, 6=ReleaseAck** |
| `io_tl_d_bits_param` | 3 | out | Grant cap: 0=toT (bridge always grants toT) |
| `io_tl_d_bits_size` | 6 | out | Echoes the request size |
| `io_tl_d_bits_source` | 4 | out | Echoes the request source |
| `io_tl_d_bits_sink` | 1 | out | Acquire-engine sink tag — tied to 0 (single slot); echoed back on E |
| `io_tl_d_bits_denied` | 1 | out | Lifted on AXI `?RESP != OKAY` (Get/AcquireBlock paths) |
| `io_tl_d_bits_data` | 64 | out | Beat payload for `AccessAckData` / `GrantData` |
| `io_tl_d_bits_corrupt` | 1 | out | Lifted on `RRESP[1]` set (SLVERR/DECERR) |

### Channel E (host → bridge) — GrantAck

| Signal | Width | Dir (slave) | Meaning |
|---|---|---|---|
| `io_tl_e_valid` / `_ready` | 1 / 1 | in/out | E handshake — bridge `ready` is high only while the Acquire engine is in its `sAcqAck` waiting state |
| `io_tl_e_bits_sink` | 1 | in | Must echo the sink the bridge sent on D (0 for single slot) |

## AXI4 interface

Identical to the TL-UH bridge — same `AxiMasterIO` bundle, same
INCR-only bursts, same `AxSIZE = log2(beatBytes) = 3` pinning,
sub-bus writes ride a full beat with `WSTRB`.  See
[`DESIGN_SPEC.md#axi4-interface`](DESIGN_SPEC.md#axi4-interface) for
the signal-by-signal tables.

The Acquire engine emits `AR` with `id = a_source` and
`lock = 0` (atomic is the only engine that asserts `AxLOCK`).
The Release engine emits `AW` and `W` with `id = c_source` and
`WSTRB` all-ones (ReleaseData writes back full cache-line bytes).

## Opcode mapping

| TL A opcode | AXI traffic | D response | Notes |
|---|---|---|---|
| `Get` (4) | AR + R | `AccessAckData` | TL-UH carry-over |
| `PutFullData` (0) | AW + W | `AccessAck` | TL-UH carry-over |
| `PutPartialData` (1) | AW + W (`mask`→`WSTRB`) | `AccessAck` | TL-UH carry-over |
| `Hint` (5) | none | `HintAck` | TL-UH carry-over |
| `ArithmeticData` (2) / `LogicalData` (3) | AR(lock=1) + R + AW(lock=1) + W | `AccessAckData` (OLD) | TL-UH carry-over |
| `AcquireBlock` (6) | AR + R | `GrantData(toT)` | New.  Multi-beat for cache-line reads |
| `AcquirePerm` (7) | *(none)* | `Grant(toT)` | New.  Permission upgrade, no data |

| TL C opcode | AXI traffic | D response |
|---|---|---|
| `Release` (6) | *(none)* | `ReleaseAck` |
| `ReleaseData` (7) | AW + W (full mask) | `ReleaseAck` |

The bridge always returns `D.param = toT` on Acquire regardless of what
the master requested (NtoB / NtoT / BtoT).  This is permissible per the
TL-C spec — granting more permission than asked is fine; the master can
treat the line as Tip.  No coherence implications because there are no
other sharers in the system.

## State machines

### Acquire engine — 4 states

```
                  AcquireBlock fire (a.fire,isAcqBlock)
   sAcqIdle ----------------------------------------> sAcqAR
       ^   \                                              |
       |    \  AcquirePerm fire (a.fire,isAcqPerm)        | AR fire
       |     +-------------------> sAcqResp <-------------+
       |                              |
       |                              | D.fire (Grant) for AcqPerm
       |                              | OR last r.fire+D.fire (GrantData) for AcqBlock
       |                              v
       +------------- e.fire ----- sAcqAck
                     (GrantAck)
```

### Release engine — 5 states

```
                                  Release C.fire (peek+fire)
   sRelIdle --------------------------------------------> sRelAck
       |
       | ReleaseData C.valid (peek-don't-fire)
       v
   sRelAW
       | AW fire
       v
   sRelData --(per-beat C.fire+W.fire)--> sRelBresp
                                              | B.fire
                                              v
                                          sRelAck --> sRelIdle on D.fire
```

ReleaseData uses the same "peek-don't-fire" pattern as the Write engine
for Put bursts: the bridge captures `source`/`size`/`address` from the
first C beat without asserting `c.ready`, then drives AW.  Once AW
fires, the engine enters `sRelData` and accepts C beats in lock-step
with AXI W beats.

### B-channel — tied off

`io.tl.b.valid := false`, all `io.tl.b.bits_*` zero.  Probes are never
issued.

### D-channel arbiter

Priority **`W > R > Atom > Acq > Rel > Hint > Err`** with a sticky
burst lock that engages on the first non-last beat of an
`AccessAckData` or `GrantData` burst and releases on the last beat.

The lock is shared between `Read` (AccessAckData) and `Acquire`
(GrantData) because at most one multi-beat burst can be in flight at a
time — if both engines are pending with distinct sources, the AXI side
demuxes R by id and only one is driving D at any cycle.

## Limitations

- **One outstanding per engine.**  Two Acquires cannot be in flight
  simultaneously; ditto Releases.
- **No probes.**  `Probe` is never issued on B; the bridge can never
  invalidate a cached copy at the master.  A multi-master setup would
  need a coherence-aware bridge (see [`CHI_PLAN.md`](CHI_PLAN.md)).
- **Always grants toT.**  No way to convey "shared" — only the upstream
  master could downgrade voluntarily via `Release`.
- **`ProbeAck` / `ProbeAckData` on C are not expected.**  A
  well-behaved master never sends them because the bridge never sent a
  matching `Probe`.  The bridge consumes them but produces no D —
  treat their arrival as integration error.
- **Sink width = 1.**  Single-slot Acquire engine; `D.sink = 0` always,
  `E.bits.sink` must be 0.
- **AXI4 limitations** carry over from the TL-UH bridge — INCR only,
  sub-bus reads return full beats.  See
  [`DESIGN_SPEC.md#limitations`](DESIGN_SPEC.md#limitations).

## Verification overview

| Layer | Target | Coverage |
|-------|--------|----------|
| Lint | `make lint-uc` | Verilator `--lint-only -Wall`, 0 warnings |
| C++ TB | `make sim-uc` | 11 directed jobs — AcquireBlock(NtoT/NtoB) full cache line, AcquirePerm(NtoT), Release(TtoN), ReleaseData(TtoN), TL-UH Put+Get+Hint carry-over, AXI read-error injection on AcquireBlock |
| cocotb | `make cocotb-uc` | 6 directed tests on Icarus — covers each new D opcode plus the carry-over path |
| Formal | `make formal-uc` | SymbiYosys BMC depth 30 + 5 cover witnesses — F-UC-1 (B tied off), F-UC-2 (GrantData source/param), F-UC-3 (Grant source/param), F-UC-4 (ReleaseAck source/size), F-UC-5 (AcquireBlock AR alignment + no lock), bonus (no corrupt/denied on ReleaseAck/Grant) |

The C++ TB models the bridge slave on the AXI side as the same
behavioral memory used by the TL-UH TB — same `0xD00` (RRESP=SLVERR) and
`0xD80` (BRESP=DECERR) error-injection addresses.  See
[`doc/ASSERTIONS.md`](ASSERTIONS.md) §8 for the full property catalog.
