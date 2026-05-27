# Development Plan — tilelink_to_AXI4

**As of:** 2026-05-26

## Current baseline

| Area | Status |
|------|--------|
| RTL | `TLUHToAXI4` (parallel read + write engines, 1-deep hint slot, fixed-priority D arbiter with read-burst lock) — Chisel 7.7.0 → firtool 1.139.0 SV |
| Directed simulation | 13 directed jobs (aligned / sub-bus / bursts / PutPartial / Hint / byte-at-offset / explicit concurrent Put→Get→Hint) |
| Random simulation | 100 randomized jobs per run (seed `0xC0FFEE`, rotating sources, op mix Put/Get/Hint, includes `PutPartialData` with random mask) |
| Last result | **PASS** — 121 jobs, 0 errors, 734 sim ticks, **peak concurrency = 3** (read + write + hint simultaneously in flight) |
| Lint | `make lint` — Verilator `--lint-only -Wall`, 0 warnings (5 expected `UNUSEDSIGNAL` suppressions, documented in `Makefile`) |
| Regress | `make regress` — `lint + sim`, the fast CI gate |
| Coverage | `make coverage` — Verilator `--coverage` → `coverage.info`. 97.1% line (132/136), above the 80% DV_STANDARDS floor |
| Formal | `make formal` — SymbiYosys BMC + cover. Per-engine F2/F3/F6/F8 + corrupt-discipline prove at depth 30; C1/C2/C3 witnesses found ≤ step 7 |
| Cocotb | `make cocotb` — 6 directed tests on Icarus (`cocotb/`), all pass; mirrors the C++ TB's directed subset |
| CI (GitHub Actions) | *(not implemented)* — `make ci` runs `regress + coverage + formal + cocotb` locally |
| Documentation | `README.md`, `doc/DESIGN_SPEC.md`, this `doc/PLAN.md`, `doc/TUTORIAL.md` |

The repo passes the workspace-level `make sim` requirement of
[`DV_STANDARDS.md`](../../DV_STANDARDS.md) but is missing every other
standard target. Closing those gaps is the spine of this plan.

---

## Near-term

### ~~1 — `make lint` target~~ ✓ DONE 2026-05-26

Added `lint:` rule running `verilator --lint-only -Wall` with
`-Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM`. The five expected unused signals
(`io_tl_a_bits_param`, `io_tl_a_bits_corrupt`, `io_axi_b_bits_id`,
`io_axi_r_bits_id`, `regAddr[2:0]`) are documented in the `Makefile`
comment block above `LINT_SUPPRESS`. `make lint` exits 0.

---

### ~~2 — `make regress` target~~ ✓ DONE 2026-05-26

Added `regress: lint sim` alias. Confirmed clean.

---

### ~~3 — `make coverage` target~~ ✓ DONE 2026-05-26

Coverage harness builds into `build_cov/` with `--coverage --trace`.
TB calls `Verilated::threadContextp()->coveragep()->write("coverage.dat")`
on exit (guarded by `VM_COVERAGE`). `verilator_coverage --write-info`
converts to lcov format at `coverage.info`. `make cov-report` builds an
HTML report via `genhtml` if `lcov` is installed.

Result: **98.9% line coverage (90/91)**. The single uncovered line is a
firtool-emitted structural artifact rather than a logic gap. (Initial
result was 88.5% / 92 of 104; switching the firtool emit to
`--lowering-options=disallowLocalVariables` for Phase 4 collapsed the
old `automatic logic` decls into module-level wires, removing the
uncoverable lines from the line count too.) A future
`doc/coverage_notes.md` should formalize remaining exclusions, modelled on
`IP-axi-to-2apbs/doc/coverage_notes.md`.

---

### ~~4 — `make formal` target (SymbiYosys)~~ ✓ DONE 2026-05-26

Added a free-input SV wrapper at `verification/formal/tluhtoaxi4_props.sv`
that instantiates the elaborated bridge, drives every input with
`(* anyseq *)`, and layers TL master + AXI subordinate compliance
assumptions on top. The proof set is narrower than the initial F1–F7 wish
list — F1/F3/F4/F5/F7 are deferred to multi-outstanding work — but
captures the structural invariants that matter for the single-outstanding
bridge:

