# tilelink_to_AXI4

A TileLink-UH (uncached heavyweight) to AXI4 bridge, written in Chisel and
verified with a Verilator C++ testbench.

The bridge presents a TileLink slave port to a TL host (manager) and drives
an AXI4 master port to a memory-mapped subordinate. It handles `Get`,
`PutFullData`, `PutPartialData`, and `Hint` opcodes; bursts up to 64 bytes
on a 64-bit data path; and forwards the TL `source` field as the AXI ID for
straight in-order routing.

## Directory layout

| Path | Purpose |
|------|---------|
| `src/main/scala/tlbridge/` | Chisel sources (bundles, FSM, elaboration entry) |
| `generated/` | Emitted SystemVerilog (`TLUHToAXI4.sv` + filelist) |
| `test/cpp/` | Verilator C++ testbench (`tb_main.cpp`) |
| `build/` | Verilator object dir (auto-generated) |
| `doc/` | Design spec + roadmap |
| `Makefile` | `elab` / `build` / `sim` / `clean` |
| `build.sbt` | Chisel / Scala project definition |

## Design contract

[`doc/DESIGN_SPEC.md`](doc/DESIGN_SPEC.md) is the protocol reference: signal
tables for both buses, opcode mapping, burst calculation, FSM diagram, and
the list of known limitations. Treat it as the source of truth for RTL
behavior — the Chisel source cites it back via comments.

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

Individual stages:

| Goal | Command |
|------|---------|
| Chisel → SystemVerilog only | `make elab` |
| Verilator build only (requires SV present) | `make build` |
| Run the simulation | `make sim` |
| Verilator `--lint-only` | `make lint` |
| Lint + sim (fast CI gate) | `make regress` |
| Coverage build + `coverage.info` | `make coverage` |
| HTML coverage report (requires `lcov`) | `make cov-report` |
| SymbiYosys BMC + cover | `make formal` |
| cocotb directed tests (Icarus) | `make cocotb` |
| Regress + coverage + formal + cocotb (full local CI) | `make ci` |
| Clean every generated artifact | `make clean` |

GitHub Actions coverage lives in `.github/workflows/ci.yml`, with separate
`regress`, `coverage`, `formal`, and `cocotb` jobs.

## Bridge mapping (summary)

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

## Status snapshot

| Area | Status |
|------|--------|
| RTL | Elaborated cleanly (Chisel 7.7.0 → firtool 1.139.0) |
| Directed sim | 23 directed jobs (aligned, sub-bus high/low, 4-beat + 2-beat + 8-beat bursts, partial-strb single + burst, hint, byte at unaligned offset, explicit Put+Get+Hint concurrency, atomic ADD/XOR/SWAP, atomic R-error + B-error, AXI error responses, unsupported opcode, illegal size) |
| Random sim | 100 Put/Get/Hint randomized jobs + 24 atomic-init pairs (`0x4000+`) per run (seed `0xC0FFEE`, rotating sources, full op mix incl. PutPartialData and Arith/Logic atomics) |
| Last result | **PASS** — 183 jobs, 0 errors, 1442 sim ticks, peak concurrency=3 |
| Lint | `make lint` clean (0 warnings, 5 documented `UNUSEDSIGNAL` suppressions) |
| Coverage | 95.1% line (232/244) — above the 80% DV_STANDARDS floor |
| Formal | `make formal` — BMC depth 30 + 4 cover witnesses (per-engine F2 / F3 incl. atomic, F6 / F8, F-LOCK, corrupt-discipline) |
| Cocotb | `make cocotb` — 9 directed tests on Icarus (`cocotb/test_bridge.py`, incl. atomic add/xor/swap) |
| GitHub Actions CI | `.github/workflows/ci.yml` with regress / coverage / formal / cocotb jobs |
