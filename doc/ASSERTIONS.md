# Assertions & Properties — tilelink_to_AXI4

**As of:** 2026-05-28 (added TL-UL → AXI4-Lite variant)

Single catalog of every property used to validate the bridges in this
repo — formal assertions, formal environment assumptions, cover goals,
and scoreboard-level checks in the testbenches.  Cross-reference this
when adding new properties so you don't duplicate, and when triaging a
failure so you can quickly find where a claim is made.

Sections §1–§6 cover the **TL-UH → AXI4 bridge** (`TLUHToAXI4`), which
has four execution engines (read, write, hint, atomic).  Section §7
covers the sibling **TL-UL → AXI4-Lite bridge** (`TLULToAXILite`), which
has three engines (read, write, hint) plus a local-error slot and no
bursts/atomics.

---

## 1. Formal safety assertions (BMC depth 30)

All gated on `chk = f_past_valid && !reset` so they fire only after the
design has seen a full reset pulse.  Defined in
[`verification/formal/tluhtoaxi4_props.sv`](../verification/formal/tluhtoaxi4_props.sv).

| ID | Property | Location | Engines |
|----|----------|----------|---------|
| F2 | `D.source == ghost.xact_source` snapshotted by the corresponding engine when it accepted the transaction | `tluhtoaxi4_props.sv:507-521` | Read, Write, Hint, Atomic |
| F3 | `D.size == ghost.xact_size` snapshotted at admission | `tluhtoaxi4_props.sv:524-535` | Read, Write, Hint, Atomic |
| F6 | `AW.burst == AR.burst == INCR (01)` and `AW.size == AR.size == 3` (log2(beatBytes)) | `tluhtoaxi4_props.sv:404-411` | AXI side |
| F8 | `AW.addr[2:0] == AR.addr[2:0] == 0` (beatBytes alignment) | `tluhtoaxi4_props.sv:414-417` | AXI side |
| F-LOCK | `AW.lock == 1` iff atomic engine is driving AW; `AR.lock == 1` iff atomic engine is driving AR. Structural check that no other engine accidentally raises lock | `tluhtoaxi4_props.sv:540-547` | All |
| —  | `D.corrupt == 0` for `AccessAck` and `HintAck` (corrupt is only meaningful for read data) | `tluhtoaxi4_props.sv:550-552` | Write, Hint |

**Result:** all pass at BMC depth 30 (`make formal`).

**Read-vs-atomic disambiguation.** Both engines produce `D.opcode = AccessAckData`,
so the wrapper distinguishes them by whether AXI R fires concurrently
with D: the read engine ties `r.ready := tl.d.ready` in `dSelR`, so
read's `d_fire` always coincides with `r_fire`; atomic captures R earlier
and emits D from `aOldData`, so atomic's `d_fire` has `r_fire == 0`.

### Deferred properties

These were on the original wishlist and remain open:

| ID | Property | Why deferred |
|----|----------|--------------|
| F1 | Number of AXI bursts conserves with number of TL transactions per engine | Needs counters across the BMC window; the bounded-step proof would be brittle |
| F4 | AXI ID-vs-source consistency under concurrent traffic | Currently enforced by environment assumption rather than asserted — the bridge's source→ID pad is structurally trivial and is captured by F2 |
| F5 | TL response opcode matches request opcode | Implicit in the per-engine F2/F3 assertions (each gated on the matching D opcode), but a stronger D-opcode assertion would be cleaner |
| F7 | WSTRB ⊆ requested mask on each W beat | Requires inspecting the in-flight A mask, not just snapshots — needs per-beat ghost |

Atomic-engine properties: **closed** — see F2/F3/F-LOCK above and C4
below.  The atomic ghost (`a_pending`, `a_xact_source`, `a_xact_size`)
mirrors the read/write/hint pattern.

---

## 2. Formal cover goals (witness must reach)

| ID | Cover goal | Location | Reached |
|----|------------|----------|---------|
| C1 | A write transaction completes (`D = AccessAck`, fire) | `tluhtoaxi4_props.sv:560-561` | step 7 |
| C2 | A read transaction completes (`D = AccessAckData`, fire) | `tluhtoaxi4_props.sv:564-565` | step 6 |
| C3 | A hint transaction completes (`D = HintAck`, fire) | `tluhtoaxi4_props.sv:568-569` | step 5 |
| C4 | An atomic RMW completes (`D = AccessAckData`, no concurrent `r_fire`, source matches atomic ghost) | `tluhtoaxi4_props.sv:573-575` | step 7 |

**Result:** all four witnesses found by `smtbmc` in `make formal`'s
`cover` task.

---

## 3. Formal environment assumptions

