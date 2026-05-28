# Tutorial — Building, Running, and Modifying the TileLink → AXI4 Bridge

This tutorial walks through this repo end-to-end: from a fresh clone with
no idea what's inside, to comfortably reading the FSM, modifying the
testbench, inspecting waveforms, and extending the verification.

It's written assuming you know **some** digital design (handshakes,
state machines, address/data buses) but have not necessarily touched
Chisel or Verilator before. Sections are independent — skip the
toolchain bit if `make sim` already works for you.

Time budget: **~45 minutes** for the full walk; ~15 minutes for the
shortest path (Section 0 → 2 → 3).

---

## 0. Prerequisites

You need three tools on `PATH`:

| Tool | Purpose | Typical install |
|------|---------|-----------------|
| **sbt** (1.10+) | Scala build tool — drives the Chisel → SystemVerilog elaboration | `apt install sbt` or [Coursier](https://get-coursier.io/) (`cs install sbt`) |
| **JDK 11+** | sbt and the Chisel/firtool jar both need a JVM | `apt install openjdk-11-jdk` |
| **Verilator** (5.0+) | SystemVerilog simulator that consumes the emitted `.sv` and your C++ TB | [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) is the easy path; ships at `~/oss-cad-suite/bin/verilator` |

Verify:

```bash
sbt --version       # any 1.10.x
java -version       # 11.x or later
verilator --version # 5.0 or later
g++ --version       # any modern g++ supporting -std=c++17
```

Optional but recommended:

- **GTKWave** — VCD viewer for poking at waveforms. `apt install gtkwave`
- **lcov / genhtml** — to render the coverage HTML report.
  `apt install lcov`

---

## 1. Repository tour (3 minutes)

```
.
├── build.sbt                              # Scala/Chisel project deps
├── Makefile                               # All the targets you'll use
├── README.md
├── doc/
│   ├── DESIGN_SPEC.md                     # Protocol reference for the TL-UH bridge
│   ├── DESIGN_SPEC_ULITE.md               # Protocol reference for the TL-UL → AXI4-Lite bridge
│   ├── ASSERTIONS.md                      # Property catalog for both bridges
│   ├── PLAN.md                            # Roadmap (DV_STANDARDS gaps)
│   ├── TLC_EVALUATION.md                  # Why we stay on TL-UH (not TL-C)
│   └── TUTORIAL.md                        # ← this file
├── src/main/scala/tlbridge/
│   ├── Bundles.scala                      # TL-UH and AXI4 IO bundles + opcode constants
│   ├── TLUHToAXI4.scala                   # The TL-UH bridge (the focus of this tutorial)
│   ├── TLUHToAXI4Decoder.scala            # Address-decoded N-port wrapper around TLUHToAXI4
│   ├── TLULToAXILite.scala                # Sibling TL-UL → AXI4-Lite bridge (single-beat)
│   └── Main.scala                         # Elaboration entry point (emits all variants)
├── test/cpp/
│   ├── tb_main.cpp                        # Verilator C++ testbench (TL-UH)
│   └── tb_ulite.cpp                       # Verilator C++ testbench (TL-UL → AXI4-Lite)
├── cocotb/
│   ├── env.py, test_bridge.py             # cocotb env + tests for TL-UH
│   └── env_ulite.py, test_ulite.py        # cocotb env + tests for TL-UL → AXI4-Lite
├── verification/formal/
│   ├── tluhtoaxi4_props.sv + .sby         # SymbiYosys wrapper for TL-UH
│   └── tlultoaxilite_props.sv + .sby      # SymbiYosys wrapper for TL-UL → AXI4-Lite
└── generated/                             # `make elab` writes here
    ├── TLUHToAXI4.sv                      # The emitted SystemVerilog (TL-UH bridge)
    ├── decoder/                           # Address-decoded variant
    └── ulite/                             # TL-UL → AXI4-Lite bridge
```

> **Tutorial scope.** The walk-through below uses the TL-UH bridge as
> the running example.  The sibling TL-UL → AXI4-Lite bridge has the same
> shape (Chisel module → SV emit → Verilator/cocotb/formal) and the same
> Makefile workflow with a `-ulite` suffix on each target (e.g.
> `make sim-ulite`, `make formal-ulite`).  Its design contract lives in
> [`DESIGN_SPEC_ULITE.md`](DESIGN_SPEC_ULITE.md); the C++ TB at
> `test/cpp/tb_ulite.cpp` is a good 300-line counterpoint to `tb_main.cpp`
> if you want to see a simpler driver/slave pair.

Two paths from source to a running sim:

1. **`make elab`** runs sbt, which compiles the Scala, then invokes
   `circt.stage.ChiselStage.emitSystemVerilogFile` (this calls the
   bundled `firtool` binary) to write `generated/TLUHToAXI4.sv`.
2. **`make build`** runs Verilator on `(SV, tb_main.cpp)`, producing a
   C++ binary at `build/VTLUHToAXI4`.
3. **`make sim`** runs that binary.

`make sim` chains all three (it's the default goal).

---

## 2. First build (5 minutes)

From the repo root:

```bash
make sim
```

What you should see (truncated):

```
sbt -batch "runMain tlbridge.Main"
[info] welcome to sbt 1.10.5
[info] compiling 3 Scala sources to ...
[info] running tlbridge.Main
Wrote SystemVerilog to generated/
[success] Total time: 16 s

verilator --cc --exe --build --trace -Wall ...
g++ ... -o VTLUHToAXI4
- Verilator: Walltime ...

cd build && ./VTLUHToAXI4

*** PASS: 47 jobs, 0 errors, 400 sim ticks ***
```

The `*** PASS ***` line is what you're aiming for. If it says **FAIL**
anywhere, jump to **Section 10: Troubleshooting**.

A `sim.vcd` waveform file should now exist at the repo root.

---

## 3. What just ran? (10 minutes)

### 3.1 The bridge in one paragraph

A TileLink **manager** (master) sits in front of you. Behind you sits
an AXI4 memory **subordinate** (slave). The bridge translates between
them. The manager issues TL `Get` / `PutFullData` / `PutPartialData` /
`Hint` opcodes on the **A channel**; the bridge fans them out to AXI4
`AR`/`AW`/`W` traffic, captures `R`/`B` responses, and replies on the
TL **D channel** with `AccessAck` / `AccessAckData` / `HintAck`.

A picture from `doc/DESIGN_SPEC.md`:

```
+---------+   Channel A   +---------------+    AW / W   +-------------+
|   TL    | ------------> |               | ----------> |             |
|  HOST   |               |  TLUHToAXI4   |     B       | AXI4 MEMORY |
| (Mgr.)  | <------------ |    (this)     | <---------- | SUBORDINATE |
|         |   Channel D   |               |    AR / R   |             |
+---------+               +---------------+ <---------> +-------------+
```

### 3.2 The 7-state FSM

Open `src/main/scala/tlbridge/TLUHToAXI4.scala`. Look at line 28:

```scala
val sIdle :: sReadAR :: sReadResp :: sWriteAW :: sWriteData ::
  sWriteResp :: sHintAck :: Nil = Enum(7)
```

Each TL transaction visits a subset of these states:

| TL request | State sequence |
|------------|----------------|
| `Get` (read) | `sIdle → sReadAR → sReadResp → sIdle` |
| `PutFullData` / `PutPartialData` | `sIdle → sWriteAW → sWriteData → sWriteResp → sIdle` |
| `Hint` | `sIdle → sHintAck → sIdle` |

The interesting wrinkle is **`sIdle` for writes peeks the A request
without firing**. TL guarantees the master holds an A-beat valid until
handshake; the bridge samples `opcode`/`size`/`address`/`source` from a
valid beat without asserting `a_ready`, then transitions to
`sWriteAW`. The first write *data* beat is therefore consumed later in
`sWriteData`, not in `sIdle`, so its `data`/`mask` aren't lost.

See `TLUHToAXI4.scala:79-91` for the opcode decode.

### 3.3 The testbench

`test/cpp/tb_main.cpp` has four moving parts:

1. **`TLDriver`** — issues TL A requests, collects TL D responses
2. **`AXISlave`** — behavioral AXI4 memory: accepts AW/W bursts, drives
   R bursts, uses `std::map<uint32_t, uint8_t>` as backing store
3. **`RefMem`** — golden reference; receives every Put at enqueue time;
   answers what a Get *should* return
4. **The `step()` lambda** — one TB cycle: drive inputs, sample
   combinational outputs, then advance the clock

The "sample-before-edge" ordering in `step()` is load-bearing — there's
a 9-line block comment explaining why. If you reorder it, the sim
will silently see 0 responses (it did during bring-up; see the
comment).

Test list (search for `// Test`):

| # | What |
|---|------|
| 1 | 64-bit aligned write+read at `0x100` |
| 2 | 32-bit sub-bus write+read at `0x200` (low half) |
| 3 | 32-bit sub-bus write+read at `0x204` (high half) |
| 4 | 32 B burst (4 beats) at `0x400` |
| 5 | 16 B burst (2 beats) at `0x300` |
| 6 | `PutPartialData` (single beat, strb = `0b00111100`) at `0x500` |
| 7 | `PutPartialData` burst (2 beats, varying strb) at `0x600` |
| 8 | `Hint` → `HintAck` |
| 9 | 1-byte write+read at offset 3 of `0x800` |
| 10+ | 30 randomized jobs (`std::mt19937(0xC0FFEE)`) |

---

## 4. Hands-on: change a parameter (10 minutes)

Let's widen the data bus from 64 to 128 bits and see what changes.

### 4.1 Edit the param

In `src/main/scala/tlbridge/Bundles.scala`, find:

```scala
case class BridgeParams(
  addrBits:   Int = 32,
  dataBits:   Int = 64,        // ← this line
  sourceBits: Int = 4,
  sizeBits:   Int = 6
)
```

Change `dataBits = 64` to `dataBits = 128`.

### 4.2 Update the testbench to match

The TB also hard-codes the data width. In `test/cpp/tb_main.cpp` near
the top:

```cpp
static constexpr int DATA_BITS    = 64;
```

You'd change this to `128` and audit the use sites (`uint64_t` data
becomes a multi-word value). **For this tutorial, revert the param change**
instead of rewriting the TB — the point is to see the elaboration adapt:

```bash
# Without reverting yet, run just the elaboration:
make clean
make elab
grep -E "(io_tl_a_bits_data|io_axi_w_bits_data)" generated/TLUHToAXI4.sv
```

You should see widths change from `[63:0]` to `[127:0]`:

```
input  [127:0] io_tl_a_bits_data,
output [127:0] io_axi_w_bits_data,
```

Revert `dataBits` to `64` before continuing:

```bash
# Edit Bundles.scala back to dataBits: Int = 64
make sim    # should PASS 47/47 again
```

### 4.3 Why this is interesting

The bridge is **fully parameterized over the data width**. You didn't
touch any RTL logic — `beatBytes`, `beatSizeLg`, the WSTRB width, the
beat counter, and all the AXI side-band widths derive automatically
from `BridgeParams`. This is the Chisel value proposition: parameters
flow through types, not through `localparam` math.

---

## 5. Hands-on: add a failing test (10 minutes)

The fastest way to trust verification is to break it and watch it
catch you.

In `tb_main.cpp`, find the directed test block (around line ~445):

```cpp
// Test 1: 64-bit aligned write + read
enqueue(mkPutFull(0x100, 3, 1, {0xDEADBEEFCAFEBABEULL}));
enqueue(mkGet    (0x100, 3, 2));
```

Add a **deliberately wrong** check right after. We'll falsify the
reference model so the TB *should* fail:

```cpp
// Tutorial: induce a failure to confirm the checker is awake.
ref.bytes[0x100] = 0x00;   // ← reference now disagrees with the bridge
```

Place that line **after** Test 1's two `enqueue` calls but **before**
any other tests.

```bash
make sim
```

You should see something like:

```
FAIL ../test/cpp/tb_main.cpp:530: job 1 Get @0x00000100 beat 0:
        got 0xdeadbeefcafebabe want 0xdeadbeefcafeba00
...
*** FAIL: 1 error(s), 47 jobs ***
```

Good. The checker is alive. **Remove the line** and rebuild:

```bash
make sim    # PASS again
```

### 5.1 Now add a *real* test

How about a 64-byte burst (8 beats at 64 b/beat, the max
`sizeBits = 6` allows)?

```cpp
// Test 11: 64-byte burst (size=6) — 8 beats
enqueue(mkPutFull(0x1000, 6, 11, {
    0xA000000000000000ULL, 0xA000000000000001ULL,
    0xA000000000000002ULL, 0xA000000000000003ULL,
    0xA000000000000004ULL, 0xA000000000000005ULL,
    0xA000000000000006ULL, 0xA000000000000007ULL,
}));
enqueue(mkGet    (0x1000, 6, 12));
```

```bash
make sim
```

Should now PASS 49 jobs. You exercised an 8-beat AXI INCR burst with
`AWLEN = 7`.

If you want a more thorough sanity check, raise the **randomized job
count** (search for `t < 30` near the bottom of the directed-test
section) and rerun.

---

## 6. Hands-on: read a waveform (5 minutes)

`make sim` writes a VCD trace to `sim.vcd`. Open it:

```bash
gtkwave sim.vcd &
```

In the **SST** pane (top-left), expand `TOP → TLUHToAXI4`. Drag these
into the wave window to see the FSM stepping through:

| Signal | What to watch |
|--------|---------------|
| `clock`, `reset` | Free reset for ~8 cycles, then real activity |
| `state[2:0]` | Walks `sIdle (0)` → `sWriteAW (3)` → `sWriteData (4)` → `sWriteResp (5)` → `sIdle (0)` → `sReadAR (1)` → `sReadResp (2)` → `sIdle (0)` for Test 1 |
| `io_tl_a_valid`, `io_tl_a_ready`, `io_tl_a_bits_opcode[2:0]` | A handshakes (opcode 0=`PutFullData`, 4=`Get`) |
| `io_axi_aw_valid`, `io_axi_aw_ready`, `io_axi_aw_bits_addr[31:0]` | The AW channel firing once per Put |
| `io_axi_w_valid`, `io_axi_w_bits_data[63:0]`, `io_axi_w_bits_last` | Streaming write data; `WLAST` rises on the final beat |
| `io_axi_b_valid`, `io_axi_b_bits_resp[1:0]` | Write response = `OKAY` (0) |
| `io_tl_d_valid`, `io_tl_d_bits_opcode[2:0]` | D responses (0=AccessAck, 1=AccessAckData, 2=HintAck) |

**What to look for:**

- Every AW transaction is followed by exactly `AWLEN + 1` W beats with
  `WLAST` on the last one.
- The bridge state machine spends most of its time in `sIdle` between
  transactions.
- For a sub-bus write (Test 2 at `0x200`, `size = 2`), `WSTRB` is
  `0x0F` (low half active); for the high-half (Test 3 at `0x204`),
  it's `0xF0`. `io_axi_aw_bits_addr` is `0x200` in both cases — the
  bridge aligned the address and let WSTRB carry the offset.

---

## 7. Lint and coverage tour (5 minutes)

```bash
make lint        # Verilator --lint-only -Wall — must be 0 warnings
make coverage    # Builds a separate coverage harness, dumps coverage.info
make cov-report  # Renders HTML (requires `lcov` installed)
make regress     # lint + sim (the fast CI gate per DV_STANDARDS)
make ci          # regress + coverage (local "everything")
```

`make coverage` should print:

```
Line coverage: 92/104 (88.5%)
```

The 12 uncovered lines are firtool-emitted structural artifacts
(`always @(posedge clock) begin`, port declarations) — not real
logic gaps. See `doc/PLAN.md` for the formalization plan.

### 7.1 What `make lint` is doing

```bash
verilator --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          --top-module TLUHToAXI4 generated/TLUHToAXI4.sv
```

The two suppressed warnings would otherwise fire on five intentionally
unused signals:

- `io_tl_a_bits_param`, `io_tl_a_bits_corrupt` — TL fields the bridge
  doesn't propagate (documented in `doc/DESIGN_SPEC.md`)
- `io_axi_b_bits_id`, `io_axi_r_bits_id` — bridge checks these with
  assertions against the latched source, but still returns the latched TL
  source on D
- `regAddr[2:0]` — masked off by `regAddrAligned` (the low 3 bits go
  into WSTRB selection, not the AXI address)

If you remove the suppressions and re-run lint, you'll see all five.

---

## 8. Hands-on: extend the bridge (15 minutes, advanced)

Try one of these as a self-driven exercise. Each is a real RTL change,
not just a test extension.

### 8.1 Add a 4KB-boundary guard

AXI4 INCR bursts must not cross a 4KB boundary. Add an RTL assertion that
checks the aligned `AW` / `AR` address plus burst byte count stays within
the current 4KB page, then add a directed test near `0xFF0` that documents
the expected behavior.

What to verify:
- Legal bursts still pass unchanged
- The new assertion fires for a crossing burst in simulation/formal
- The design spec documents whether this is an integration constraint or a
  denied-response case

### 8.2 Add a deadlock watchdog

In the main sim loop near the `MAX_CYCLES` check, count how many
consecutive cycles `state` is non-zero with `tl_a_valid` low. If
that exceeds, say, 200 cycles, dump the state and FAIL fast — this
catches future RTL bugs that hang the FSM mid-transaction.

### 8.3 Add a simple bridge property

Pick a low-hanging invariant from `doc/PLAN.md` Phase 4:

> F6: `AxBURST == INCR` and `AxSIZE == 3` invariantly

Add this check directly in the C++ TB (no formal needed):

```cpp
// In step() after dut->eval():
if (dut->io_axi_aw_valid) {
    CHECK(dut->io_axi_aw_bits_burst == 1,
          "AW.burst not INCR: got %d", (int)dut->io_axi_aw_bits_burst);
    CHECK(dut->io_axi_aw_bits_size == 3,
          "AW.size not 3: got %d", (int)dut->io_axi_aw_bits_size);
}
```

This catches regressions and is the cheap alternative to a formal
proof for some invariants.

---

## 9. Where to go next

- **`doc/DESIGN_SPEC.md`** — full signal-by-signal reference. The
  authoritative protocol description.
- **`doc/PLAN.md`** — phased roadmap. The core DV milestones are complete;
  longer-horizon items track atomics, width sweeps, and optional UVM work.
- **Workspace `DV_STANDARDS.md`** (`../DV_STANDARDS.md`) — the shared
  conventions the sibling RTL repos follow; lists what's standard
  across the workspace.
- **Sibling repos** for comparison:
  - `IP-axi-to-2apbs/` — fully-built AXI→APB bridge with UVM, formal,
    coverage, CI all complete. The closest "what the finished version
    of this repo looks like."
  - `chi-to-bow-bridge/` — different protocol family, similar DV
    structure.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `sbt: command not found` | sbt not installed / not on PATH | `apt install sbt` or `cs install sbt` |
| `verilator: command not found` | OSS CAD Suite not sourced | `source ~/oss-cad-suite/environment` or add to PATH |
| First `make elab` takes 60+ s | sbt downloading Chisel + dependencies on first run | Wait it out; subsequent runs use the cache (~5 s) |
| `make sim` says `FAIL: N errors` after a TB edit | Your edit doesn't match what the bridge does | Check the reference-model `apply()` and the request — they must agree on what should land in memory |
| `make coverage` says `0/0 (0%)` | Verilator built without `--coverage`, or the TB skipped the `coveragep()->write()` call | Make sure `VM_COVERAGE` is set (only in `build_cov/`, not `build/`) |
| GTKWave shows no signals | You opened the file but didn't drag any signals into the wave pane | In the SST pane, double-click the module name; drag signals to the right |
| Lint warning fires on a signal you added | It's actually unused, OR you spelled it differently from how Chisel emits it | Run `grep -n <signal> generated/TLUHToAXI4.sv` to confirm the emitted name |

If you're stuck, the most useful single artifact is the VCD: open
`sim.vcd` in GTKWave, find the cycle where things go wrong, and look
at the FSM state plus the handshake signals.
