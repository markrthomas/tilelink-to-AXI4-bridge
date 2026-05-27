# Development Plan — tilelink_to_AXI4

**As of:** 2026-05-27

## Current baseline

| Area | Status |
|------|--------|
| RTL | `TLUHToAXI4` (parallel read + write + atomic engines, 1-deep hint slot, fixed-priority D arbiter with read-burst lock) — Chisel 7.7.0 → firtool 1.139.0 SV |
| Directed simulation | 23 directed jobs (aligned / sub-bus / bursts incl. 64 B max / PutPartial / Hint / byte-at-offset / explicit concurrent Put→Get→Hint / atomic arith+logic / atomic R-error + B-error / AXI errors / unsupported opcode / illegal size) |
| Random simulation | 100 Put/Get/Hint + 24 atomic-init pairs (`0x4000+`) per run (seed `0xC0FFEE`, rotating sources, op mix Put/Get/Hint/Arith/Logic with `PutPartialData` masks) |
| Last result | **PASS** — 183 jobs, 0 errors, 1442 sim ticks, **peak concurrency = 3** |
| Lint | `make lint` — Verilator `--lint-only -Wall`, 0 warnings (5 expected `UNUSEDSIGNAL` suppressions, documented in `Makefile`) |
| Width sweep | `make lint-widths` — elaboration + Verilator lint for `dataBits ∈ {32, 64, 128, 256}` |
| Regress | `make regress` — `lint + lint-decoder + lint-widths + sim`, the fast CI gate |
| Coverage | `make coverage` — Verilator `--coverage` → `coverage.info`. 95.1% line (232/244), above the 80% DV_STANDARDS floor |
| Formal | `make formal` — SymbiYosys BMC + cover. Per-engine F2/F3 (incl. atomic), F6/F8, F-LOCK + corrupt-discipline prove at depth 30; C1/C2/C3/C4 witnesses found ≤ step 7 |
| Cocotb | `make cocotb` — 9 directed tests on Icarus (`cocotb/`), all pass; mirrors the C++ TB's directed subset incl. atomics |
| CI (GitHub Actions) | `.github/workflows/ci.yml` with separate `regress`, `coverage`, `formal`, and `cocotb` jobs |
| Documentation | `README.md`, `doc/DESIGN_SPEC.md`, this `doc/PLAN.md`, `doc/TUTORIAL.md`, `doc/ASSERTIONS.md`, `doc/TLC_EVALUATION.md` |

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
- Result: **127 jobs, 0 errors, peak concurrency = 3** — all three
  engines simultaneously in flight at the peak.
- Formal wrapper reworked into per-engine ghosts (`r_pending` /
  `w_pending` / `h_pending_g` with snapshotted source + size each).
  F2 splits into three per-opcode assertions; F3 (D.size matches the
  per-engine snapshotted A.size) added as a bonus.  Multi-beat Put
  burst-stability is now confined to `w_in_burst` (peek through last
  A.fire), leaving the master free to start a Get or Hint in parallel.
  BMC depth 30 passes; C1 / C2 / C3 witnesses found at step 7 / 6 / 5.
- Coverage held above the DV_STANDARDS floor with the new arbiter + ghost
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

### ~~7 — GitHub Actions CI~~ ✓ DONE 2026-05-26

**What:** A `.github/workflows/ci.yml` matching the DV_STANDARDS layout
(`regress` / `coverage` / `formal` / optionally `cocotb`).

Implemented as four jobs on `ubuntu-latest`: `regress`, `coverage`,
`cocotb`, and `formal`. Each job installs the required open-source tools,
reruns elaboration as needed, and coverage uploads `coverage.info` as an
artifact.

Follow-up: add a README badge after the workflow is green on the default
branch.

### ~~8 — Robust Local Error Slot & AXI Upgrades~~ ✓ DONE 2026-05-26

Refined the `isLocalError` handling to correctly consume bursts (illegal `Put` sizes/opcodes) and return a single `AccessAck` with `denied=1`, preventing bridge hangs during bring-up. Optimized `aBeats` calculation and added standard AXI4 sideband signals (`prot`, `cache`, `lock`, `qos`, `region`) driven with safe defaults. Enabled independent parameterization of `idBits` (ID ≥ source).

### ~~9 — Atomic opcodes~~ ✓ DONE 2026-05-26

Implemented support for `ArithmeticData` (`add`, `min`, `max`, …) and `LogicalData` (`xor`, `or`, `and`, `swap`) by mapping to AXI exclusive accesses (AxLOCK).  Includes:
- FSM expansion for Read-Modify-Write (RMW) sequence.
- Internal ALU for TileLink arithmetic/logical operations.
- Verification via directed RMW tests and formal properties for exclusivity.

