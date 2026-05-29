# tilelink_to_AXI4

TileLink → AXI bridges, written in Chisel and verified with a Verilator
C++ testbench, SymbiYosys formal proofs, and cocotb.

This repo ships three sibling bridges:

- **TLUHToAXI4** — TileLink-UH (uncached heavyweight) → AXI4 master.
  Handles `Get`, `PutFullData`, `PutPartialData`, `Hint`, `ArithmeticData`,
  and `LogicalData`; bursts up to 64 bytes on a 64-bit data path; forwards
  the TL `source` field as the AXI ID for straight in-order routing.
- **TLULToAXILite** — TileLink-UL (uncached lightweight) → AXI4-Lite
  master.  Handles `Get`, `PutFullData`, `PutPartialData`, and `Hint` —
  single-beat only, 32-bit data path by default (also valid at 64-bit),
  no bursts, no atomics.  Intended for control-plane peripherals.
- **TLUCToAXI4** — TL-C wire shape (A + B + C + D + E) with no
  coherence → AXI4 master.  Carries the full TL-UH opcode set plus
  `AcquireBlock`, `AcquirePerm`, `Release`, and `ReleaseData`; always
  grants Tip on Acquire (no other sharers to invalidate); TL-B is tied
  off because the bridge never issues a Probe.  Intended for single
  cached masters where coherence is unnecessary, and as the stepping
  stone for the upcoming TL-C → CHI bridge.

All three present a TL slave port to the host and drive an AXI-family
master port to a memory-mapped subordinate.

## Directory layout

| Path | Purpose |
|------|---------|
| `src/main/scala/tlbridge/` | Chisel sources — `TLUHToAXI4`, `TLUHToAXI4Decoder`, `TLULToAXILite`, `TLUCToAXI4`, bundles, elaboration entry |
| `generated/` | Emitted SystemVerilog — `TLUHToAXI4.sv`, `decoder/`, `ulite/`, `uc/` |
| `test/cpp/` | Verilator C++ testbenches — `tb_main.cpp` (TL-UH), `tb_ulite.cpp` (TL-UL), `tb_uc.cpp` (TL-UC) |
| `cocotb/` | cocotb env + tests for all three bridges — `test_bridge.py`/`env.py` (TL-UH), `test_ulite.py`/`env_ulite.py` (TL-UL), `test_uc.py`/`env_uc.py` (TL-UC) |
| `verification/formal/` | SymbiYosys wrappers — `tluhtoaxi4_props.sv`, `tlultoaxilite_props.sv`, `tluctoaxi4_props.sv` |
| `build/`, `build_ulite/`, `build_uc/` | Verilator object dirs (auto-generated) |
| `doc/` | Design specs (`DESIGN_SPEC.md`, `DESIGN_SPEC_ULITE.md`, `DESIGN_SPEC_UC.md`) + roadmap |
| `Makefile` | `elab` / `build` / `sim` / `lint` / `formal` / `cocotb` / `clean` (+ `-ulite` / `-uc` variants) |
| `build.sbt` | Chisel / Scala project definition |

## Design contract

[`doc/DESIGN_SPEC.md`](doc/DESIGN_SPEC.md) is the protocol reference for
the TL-UH bridge: signal tables for both buses, opcode mapping, burst
calculation, FSM diagram, and the list of known limitations.
[`doc/DESIGN_SPEC_ULITE.md`](doc/DESIGN_SPEC_ULITE.md) covers the TL-UL
→ AXI4-Lite bridge.  [`doc/DESIGN_SPEC_UC.md`](doc/DESIGN_SPEC_UC.md)
covers the TL-UC → AXI4 bridge (TL-C wire shape, no coherence).  Treat
them as the source of truth for RTL behavior — the Chisel source cites
them back via comments.

## Tutorial