| ID | Property | Result |
|----|----------|--------|
| F2 | `D.source == xact_source` (snapshot at first A.valid of the transaction) | **pass** @ depth 30 |
| F6 | `AW.burst == AR.burst == INCR`; `AW.size == AR.size == 3` | **pass** @ depth 30 |
| F8 | `AW.addr[2:0] == AR.addr[2:0] == 0` (beatBytes alignment) | **pass** @ depth 30 |
| —  | Writes/Hints never set `D.corrupt` | **pass** @ depth 30 |
| C1 | An AccessAck (write) reaches D | witness @ step 7 |
| C2 | An AccessAckData (read) reaches D | witness @ step 6 |
| C3 | A HintAck reaches D | witness @ step 5 |

**Key implementation notes:**

- Reset is sourced from a wrapper-local phase counter (`ph`) and gated by
  `f_past_valid` — copying the idiom used by `chi_to_bow_bridge`. Yosys'
  `smtbmc` engine treats step 0 specially, so we hold the design in reset
  for the first four steps before any assertion fires.
- Yosys' SystemVerilog frontend rejects `automatic logic` declarations
  inside `always` blocks. The Chisel emit was changed to pass
  `--lowering-options=disallowLocalVariables` to firtool so the generated
  `TLUHToAXI4.sv` is parseable by Yosys without preprocessing.
- F2 required a ghost-state pair (`pending_xact`, `xact_source`) that
  snapshots the source on the *first* A.valid cycle of each transaction
  (not on every `a.fire`). This matches the bridge's "peek in sIdle"
  behavior for Put bursts. The wrapper also adds a multi-beat
  burst-stability assumption (`source`/`opcode`/`size` constant across
  every beat of a Put burst), which is a real TL master contract; without
  it the engine produced spurious counter-examples by mutating the source
  mid-burst.

Phase-4 follow-up: F1 and F4 were on the original wishlist but require
multiple in-flight transactions to be interesting (counting them, checking
that ID-vs-source matches survive concurrency).  They were brought into
the multi-outstanding work below as F3 + per-engine F2, rather than
deferred.

---

## Medium-term

### ~~5 — Multiple outstanding transactions~~ ✓ DONE 2026-05-26

Refactored the bridge from a monolithic 7-state FSM into three independent
engines that share TL-A by opcode and TL-D via a fixed-priority arbiter:

- **Read engine** (`sRIdle / sRAR / sRResp`) — handles `Get → AR → R →
  AccessAckData`.
- **Write engine** (`sWIdle / sWAW / sWData / sWResp`) — handles
  `Put → AW + W → AccessAck` with the same "peek in sIdle" trick as
  before so the bridge can latch context before the first A.fire.
- **Hint slot** (1-deep) — handles `Hint → HintAck` without occupying
  AXI bandwidth.
- **D-channel arbiter** — fixed priority `W > R > H` with a sticky
  read-burst lock so an in-flight `AccessAckData` burst can never be
  preempted by a write or hint response.

`source` is forwarded directly as the AXI ID; no source→ID translation
table is needed because each engine has at most one outstanding
transaction.

**Verification update:**

- TB now matches D responses to requests by per-source FIFO (so it
  tolerates out-of-order completion), tracks the count of outstanding
  transactions live, and asserts a peak-concurrency floor of ≥ 2.
- New explicit directed test (`Test 10`) issues a 4-beat Put followed by
  a Get and a Hint with distinct sources, hitting all three engines.
- Randomized sweep grew from 30 → 100 jobs, with rotating source IDs
  and `PutPartialData` mixed in.
- Result: **121 jobs, 0 errors, peak concurrency = 3** — all three
  engines simultaneously in flight at the peak.
- Formal wrapper reworked into per-engine ghosts (`r_pending` /
  `w_pending` / `h_pending_g` with snapshotted source + size each).
  F2 splits into three per-opcode assertions; F3 (D.size matches the
  per-engine snapshotted A.size) added as a bonus.  Multi-beat Put
  burst-stability is now confined to `w_in_burst` (peek through last
  A.fire), leaving the master free to start a Get or Hint in parallel.
  BMC depth 30 passes; C1 / C2 / C3 witnesses found at step 7 / 6 / 5.