### ~~10 — Atomic engine hardening~~ ✓ DONE 2026-05-27

Post-review hardening of the atomic engine landed in this phase:

- **W-channel arbitration fix.** `io.tl.a.ready` previously asserted for a
  Put beat while `wState===sWData && w.ready=1`, even if the atomic engine
  was simultaneously driving W (`aState===sAWrite`).  Since the W-mux
  routes atomic data on bits, the Put beat was silently consumed from TL
  with no AXI commit.  Gated the Put-row of the `a.ready` MuxCase on
  `!(aState === sAWrite)` so Put pauses for atomic's single-beat W.
- **AXI error propagation.** Atomic D response now carries `denied` /
  `corrupt` derived from RRESP/BRESP (`resp[1]` = SLVERR/DECERR).  On
  R-error the engine skips the write half and goes straight to sAResp
  with denied+corrupt — there's nothing meaningful to write back.
- **Random-sweep extension.** Added 24 atomic-init pairs at
  `0x4000-0x40F8` after the 100-job random workload, no `wait_all`
  between, so init-Puts pile into the write engine while previous
  atomics' RMWs are mid-flight — actually exercises the W-channel
  arbitration path.
- **Directed atomic-error tests.** New Test 12b (atomic at 0xD00 →
  RRESP=SLVERR) and 12c (atomic at 0xD80 → BRESP=DECERR) cover the new
  error-propagation paths.

Result: 183 jobs / 0 errors / 95.5% line coverage / formal still passes
at BMC depth 30 / cocotb 9 PASS.

---

## Longer horizon

| Theme | Aim |
|-------|-----|
| ~~TL-C evaluation~~ ✓ DONE 2026-05-27 — decision: stay on TL-UH.  See [`doc/TLC_EVALUATION.md`](TLC_EVALUATION.md) for the reasoning and triggers to revisit (ACE/ACE-Lite, probe-back consumers, coherent host interconnect). |
| ~~Address-decode bridge variant~~ ✓ DONE 2026-05-27 (structural) — new `TLUHToAXI4Decoder` module in `src/main/scala/tlbridge/TLUHToAXI4Decoder.scala`, parameterized by a `Seq[DecodeRegion]`.  Fans TL-A out by address; merges TL-D back via priority arbiter with a sticky lock for multi-beat AccessAckData bursts.  Emitted to `generated/decoder/` (separate dir so firtool's child-module pruning doesn't overwrite the standalone bridge).  `make lint-decoder` is part of the regress gate.  **Follow-up:** dedicated multi-port TB and formal extension (per-source ordering across regions is currently the master's responsibility — see scaladoc). |
| ~~Parameterized data widths~~ ✓ DONE 2026-05-27 — added `tlbridge.WidthSweep` and `make lint-widths`, which elaborates and Verilator-lints standalone bridge variants at `dataBits ∈ {32, 64, 128, 256}`. This is wired into `make regress` / CI. The self-checking C++ and cocotb benches remain 64-bit-specialized; making them width-generic is a possible future DV expansion rather than a parameterization blocker. |
| ~~ASSERTIONS.md~~ ✓ DONE 2026-05-27 — single catalog at `doc/ASSERTIONS.md` enumerating formal assertions, env assumptions, cover goals, scoreboard checks, lint, and cocotb tests. |
| ~~Atomic-engine formal~~ ✓ DONE 2026-05-27 — atomic ghost (`a_pending` / `a_xact_source` / `a_xact_size`), per-engine F2/F3 over read-vs-atomic disambiguated by `r_fire`, F-LOCK structural assertion, C4 cover witness, cross-engine source-uniqueness assumption.  Found a latent bridge bug in the process: `dSelR` published `tl.d.valid = 1'b1` even when no fresh AXI R was backing the beat — fixed in the bridge (now gated on `io.axi.r.valid`). |
| UVM environment | If/when the workspace standardizes on UVM CI, add a `uvm/` env mirroring `IP-axi-to-2apbs/uvm/`. |

---

## How to use this file

- Promote a longer-horizon item to near/medium-term when scope is clear.
- Update **Current baseline** when a milestone lands.
- Mark completed phases by striking the heading and dating it, e.g.
  `~~### 1 — make lint target~~ ✓ DONE 2026-MM-DD`.
- Convert near-term items to GitHub issues with acceptance criteria
  before starting.