New to this repo? Start with [`doc/TUTORIAL.md`](doc/TUTORIAL.md) — a
~45-minute hands-on walk through the toolchain, the FSM, the testbench,
modifying the design, reading waveforms, and lint/coverage. Best read
with a terminal open.  Every safety property the bridge claims —
formal assertions, environment assumptions, scoreboard checks — is
cataloged in [`doc/ASSERTIONS.md`](doc/ASSERTIONS.md).  Wondering why
the bridge stops at TL-UH and doesn't extend to coherent TL-C?  See
[`doc/TLC_EVALUATION.md`](doc/TLC_EVALUATION.md).

## Prerequisites

- **sbt** (any 1.x, tested with 1.10.5). On WSL this user has the
  Coursier-managed toolchain in `~/.local/share/coursier/bin`.
- **JDK 11+** (Ubuntu `openjdk-11-jdk` works).
- **Verilator** 5.0+ — this project was developed against Verilator
  5.047 from the OSS CAD Suite (`~/oss-cad-suite/bin/verilator`).
- A C++17 compiler (`g++`).

The Chisel side pins `org.chipsalliance::chisel:7.7.0` (matches the
sibling `chisel-playground` repo); the SV is emitted via `firtool` bundled
with the Chisel artifact.

## Quick start

```bash
make sim     # elab + build + run the Verilator TB end-to-end
```

Run `make` with no arguments to print the full target list.  Individual
stages:

| Goal | Command |
|------|---------|
| Chisel → SystemVerilog (all variants) | `make elab` |
| Verilator build only (requires SV present) | `make build` |
| Run the TL-UH simulation | `make sim` |
| Run the TL-UL → AXI4-Lite simulation | `make sim-ulite` |
| Run the TL-UC → AXI4 simulation | `make sim-uc` |
| Verilator `--lint-only` (TL-UH bridge) | `make lint` |
| Verilator `--lint-only` (address-decoded variant) | `make lint-decoder` |
| Verilator `--lint-only` (TL-UL → AXI4-Lite variant) | `make lint-ulite` |
| Verilator `--lint-only` (TL-UC → AXI4 variant) | `make lint-uc` |
| Elaborate + lint `dataBits` width sweep | `make lint-widths` |
| Lint + sim across all three bridges (fast CI gate) | `make regress` |
| Lint + sim for the AXI-Lite variant only | `make regress-ulite` |
| Lint + sim for the TL-UC variant only | `make regress-uc` |
| Coverage build + `coverage.info` (TL-UH) | `make coverage` |
| HTML coverage report (requires `lcov`) | `make cov-report` |
| SymbiYosys BMC + cover (TL-UH) | `make formal` |
| SymbiYosys BMC + cover (TL-UL → AXI4-Lite) | `make formal-ulite` |
| SymbiYosys BMC + cover (TL-UC → AXI4) | `make formal-uc` |
| cocotb directed tests, TL-UH (Icarus) | `make cocotb` |
| cocotb directed tests, TL-UL → AXI4-Lite (Icarus) | `make cocotb-ulite` |
| cocotb directed tests, TL-UC → AXI4 (Icarus) | `make cocotb-uc` |
| Regress + coverage + formal + cocotb across all three bridges (full local CI) | `make ci` |
| Run sim and open `sim.vcd` in GTKWave | `make wave` |
| Open the formal cover witness in GTKWave | `make wave-formal` |
| Open the BMC counter-example (only after a failure) | `make wave-bmc` |
| Clean every generated artifact | `make clean` |

The wave targets honor `WAVE_VIEWER` (default `gtkwave`) and `WAVE_FILE`
(default `sim.vcd`).  Example: `make wave WAVE_VIEWER=surfer
WAVE_FILE=verification/formal/tluhtoaxi4_cover/engine_0/trace2.vcd`.

GitHub Actions coverage lives in `.github/workflows/ci.yml`, with separate
`regress`, `coverage`, `formal`, and `cocotb` jobs.

## Bridge mapping (summary)

### TL-UH → AXI4 (`TLUHToAXI4`)