These constrain the formal engine's free inputs so it explores only TL/AXI
protocol-compliant traces.  An assumption is **not** verified — it
restricts the state space.  If an assumption is wrong, the safety
assertions may pass spuriously.  Audit this list when an assertion claim
starts feeling suspicious.

### TL master compliance

| ID | Assumption | Location | Rationale |
|----|-----------|----------|-----------|
| TL-A0 | `a.valid == 0` during reset | `tluhtoaxi4_props.sv:175` | Bridge does not accept A before reset deasserted |
| TL-A1 | `a.opcode ∈ {0, 1, 2, 3, 4, 5}` (PutFull, PutPart, Arith, Logic, Get, Hint) | `tluhtoaxi4_props.sv:179-185` | Reserved opcodes (6, 7) illegal per TL spec |
| TL-A2 | `a.size ≤ 6` (max 64 B = beatBytes × maxBurst) | `tluhtoaxi4_props.sv:188-189` | sizeBits=6 envelope |
| TL-A3 | A-channel bits stable while `valid && !ready` (irrevocability) | `tluhtoaxi4_props.sv:192-202` | TL master contract |
| TL-A4 | While inside a Put A burst (`w_in_burst`), `a.opcode/source/size` match the snapshotted burst | `tluhtoaxi4_props.sv:431-435` | Real TL contract — burst beats share a header |
| TL-A5 | Single-outstanding per engine: no new Get/Put/Hint/Atomic while same engine has a pending transaction | `tluhtoaxi4_props.sv:440-447` | Bridge's per-engine slot is 1-deep |
| TL-A6 | Atomic `a.size ≤ 3` (single beat, ≤ beatBytes) | `tluhtoaxi4_props.sv:453-454` | Bridge routes oversized atomics to error slot — keeps the ghost tight |
| TL-A7 | When read+atomic both pending, `r_xact_source != a_xact_source`; same for write+atomic | `tluhtoaxi4_props.sv:460-463` | AXI4 spec: outstanding transactions on the same channel must use unique IDs |

### AXI subordinate compliance

| ID | Assumption | Location | Rationale |
|----|-----------|----------|-----------|
| AXI-B0 | B-channel bits stable while `valid && !ready` | `tluhtoaxi4_props.sv:203-209` | AXI4 §A3.2.2 |
| AXI-R0 | R-channel bits stable while `valid && !ready` | `tluhtoaxi4_props.sv:212-220` | AXI4 §A3.2.2 |
| AXI-B1 | Any B response must match a pending write or atomic engine's source | `tluhtoaxi4_props.sv:469-471` | Slave doesn't fabricate responses; AXI ID uniqueness disambiguates write vs atomic |
| AXI-R1 | Any R response must match a pending read or atomic engine's source | `tluhtoaxi4_props.sv:472-474` | Same as B1 but for the R channel |

---

## 4. Scoreboard-level checks (Verilator C++ TB)

Run in `make sim` / `make regress`.  Defined in
[`test/cpp/tb_main.cpp`](../test/cpp/tb_main.cpp).  Each check is `CHECK(cond, fmt, ...)`
and increments the error counter on failure.

| ID | Check | Location | Scope |
|----|-------|----------|-------|
| TB-S1 | Per-source FIFO ordering: response source must match a pending request from that source | `tb_main.cpp:730-734` | Multi-engine concurrency safety |
| TB-S2 | `resp.size == job.req.size` | `tb_main.cpp:759-760` | Size preservation (sim-level F3) |
| TB-S3 | `resp.denied == job.expectDenied` | `tb_main.cpp:762-764` | Error propagation (AXI RRESP/BRESP, illegal opcode, illegal size) |
| TB-S4 | `resp.corrupt == job.expectCorrupt` | `tb_main.cpp:765-767` | Corrupt bit on read errors |
| TB-S5 | `resp.opcode == job.expectOpcode` | `tb_main.cpp:768-770` | D-opcode matches engine type (sim-level F5) |
| TB-S6 | For AckData responses: beat count and per-beat data match reference memory snapshot | `tb_main.cpp:772-784` | Functional correctness of bridge data path + AXI slave model |
| TB-S7 | Every per-source FIFO empty after run (no orphaned expectations) | `tb_main.cpp:789-794` | Completeness — no lost responses |
| TB-S8 | Peak total in-flight transactions ≥ 2 (assertion that the parallel engines actually overlap) | `tb_main.cpp` peak-concurrency check | Concurrency exercised |
| TB-S9 | Slave memory == reference memory byte-by-byte at end of run | `tb_main.cpp:810+` | Bridge faithfully forwards writes to AXI side |
| TB-AX1 | AXI slave model: `WLAST` aligns with `AWLEN` (slave-side protocol check) | `tb_main.cpp:289-294` | Bridge's burst length matches its `AWLEN` claim |

