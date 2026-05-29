# TL-C Evaluation — why this bridge stays on TileLink-UH

**As of:** 2026-05-27 (original); reopened 2026-05-28
**Decision:** stay on TL-UH for the AXI4 bridges; **separately**, a
sibling TL-C → CHI bridge has been planned — see
[`CHI_PLAN.md`](CHI_PLAN.md).

> **Status update (2026-05-28).**  The "stay on TL-UH" verdict is still
> correct *for the AXI4 path* — see the "Why AXI4 makes TL-C
> semantically unhelpful here" section below; nothing about AXI4 has
> changed.  A separate decision was made to add a **third sibling
> bridge** translating TL-C → CHI, where coherence semantics map
> naturally to the downstream protocol.  The TL-C → CHI work does not
> change the AXI4 bridges, which remain on TL-UH; it adds a new
> coherent path alongside them.  See [`CHI_PLAN.md`](CHI_PLAN.md) for
> the staged roadmap.

This memo exists so future readers do not have to re-litigate the
question.  The decision is reversible if the downstream world changes,
but the reasoning is stable.

---

## What TL-C would add

TileLink has three conformance levels:

| Level | Channels | Added semantics |
|---|---|---|
| TL-UL | A, D       | Uncached, single-beat — what `TLULToAXILite` speaks (`doc/DESIGN_SPEC_ULITE.md`). |
| TL-UH | A, D       | Uncached, bursts + atomics + hints — what `TLUHToAXI4` speaks. |
| TL-C  | A, B, C, D, E | Coherent: probes, permissions, dirty writebacks. |

Moving to TL-C is not "TL-UH plus a few opcodes" — it is a separate
protocol with five channels.  The added machinery is:

- **B channel** (probe from manager → client): the host asks a client
  whether it holds a cache line and what permission.
- **C channel** (release/probe-ack from client → manager): the client
  voluntarily writes a dirty line back or responds to a probe.
- **E channel** (grant-ack from client → manager): the client
  acknowledges a permission grant.
- **A/D extensions**: `Acquire` / `Grant` / `Release` opcodes with
  permission encodings (NtoB, NtoT, BtoT, TtoB, TtoN…).

A bridge from TL-C to AXI would need to terminate the coherence
protocol: maintain a directory or some form of in-bridge cache state,
generate probes back to upstream clients, accept dirty writebacks,
and present a coherent illusion to the AXI subordinate which has none.

---

## Why AXI4 makes TL-C semantically unhelpful here

AXI4 has no coherence primitives.  It has the `AxCACHE` and `AxPROT`
hints, which describe **expected** caching behaviour to the
interconnect, but nothing the slave can use to participate in a
coherence protocol.  AXI's `AxLOCK` exclusive access (which this bridge
uses for atomics) is a single-master synchronization primitive — not a
multi-master coherence primitive.

The closest standard that adds coherence on top of AXI is **ACE / ACE-Lite**
(AXI Coherency Extensions).  ACE *does* carry probe-like traffic, and a
TL-C → ACE bridge is the structurally honest path if multi-master
coherence is the real requirement.  A TL-C → plain AXI4 bridge would
either:

1. Pretend the AXI subordinate is fully coherent (i.e., snoop every
   read) — incurring full probe traffic for every transaction even
   though the slave never participates.  This is a perf cliff with no
   semantic gain over TL-UH.
2. Terminate coherence in the bridge with an internal directory cache.
   This makes the bridge itself the coherence point, which is a
   reasonable design for a memory controller but is a different IP
   block than what this repo is.

Neither option is "implement TL-C in this bridge"; both are major
new components that happen to speak TL-C on the upstream side.

---

## What workloads would push toward this

The bridge would need to be re-evaluated if:

- The host upgrades to a coherent fabric (e.g., Rocket Tile-based
  designs with shared L2 caches) and our memory subsystem becomes the
  shared point of consistency.
- A second master joins the AXI side that must observe writes from
  this bridge under coherence guarantees stronger than what
  `AxLOCK`/exclusive provides.
- A consumer downstream of the AXI port needs probe-style invalidation
  delivered back to the TL host (e.g., a DMA engine evicting a host
  cache line).

None of these are on the current roadmap.

---

## What we keep instead

Within TL-UH the bridge already supports:

- `Get` / `PutFullData` / `PutPartialData` with bursts up to 64 B
- `Hint` (handled in-bridge, no AXI traffic)
- `ArithmeticData` / `LogicalData` via AXI exclusive access
  (`AxLOCK=1`) — single-master atomicity, sufficient for synchronization
  primitives in a single-host system
- Source-as-AXI-ID forwarding, enabling four engines in flight
  concurrently (read + write + atomic + hint)

This covers the spectrum of "uncached host talks to memory-mapped
peripherals via AXI" without requiring a coherence point inside the
bridge.

---

## When to revisit

Concretely, re-open this decision when ANY of the following becomes
true:

- A consumer of this bridge requests probe-based invalidation
- The host SoC adopts a coherent interconnect AND this bridge becomes
  load-bearing for that coherence
- The AXI side migrates to ACE / ACE-Lite

Until then, the TL-UH bridge is the right shape.  The atomic engine
already covers the synchronization use cases that come up in single-host
designs.

---

## Reopen log

- **2026-05-28** — added [`CHI_PLAN.md`](CHI_PLAN.md), a separate
  staged plan for a TL-C → CHI bridge sibling.  The AXI4 bridges remain
  on TL-UH; the CHI bridge addresses the third "consumer requests
  probe-based invalidation / host adopts coherent interconnect" trigger
  by routing coherent traffic to a coherent downstream protocol instead
  of trying to bolt coherence onto AXI4.