| TL A opcode | AXI traffic | TL D response |
|---|---|---|
| `Get` (4) | `AR` + `R` | `AccessAckData` |
| `PutFullData` (0) | `AW` + `W` | `AccessAck` |
| `PutPartialData` (1) | `AW` + `W` (`mask` → `WSTRB`) | `AccessAck` |
| `Hint` (5) | *(none — handled in-bridge)* | `HintAck` |
| `ArithmeticData` (2) / `LogicalData` (3) | `AR(lock=1)` + `R` + `AW(lock=1)` + `W` (RMW) | `AccessAckData` (OLD value) |

Bursts are always `INCR`. `AxSIZE` is pinned at `log2(beatBytes) = 3`;
sub-bus writes ride a full beat with `WSTRB` selecting the active bytes.
The bridge runs four independent engines (read, write, atomic RMW, and a
1-deep hint slot) sharing TL-A by opcode and TL-D via a fixed-priority
arbiter (`W > R > A > H > E`) with a sticky lock for in-flight read
bursts.  TL `source` is forwarded directly as the AXI ID, so a host may
overlap a read, a write, an atomic, and a hint from distinct sources —
peak observed concurrency in the regression workload is 3 transactions
in flight.

### TL-UL → AXI4-Lite (`TLULToAXILite`)

| TL A opcode | AXI-Lite traffic | TL D response |
|---|---|---|
| `Get` (4) | `AR` + `R` | `AccessAckData` |
| `PutFullData` (0) | `AW` + `W` (issued in parallel) | `AccessAck` |
| `PutPartialData` (1) | `AW` + `W` (`mask` → `WSTRB`) | `AccessAck` |
| `Hint` (5) | *(none — handled in-bridge)* | `HintAck` |