---

## 5. Lint checks (Verilator `--lint-only -Wall`)

Run in `make lint` (and `make regress`).  Treated as assertions: any
warning fails the build.

| ID | Check | Source | Suppressions |
|----|-------|--------|--------------|
| LINT-W0 | Verilator default `-Wall` (no warnings) | `make lint` | `UNUSEDSIGNAL`, `UNUSEDPARAM` (5 expected unused — documented in `Makefile`'s `LINT_SUPPRESS` block) |

---

## 6. Cocotb directed tests (Icarus)

Run in `make cocotb`.  Each cocotb `@cocotb.test` is itself an assertion
that the bridge produces the right response — failures raise `AssertionError`.

| Test | Coverage | Location |
|------|----------|----------|
| `test_aligned_put_get` | Single-beat full-bus Put then Get | `cocotb/test_bridge.py` |
| `test_sub_bus_halves` | 32-bit writes at low + high halves of an 8 B beat | `cocotb/test_bridge.py` |
| `test_4beat_burst` | 32 B burst (size=5, 4 beats) | `cocotb/test_bridge.py` |
| `test_2beat_partial` | `PutPartialData` burst with per-beat WSTRB | `cocotb/test_bridge.py` |
| `test_hint` | Hint → HintAck single-beat | `cocotb/test_bridge.py` |
| `test_byte_at_offset` | size=0 byte at offset 3 of a beat | `cocotb/test_bridge.py` |
| `test_atomic_add` | `ArithmeticData` ADD RMW | `cocotb/test_bridge.py` |
| `test_atomic_xor` | `LogicalData` XOR RMW | `cocotb/test_bridge.py` |
| `test_atomic_swap` | `LogicalData` SWAP RMW | `cocotb/test_bridge.py` |

---

## 7. How to add a new property

1. **Decide layer.** Functional invariants → formal (high confidence,
   bounded depth).  Anything involving randomized data or burst-count
   inductive reasoning → scoreboard (cheap to write, runs every regress).
2. **Place it.** Formal: append to `tluhtoaxi4_props.sv` with an `// F<n>`
   comment header and a gate on `chk`.  Scoreboard: extend the verify
   loop in `tb_main.cpp` after the existing `CHECK(...)` block.
3. **Catalog it.** Add a row here with the same ID and a `file:line`
   anchor.  Update `doc/PLAN.md` if the property closes a deferred F-id.
4. **Re-run gates.** `make regress && make formal && make coverage`.
   Coverage may dip if the new assertion is "trap" code (unreachable
   error path) — that's OK as long as you stay above the 80 % floor.

---

## 7. TL-UL → AXI4-Lite bridge (`TLULToAXILite`)

The sibling AXI4-Lite bridge has a tighter property surface — no bursts,
no atomics, no read-burst lock — but mirrors the TL-UH catalog where
the concepts apply.  All formal artifacts live at
[`verification/formal/tlultoaxilite_props.sv`](../verification/formal/tlultoaxilite_props.sv)
and the `.sby` script next to it.  Defaults: `dataBits=32`, `sourceBits=4`,
`sizeBits=2`, `beatSizeLg=2`.

### 7.1 Formal safety assertions (BMC depth 20)

Engine disambiguation: the bridge ties `io_axi_b_ready := tl.d.ready`
only in `dSelW`, and `io_axi_r_ready := tl.d.ready` only in `dSelR`.
Defaults are zero elsewhere, so the helper wires `d_from_w`, `d_from_r`,
`d_from_he` identify which engine the arbiter selected for any D beat,
independent of opcode/denied combinations.  This is what makes a denied
`AccessAck` (BRESP error → W) cleanly distinguishable from a denied
`AccessAck` (local-error → E).

| ID | Property | Engines |
|----|----------|---------|
| F2 | `D.source == ghost.xact_source` snapshotted at admission | Read, Write, Hint, Error |
| F3 | `D.size == ghost.xact_size` snapshotted at admission | Read, Write, Hint, Error |
| F-UL-1 | `AW.addr[1:0] == AR.addr[1:0] == 0` (beatBytes alignment, default 32-bit data) | AXI side |
| — | `D.corrupt == 0` for `AccessAck` and `HintAck` | Write, Hint, Error |

**Result:** all pass at BMC depth 20 (`make formal-ulite`).

The TL-UH F6 (AxBURST/AxSIZE) and F-LOCK assertions don't apply: AXI4-Lite
has no `len`/`size`/`burst`/`lock` fields, so those properties are
trivially satisfied by the emitted port list (structural invariant —
verified by inspection at elaboration and by `make lint-ulite`).

### 7.2 Formal cover goals

| ID | Cover goal | Reached |
|----|------------|---------|
| C1 | A write transaction completes (`d_from_w`, AccessAck, not denied) | step 6 |
| C2 | A read transaction completes (`d_from_r`, AccessAckData) | step 6 |
| C3 | A hint transaction completes (`d_from_he`, HintAck) | step 5 |
| C4 | A local-error transaction completes (`d_from_he`, denied AccessAck) | step 5 |

**Result:** all four witnesses found by `smtbmc` in the `cover` task.

### 7.3 Formal environment assumptions

| ID | Assumption | Rationale |
|----|------------|-----------|
| UL-A0 | `a.valid == 0` during reset | Bridge does not accept A before reset deasserted |
| UL-A1 | `a.opcode ≤ 5` (PutFull, PutPart, Arith, Logic, Get, Hint) | Reserved opcodes (6, 7) excluded from the formal envelope |
| UL-A2 | A-channel bits stable while `valid && !ready` | TL master irrevocability |
| UL-A3 | Single-outstanding per engine: no second Get/Put/Hint of the same opcode while same engine is pending (errors may always re-enter the error slot is single-deep too) | Bridge's per-engine slot is 1-deep |
| UL-A4 | When `b.valid`, `w_pending` must be true | AXI slave doesn't fabricate write responses |
| UL-A5 | When `r.valid`, `r_pending` must be true | AXI slave doesn't fabricate read responses |
| AXI-Lite-B0 | B-channel `resp` stable while `valid && !ready` | AXI4-Lite §B1.1 |
| AXI-Lite-R0 | R-channel `data`/`resp` stable while `valid && !ready` | AXI4-Lite §B1.1 |

### 7.4 Scoreboard-level checks (Verilator C++ TB)

Run in `make sim-ulite`.  Defined in
[`test/cpp/tb_ulite.cpp`](../test/cpp/tb_ulite.cpp).

| ID | Check | Scope |
|----|-------|-------|
| ULTB-S1 | Per-source FIFO ordering: D response source matches a pending request from that source | Multi-engine concurrency safety |
| ULTB-S2 | `resp.size == job.req.size` | Size preservation (sim-level F3) |
| ULTB-S3 | `resp.denied == job.expectDenied` | Error propagation (RRESP/BRESP, unsupported, oversized) |
| ULTB-S4 | `resp.corrupt == job.expectCorrupt` | Corrupt bit on read errors |
| ULTB-S5 | `resp.opcode == job.expectOpcode` | D-opcode matches engine type |
| ULTB-S6 | `AccessAckData.data == ref.beat(address)` | Bridge data-path functional correctness |
| ULTB-S7 | Every per-source FIFO empty after run (no orphaned expectations) | Completeness |
| ULTB-S8 | Peak total in-flight transactions tracked and printed (sim achieves 3) | Concurrency exercised |

The AXI4-Lite slave model accepts `AW` and `W` in either order
(including same-cycle handshake of both), commits to memory once both
are present, and emits `B`.  Error injection at the same addresses as
the TL-UH TB (`0xD00` → RRESP=SLVERR, `0xD80` → BRESP=DECERR) so the
error-handling code paths are exercised identically across the two
bridges.

### 7.5 Cocotb directed tests (Icarus)

Run in `make cocotb-ulite`.  Defined in
[`cocotb/test_ulite.py`](../cocotb/test_ulite.py).

| Test | Coverage |
|------|----------|
| `test_aligned_put_get` | 32-bit aligned PutFull + Get round-trip |
| `test_byte_lanes` | size=0 write+read at each byte lane of the 32-bit beat |
| `test_half_word` | 16-bit writes at both halves of a beat, then full-beat Get |
| `test_partial_put` | PutPartialData with a custom mask — only middle bytes written |
| `test_hint` | Hint → HintAck |

### 7.6 Lint

Run in `make lint-ulite`.  Verilator `--lint-only -Wall` with the same
`UNUSEDSIGNAL`/`UNUSEDPARAM` suppressions used by the TL-UH bridge —
clean at 0 warnings.

---

## 8. Known gaps

These are tracked in `doc/PLAN.md` under longer horizon; listing here
so reviewers see the catalog's edges:

- **F1/F4/F5/F7** still pending on the TL-UH bridge — see §1's "Deferred" table.
- **WSTRB ⊆ mask** is only checked behaviorally by the AXI slave model;
  no formal assertion (applies to both bridges).
- **AXI exclusive-monitor semantics** (EXOKAY vs OKAY discrimination on
  atomic B-response) are not modelled — the TL-UH bridge accepts both as
  success, consistent with single-master use.
- **TL-UL randomized sweep.**  The TL-UL → AXI4-Lite C++ TB has 24
  directed jobs only; a randomized op-mix sweep would mirror the TL-UH
  bridge's 100-job random workload.
