# Development Plan — tilelink_to_AXI4

**As of:** 2026-05-26

## Current baseline

| Area | Status |
|------|--------|
| RTL | `TLUHToAXI4` elaborated cleanly (Chisel 7.7.0 → firtool 1.139.0 → 164-line `generated/TLUHToAXI4.sv`) |
| Directed simulation | 9 directed jobs via Verilator C++ TB (aligned, sub-bus high/low, 32 B + 16 B bursts, PutPartial single + burst, Hint, byte-at-offset) |
| Random simulation | 30 randomized jobs per run (seed `0xC0FFEE`) |
| Last result | **PASS** — 47 jobs, 0 errors, 400 sim ticks |
| Lint | `make lint` — Verilator `--lint-only -Wall`, 0 warnings (5 expected `UNUSEDSIGNAL` suppressions, documented in `Makefile`) |
| Regress | `make regress` — `lint + sim`, the fast CI gate |
| Coverage | `make coverage` — Verilator `--coverage` → `coverage.info`. 98.9% line (90/91), above the 80% DV_STANDARDS floor |
| Formal | `make formal` — SymbiYosys BMC + cover. F2/F6/F8 + corrupt-discipline prove at depth 30; C1/C2/C3 reachability witnesses found ≤ step 7 |
| Cocotb | *(not implemented)* |
| CI (GitHub Actions) | *(not implemented)* — `make ci` runs `regress + coverage + formal` locally |
| Documentation | `README.md`, `doc/DESIGN_SPEC.md`, this `doc/PLAN.md` |

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

Future work: F1/F4 will be revisited under [Phase 5 — Multiple
outstanding](#5--multiple-outstanding-transactions) when the bridge can
have more than one transaction in flight.

---

## Medium-term

### 5 — Multiple outstanding transactions

**What:** TileLink encodes concurrency via `source`. The current bridge
serialises everything, leaving throughput on the table. The interesting
case is overlapping a read and a write: AXI has separate AW/W and AR/R,
so the two can fully pipeline.

**Work items:**

- Refactor the FSM into two parallel engines (read engine, write engine)
  that arbitrate the shared `A` channel by opcode and the shared `D`
  channel by priority (typically writes drain first).
- Add a small `source → ID` table for multi-source hosts (or just forward
  `source` as ID directly and rely on AXI's ID-based ordering rules).
- Extend the TB to interleave reads and writes from distinct `source`
  values; assert that responses can return out-of-order relative to
  issue order (per TL spec).

**Exit:** TB passes a randomized interleaved workload of 100+ jobs with
≥ 2 concurrent transactions in flight at peak.

---

### 6 — Cocotb TB (parallel verification env)

**What:** A second TB in cocotb gives an independent check of the same
RTL and lines up with the sibling repos
(`IP-axi-to-2apbs/cocotb/`, `chi-to-bow-bridge/uvm/cocotb_bench/`).

**Work items:**

- New `cocotb/` directory at repo root with `Makefile` invoking
  `make SIM=verilator` and `VERILOG_SOURCES=../generated/TLUHToAXI4.sv`.
- Use `cocotb-bus` AXI4 BFM on the AXI side; write a small TL driver
  on the host side (no public TL-UH BFM exists in cocotb — write one).
- Mirror the directed jobs from `test/cpp/tb_main.cpp` so the two TBs
  are checking the same surface.
- **Toolchain note:** prior cocotb work in this workspace required
  `ICARUS_BIN_DIR=/usr/bin` to avoid OSS CAD Suite's bundled Python
  picking up the wrong interpreter. With Verilator, that issue may not
  apply — confirm before assuming.

**Exit:** `make cocotb` green; both TBs invoked from `make regress`
(slow-gate variant) or a separate `make regress-full`.

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