TL-UL is **single-beat by construction** — `a.size ≤ log2(beatBytes)`;
oversized requests and unsupported opcodes (including atomics) route to
a 1-deep local-error slot and answer with a denied `AccessAck`.
AXI4-Lite carries no `id`, `len`, `size`, `burst`, `last`, `lock`,
`cache`, `qos`, or `region` fields — `AxPROT` and `?RESP` are the only
sidebands.  The bridge has three engines (read, write, hint) plus the
error slot; they share TL-D via a fixed-priority arbiter (`W > R > H > E`)
with no read-burst lock (it isn't needed without bursts).  Default
`dataBits = 32`; 64-bit is also valid per the AXI4-Lite spec.  See
[`doc/DESIGN_SPEC_ULITE.md`](doc/DESIGN_SPEC_ULITE.md) for the full
contract.

### TL-UC → AXI4 (`TLUCToAXI4`)

TL-C wire shape (A + B + C + D + E) with no coherence: the bridge
exposes all five TL-C channels, accepts cached opcodes, but the AXI4
downstream cannot participate in coherence so no probes are ever
issued.

| TL A opcode | AXI traffic | TL D response |
|---|---|---|
| TL-UH opcodes (`Get`, `Put*`, `Hint`, `ArithmeticData`, `LogicalData`) | same as TLUHToAXI4 | same |
| `AcquireBlock` (6) | `AR` + `R` | `GrantData(toT)` |
| `AcquirePerm` (7) | *(none)* | `Grant(toT)` |

| TL C opcode | AXI traffic | TL D response |
|---|---|---|
| `Release` (6) | *(none)* | `ReleaseAck` |
| `ReleaseData` (7) | `AW` + `W` (full mask) | `ReleaseAck` |

Bridge always returns `D.param = toT` regardless of the requested cap
(NtoB/NtoT/BtoT) — there are no other sharers to invalidate, and TL-C
allows granting more permission than asked.  TL-B is tied off
(`io_tl_b_valid := 0`).  Master must respond with `GrantAck` on TL-E
after every Grant/GrantData to release the Acquire engine slot.  Six
parallel engines (read, write, hint, atomic, acquire, release) plus a
local-error slot share TL-D via a fixed-priority arbiter
(`W > R > Atom > Acq > Rel > Hint > Err`) with a sticky burst lock for
multi-beat `AccessAckData` and `GrantData`.  See
[`doc/DESIGN_SPEC_UC.md`](doc/DESIGN_SPEC_UC.md) for the full
contract.

## Status snapshot

| Area | Status |
|------|--------|
| RTL | Both bridges elaborate cleanly (Chisel 7.7.0 → firtool 1.139.0) |
| TL-UH directed sim | 23 directed jobs (aligned, sub-bus high/low, 4-beat + 2-beat + 8-beat bursts, partial-strb single + burst, hint, byte at unaligned offset, explicit Put+Get+Hint concurrency, atomic ADD/XOR/SWAP, atomic R-error + B-error, AXI error responses, unsupported opcode, illegal size) |
| TL-UH random sim | 100 Put/Get/Hint randomized jobs + 24 atomic-init pairs (`0x4000+`) per run (seed `0xC0FFEE`, rotating sources, full op mix incl. PutPartialData and Arith/Logic atomics) |
| TL-UH last result | **PASS** — 183 jobs, 0 errors, 1442 sim ticks, peak concurrency=3 |
| TL-UL → AXI4-Lite sim | `make sim-ulite` — 24 directed jobs (aligned put/get, every byte lane, half-word at both halves, partial mask, hint, three-engine concurrency, AXI SLVERR + DECERR injection, unsupported opcode, oversized request).  **PASS** — 24 jobs, 0 errors, peak concurrency=3 |
| TL-UC → AXI4 sim | `make sim-uc` — 11 directed jobs (AcquireBlock(NtoT/NtoB) full cache line, AcquirePerm(NtoT), Release(TtoN), ReleaseData(TtoN), TL-UH Put+Get+Hint carry-over, AXI read-error injection on AcquireBlock).  **PASS** — 11 jobs, 0 errors, peak concurrency=2 |
| Lint | `make lint` + `make lint-ulite` + `make lint-uc` all clean (0 warnings, 5 documented `UNUSEDSIGNAL` suppressions on TL-UH/TL-UC) |
| Width sweep | `make lint-widths` clean for `dataBits ∈ {32, 64, 128, 256}` (TL-UH) |
| Coverage | 95.1% line (232/244) — above the 80% DV_STANDARDS floor (TL-UH) |
| Formal — TL-UH | `make formal` — BMC depth 30 + 4 cover witnesses (per-engine F2 / F3 incl. atomic, F6 / F8, F-LOCK, corrupt-discipline) |
| Formal — TL-UL → AXI4-Lite | `make formal-ulite` — BMC depth 20 + 4 cover witnesses (per-engine F2 / F3, F-UL-1 alignment, no-corrupt on AccessAck/HintAck) |
| Formal — TL-UC → AXI4 | `make formal-uc` — BMC depth 30 + 5 cover witnesses (F-UC-1 B-tied-off, F-UC-2 GrantData, F-UC-3 Grant, F-UC-4 ReleaseAck, F-UC-5 AR alignment + no lock) |
| Cocotb — TL-UH | `make cocotb` — 9 directed tests on Icarus (`cocotb/test_bridge.py`, incl. atomic add/xor/swap) |
| Cocotb — TL-UL → AXI4-Lite | `make cocotb-ulite` — 5 directed tests on Icarus (`cocotb/test_ulite.py`: aligned put/get, byte lanes, half-word, partial put, hint) |
| Cocotb — TL-UC → AXI4 | `make cocotb-uc` — 6 directed tests on Icarus (`cocotb/test_uc.py`: AcquireBlock NtoT/NtoB, AcquirePerm, Release, ReleaseData, TL-UH carry-over) |
| GitHub Actions CI | `.github/workflows/ci.yml` with regress / coverage / formal / cocotb jobs |
| Address-decoded variant | `TLUHToAXI4Decoder` (structural) — emitted to `generated/decoder/`, `make lint-decoder` clean. See `doc/DESIGN_SPEC.md#address-decoded-variant` for the master-side assumptions; full multi-port TB is a follow-up. |
