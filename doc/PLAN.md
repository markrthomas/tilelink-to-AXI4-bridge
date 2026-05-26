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
| Coverage | `make coverage` — Verilator `--coverage` → `coverage.info`. 88.5% line (92/104), above the 80% DV_STANDARDS floor |
| Formal | *(not implemented)* |
| Cocotb | *(not implemented)* |
| CI (GitHub Actions) | *(not implemented)* — `make ci` runs `regress + coverage` locally |
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

Result: **88.5% line coverage (92/104)**. Uncovered lines are firtool-emitted
structural artifacts (`always @(posedge clock) begin`, `automatic logic`
decls, port declarations) rather than actual logic gaps. A future
`doc/coverage_notes.md` should formalize these exclusions, modelled on
`IP-axi-to-2apbs/doc/coverage_notes.md`.

---

### 4 — `make formal` target (SymbiYosys)

**What:** Add a small `.sby` proof set targeting the bridge's structural
invariants. Reading `IP-axi-to-2apbs/verification/formal/` as a template,
the goals here are tighter than a full functional proof:

| ID | Property |
|----|----------|
| F1 | Every accepted A produces exactly one D (counted by `source`) |
| F2 | `D.source` matches the latched request `source` |
| F3 | `D.size` matches the latched request `size` |
| F4 | AXI burst length: `AxLEN + 1` equals the W-beat count emitted for that AW (and the R-beat count consumed for that AR) |
| F5 | `WSTRB ⊆ a_mask` (writes don't widen the active-bytes set) |
| F6 | `AxBURST == INCR` and `AxSIZE == 3` invariantly |
| F7 | `WLAST` and the bridge's `last` agree |

**Work items:**

- Create `verification/formal/Makefile` and `tluhtoaxi4.sby` with both
  `bmc` and `cover` tasks (DV_STANDARDS requires both).
- Put properties either inline in the Chisel (via `chisel3.ltl` or
  Verilog `formal` blocks gated with ``ifdef FORMAL``) or in a
  separate SV wrapper. The simplest path is a SV wrapper that
  instantiates the generated module and asserts F1–F7.
- BMC depth: 30 cycles handles a 4-beat burst end-to-end plus reset
  recovery. Start there; raise if a property needs more.
- Add a `make formal` rule that delegates to `verification/formal/`.

**Exit:** `make formal` proves F1–F7 at depth 30; CI-gated; counter-examples
investigated and either fixed in RTL or documented as design choices.

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