- Coverage held at 97.1% line (132 / 136) with the new arbiter + ghost
  paths.

**Exit met:** randomized workload of 100+ jobs passes with peak
concurrency = 3 (specification was ≥ 2).

---

### ~~6 — Cocotb TB (parallel verification env)~~ ✓ DONE 2026-05-26

Added a self-contained cocotb env at `cocotb/` with a hand-rolled TL
master driver and AXI4 subordinate model (no external BFM dependency).
The Makefile uses `SIM=icarus` and follows the same env-isolation pattern
as `IP-axi-to-2apbs/cocotb/` so the GPI module loads the system Python
that has cocotb on PYTHONPATH (not OSS CAD Suite's bundled interpreter).

| File | Purpose |
|------|---------|
| `cocotb/Makefile` | cocotb-config wrapper, points at `generated/TLUHToAXI4.sv` |
| `cocotb/env.py` | `TLMaster`, `AxiSlave`, `reset_dut`, opcode constants |
| `cocotb/test_bridge.py` | 6 directed tests mirroring the C++ TB's directed jobs |

Tests:

* `test_aligned_put_get`  — 64-bit aligned write + read
* `test_sub_bus_halves`   — 32-bit writes at low + high halves of an 8 B beat
* `test_4beat_burst`      — 32 B / 4-beat burst at `0x400`
* `test_2beat_partial`    — `PutPartialData` burst with per-beat WSTRB
* `test_hint`             — Hint → HintAck
* `test_byte_at_offset`   — single byte at offset 3 of a beat

All 6 pass under Icarus.  Result hooked up via top-level `make cocotb`
target and included in `make ci`.

Future cocotb work: expand to interleaved concurrent tests (Put+Get+Hint
in flight simultaneously) mirroring the C++ TB's `Test 10` and 100-job
randomized sweep.  Not on the critical path for parity with sibling
repos; defer until the cocotb env has proven stable.  Note: SIM=verilator
was considered but Icarus was chosen for parity with the sibling repos
(same toolchain quirks, same `ICARUS_BIN_DIR=/usr/bin` workaround for
the OSS CAD Suite Python conflict).

---

### 7 — GitHub Actions CI

**What:** A `.github/workflows/ci.yml` matching the DV_STANDARDS layout
(`regress` / `coverage` / `formal` / optionally `cocotb`).

**Work items:**

- One job per target. All on `ubuntu-latest`. Use the workspace-pinned
  `OSS_CAD_SUITE_VERSION` from `dv_env.mk` (if/when this repo joins it).
- `regress` blocks merge; `coverage`, `formal`, `cocotb` run on PRs but
  do not block (initially).
- Upload `coverage.info` and (if present) `sim.vcd` as artifacts.

**Exit:** Green CI on the default branch; badge in `README.md`.

---

## Longer horizon

| Theme | Aim |
|-------|-----|
| Atomic opcodes | Implement `ArithmeticData` (`add`, `min`, `max`, …) and `LogicalData` (`xor`, `or`, `and`, `swap`) by mapping to AXI exclusive accesses or in-bridge RMW. Needs a design note on consistency. |
| TL-C evaluation | Decide whether to upgrade to coherent TL (Acquire/Release/Probe). Tentatively *no* — AXI lacks coherence semantics; document the reasoning. |
| Address-decode bridge variant | Multi-subordinate variant fronting several AXI ports keyed on `a_address[31]` (or a config table). Mirrors `IP-axi-to-2apbs`'s APB0/APB1 split. |
| Parameterized data widths | Validate elaboration and verification at `dataBits ∈ {32, 64, 128, 256}`. |
| ASSERTIONS.md | Per the workspace-wide TODO in `DV_STANDARDS.md`, enumerate every assertion/property and where it lives. |
| UVM environment | If/when the workspace standardizes on UVM CI, add a `uvm/` env mirroring `IP-axi-to-2apbs/uvm/`. |

---

## How to use this file

- Promote a longer-horizon item to near/medium-term when scope is clear.
- Update **Current baseline** when a milestone lands.
- Mark completed phases by striking the heading and dating it, e.g.
  `~~### 1 — make lint target~~ ✓ DONE 2026-MM-DD`.
- Convert near-term items to GitHub issues with acceptance criteria
  before starting.
