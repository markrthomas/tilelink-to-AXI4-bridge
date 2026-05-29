# TL-C → CHI Bridge — Staged Implementation Plan

**Status:** Stages 1–3 landed 2026-05-29; Stages 4–7 pending.
**As of:** 2026-05-29
**Direction:** TL-C upstream → CHI Issue-E downstream
**Module name:** `TLCToCHI`

This document is the roadmap for adding a TL-C → CHI bridge as a third
sibling variant alongside `TLUHToAXI4` and `TLULToAXILite`.  It is
substantially larger than either of those bridges and is therefore
staged so each milestone is independently shippable (lint + sim + formal
+ cocotb all green before the next stage starts).  No RTL has been
written yet; the plan is gated on a separate go-ahead.

## 0. Context

The earlier [`TLC_EVALUATION.md`](TLC_EVALUATION.md) memo documented the
decision to **not** extend the bridge to TL-C.  That decision is being
reopened (see the status note at the top of that file).  The trigger is
explicit: add a coherent TileLink → coherent fabric path for use cases
that the TL-UH bridge cannot cover.  The earlier analysis (TL-C
introduces probes, permissions, dirty writebacks; AXI4 has no coherence
primitives) remains accurate — that is precisely why CHI is the target
this time, not AXI4.

## 1. Scope and ground rules

| | |
|---|---|
| Module name | `TLCToCHI` |
| Role | TL-C **slave** (sinks A + C; sources B + D); CHI **Request Node** (RN-F, fully-coherent) |
| CHI issue | **Issue E** (snoopable, atomic ops, DCT/DMT, prefetch hints) |
| Cache line | 64 B (CHI Issue-E RN-F baseline) — parameterization deferred |
| Coherence mapping | TL-C `N` ≡ CHI `I`; TL-C `B` ≡ CHI `SC`; TL-C `T` ≡ CHI `UC`/`UD` |
| Topology | One TL-C master upstream; one CHI fabric downstream.  Multi-master is out of scope |
| Out of scope (forever) | Home-Node mode, ACE/ACE-Lite, multi-host snoop arbitration in the bridge |
| Out of scope (for now) | Persistent CMO, RAS, MTE, DVM, realm/secure-world distinctions |
| Makefile parity | `lint-chi`, `sim-chi`, `formal-chi`, `cocotb-chi`, `regress-chi`; `regress`/`ci` extended |

## 2. Open questions to settle before Stage 1

1. **DCT / DMT** support — does the bridge advertise Direct Cache/Memory
   Transfer in its CHI capabilities?  Off-by-default is simpler; on
   adds a fourth formal property catalog.
2. **CHI HN model for verification** — synthesize a toy Home Node from
   the spec, or import a permissively-licensed reference if one exists?
   Affects Stage 2 timeline most.
3. **Multi-line atomic guarantee** — confirm the upstream TL-C master
   never crosses a cache-line boundary in atomic ops (CHI Issue-E
   atomics are single-line).
4. **Cache line parameterization** — pin at 64 B for Stage 1 or expose
   `lineBytes` as a `CHIBridgeParams` field?  Pin is recommended.

## 3. Stages

Each stage is an independently shippable milestone.  The Makefile gains
the `chi` variant slot in Stage 1 and stays green from then on.

### ~~Stage 1 — Protocol mapping doc + skeleton~~ ✓ DONE 2026-05-28

**Deliverables (all landed)**
- `doc/DESIGN_SPEC_CHI.md` — full TL↔CHI opcode/permission mapping
  tables, channel signal tables, transaction-flow diagrams (acquire,
  release, snoop), CHI ordering rules applied to the bridge, Stage 1
  limits.
- `src/main/scala/tlbridge/CHIBundles.scala` — `CHIBridgeParams` + CHI
  REQ/RSP/DAT/SNP bundles + `CHIOpcode` and `CHIResp` constants
  (Issue-E values for Stage 2–6 opcodes).
- TL-C channel bundles (`TLBChannel`, `TLCChannel`, `TLEChannel`,
  `TLUCSlaveIO`) reused as-is from `Bundles.scala` — these landed
  with the TL-UC bridge work and didn't need duplication.
- `src/main/scala/tlbridge/TLCToCHI.scala` — module skeleton with all
  5 TL channels + all 4 CHI channels wired (txreq/txrsp/txdat +
  rxrsp/rxdat/rxsnp), every output tied to a safe default, zero
  functional behavior.
- `Main.scala` emits to `generated/chi/TLCToCHI.sv`.
- `Makefile`, `cocotb/Makefile`, `verification/formal/Makefile`
  extended with the `chi` variant slot.  `make lint-chi` is in
  `make regress`.

**Exit criteria met**
- Lint-clean elaboration of `TLCToCHI` — `make lint-chi`: 0 warnings.
- Mapping doc complete at `doc/DESIGN_SPEC_CHI.md` (10 sections, ~450 lines).
- No regression: full `make regress` PASS — TLUH 183 jobs, ULite 24
  jobs, UC 11 jobs, all 0 errors; all 6 lint targets clean.

### ~~Stage 2 — Read-shared path~~ ✓ DONE 2026-05-29

The simplest end-to-end story: a cold `AcquireBlock(NtoB)` returns a
clean shared copy.  Proves the channel plumbing.

**Mapping**
| TL | CHI |
|---|---|
| TL-A `AcquireBlock(NtoB)` | REQ `ReadShared` |
| DAT `CompData(SC)` | TL-D `GrantData(toB)` |
| RSP `Comp` (when `ExpCompAck=1`) | TL-E `GrantAck` → CHI RSP `CompAck` |

Landed with the Stage 3 work — the acquire engine in
`TLCToCHI.scala` handles all four cases together (NtoB, NtoT, BtoT,
AcquirePerm), since the state machine is identical and the divergence
is purely opcode/needsData selection at A.fire.

### ~~Stage 3 — Read-unique path~~ ✓ DONE 2026-05-29

**Mapping**
| TL | CHI |
|---|---|
| TL-A `AcquireBlock(NtoT)` | REQ `ReadUnique` |
| TL-A `AcquireBlock(BtoT)` | REQ `MakeUnique` |
| TL-A `AcquirePerm(*)` | REQ `MakeUnique` |
| DAT `CompData(UC)` / `CompData(UD)` | TL-D `GrantData(toT)` |
| RSP `Comp` (UC, no data) | TL-D `Grant(toT)` |

**Deliverables (all landed)**
- Acquire engine in `TLCToCHI.scala`: A → REQ issue path
  (snapshot at A.fire), CompData / Comp → D, TL-E → CHI CompAck.
- `test/cpp/tb_chi.cpp` — Verilator TB with a CHI HN model that
  serves ReadShared / ReadUnique / MakeUnique end-to-end.
- `cocotb/env_chi.py` + `cocotb/test_chi.py` — single
  `test_acquire_mixed` exercising all four acquire cases.
- `verification/formal/tlctochi_props.sv` — F-CHI-1
  (REQ opcode matches snapshot {opcode,param}), F-CHI-2 (CompAck
  txnID matches snapshot source), F-CHI-3 (D.source = snapshot
  source).  Two cover goals: Grant and GrantData both reachable.

**Exit criteria met**
- `make sim-chi` PASS: 4 directed jobs (NtoB, NtoT, BtoT, AcquirePerm).
- `make formal-chi` BMC depth 20 PASS, both cover goals reached.
- `make cocotb-chi` PASS: 1 test.
- `make regress` PASS — TLUH 183 jobs, ULite 24, UC 11, CHI 4; all
  lints clean.

### Stage 4 — Release path

Writes data back to memory through the CHI side.

**Mapping**
| TL | CHI |
|---|---|
| `Release(TtoB)` | `WriteCleanFull` |
| `Release(TtoN, clean)` | `Evict` |
| `ReleaseData(TtoN)` | `WriteBackFull` |
| `Release(BtoN)` | `Evict` |
| `ReleaseData(TtoB)` | `WriteCleanFull` (with data) |
| RSP `Comp` for WriteBack* / WriteClean* | TL-D `ReleaseAck` |

**Verification additions**
- Directed Release tests for every (current, target) permission pair
- Formal: F-CHI-4 (every Release path produces exactly one ReleaseAck),
  F-CHI-5 (data preservation across WriteBack → ReadShared roundtrip)

### Stage 5 — Snoop path *(hardest)*

Turn incoming CHI snoops into TL-B Probes; forward TL-C
`ProbeAck`/`ProbeAckData` back as CHI `SnpResp`.  This is where the
canonical TL-C deadlock pits live.

**Mapping**
| CHI | TL |
|---|---|
| SNP `SnpShared` / `SnpNotSharedDirty` | TL-B `Probe(toB)` |
| SNP `SnpUnique` | TL-B `Probe(toN)` |
| SNP `SnpClean` | TL-B `Probe(toB)` + require data if dirty |
| SNP `SnpOnce` | TL-B `Probe` allowing source to keep state |
| SNP `SnpMakeInvalid` | TL-B `Probe(toN)`, no data |
| TL-C `ProbeAck` | RSP `SnpResp` |
| TL-C `ProbeAckData` | DAT `SnpRespData` |

**Critical correctness work**
- **Probe ↔ Release race.**  The host may issue a `Release` for the
  same line just before the bridge dispatches a `Probe`.  Bridge must
  collapse: drop the Probe and answer the snoop with the released state.
- **CHI ExpCompAck ordering.**  Snoops to addresses with outstanding
  `ReadUnique` requests must respect CHI §B2 hazard rules.
- **TL-B forward-progress.**  Bridge must not block TL-A on TL-B
  (deadlock).

**Verification additions**
- TB CHI HN model gains a snooper with configurable post-grant delay
- Directed snoop tests: each Snp* opcode against each cached state
- Formal: F-CHI-6 (every Snp produces exactly one SnpResp),
  F-CHI-7 (no Probe without a covering CHI Snp),
  F-CHI-8 (Probe-Release race resolved deterministically)
- Cocotb: snoop-while-modified, snoop-while-shared, snoop-during-acquire

### Stage 6 — Atomics, CMO, prefetch

**Mapping**
| TL | CHI |
|---|---|
| TL-A `ArithmeticData` / `LogicalData` | `AtomicStore_*` / `AtomicLoad_*` / `AtomicSwap` / `AtomicCompare` |
| TL-A `Hint(PrefetchRead)` | `ReadOnce` or `PrefetchTgt` |
| TL-A `Hint(PrefetchWrite)` | `ReadOnceMakeInvalid` or omit |
| CMO opcodes via Hint param (if used) | `CleanInvalid` / `CleanShared` / `MakeInvalid` |

**Verification additions**
- Atomic ADD / XOR / SWAP / CAS directed + randomized
- Formal: F-CHI-9 (atomic completes in-order with prior reads/writes
  per CHI §B2 ordering)

### Stage 7 — Full verification surface + CI parity

- Randomized C++ TB sweep (100–500 jobs across opcode × permission)
  mirroring the TLUH `0xC0FFEE` workload
- BMC depth bumped to 30 across all properties
- Coverage measured; target 90 %+ line, document structural exclusions
- `.github/workflows/ci.yml` gains a `chi` job parallel to the existing four
- `doc/ASSERTIONS.md` §8 catalog appended
- `doc/PLAN.md` "longer horizon" row marked DONE with verification-parity
  summary
- `make ci` runs everything

## 4. Makefile shape (concrete, lands in Stage 1)

Mirrors the AXI-Lite pattern:

```make
CHI_DIR := $(GEN_DIR)/chi
CHI_SV  := $(CHI_DIR)/TLCToCHI.sv
CHI_TB  := test/cpp/tb_chi.cpp
CHI_BUILD := build_chi
CHI_EXE   := $(CHI_BUILD)/VTLCToCHI

elab ... $(CHI_SV):
	$(SBT) -batch "runMain tlbridge.Main"

lint-chi: $(CHI_SV)
	$(VERILATOR) --lint-only -Wall $(LINT_SUPPRESS) \
	    --top-module TLCToCHI $(CHI_SV)

build-chi $(CHI_EXE): $(CHI_SV) $(CHI_TB)
	$(VERILATOR) $(CHI_VERILATOR_FLAGS) -o VTLCToCHI $(CHI_SV) $(CHI_TB)

sim-chi: $(CHI_EXE)
	cd $(CHI_BUILD) && ./VTLCToCHI

formal-chi: $(CHI_SV)
	$(MAKE) -C verification/formal chi

cocotb-chi: $(CHI_SV)
	$(MAKE) -C cocotb chi

regress: lint lint-decoder lint-widths lint-ulite lint-chi sim sim-ulite sim-chi
ci:      regress coverage formal formal-ulite formal-chi cocotb cocotb-ulite cocotb-chi
```

`cocotb/Makefile` gains a `VARIANT=chi` branch; `verification/formal/Makefile`
gains `chi` / `chi-bmc` / `chi-cover` targets.

## 5. Files added (final shape after Stage 7)

```
src/main/scala/tlbridge/
  CHIBundles.scala            — CHI REQ/RSP/DAT/SNP bundles + opcode consts
  TLCBundles.scala            — TLBChannel, TLCChannel, TLEChannel
  TLCToCHI.scala              — the bridge

test/cpp/
  tb_chi.cpp                  — Verilator TB with CHI HN model

cocotb/
  env_chi.py, test_chi.py     — cocotb env + tests

verification/formal/
  tlctochi_props.sv           — SymbiYosys wrapper
  tlctochi.sby                — proof script

doc/
  DESIGN_SPEC_CHI.md          — protocol reference (Stage 1 deliverable, ~600–1000 lines)
  ASSERTIONS.md               — §8 catalog appended (Stage 7)
  PLAN.md                     — phase entries (each stage exit)
  TLC_EVALUATION.md           — verdict updated (Stage 1)
  README.md                   — third bridge in intro and tables (Stage 7)
```

## 6. Risks

| Risk | Mitigation |
|---|---|
| CHI HN model is non-trivial — bugs in our model can mask bridge bugs | Cross-check against published Arm CHI reference flows; revisit at Stage 2 exit |
| Issue-E surface is huge — property catalog could grow to 20+ formal claims | Stage 5 (snoop) is the budget driver; lock Stage 4 first |
| Probe ↔ Release race is the canonical TL-C deadlock pit | Mandatory formal property (F-CHI-8) before Stage 5 exits |
| CHI ordering rules vs. TL forward-progress | Baseline `RequestOrder=0`, `ExpCompAck=1`; document limits |
| No reference SV simulator for CHI | All TB infrastructure is hand-rolled, like the existing two bridges |
| Effort estimate uncertainty | Re-plan after Stage 4 lands |

## 7. Ballpark effort

| Stage | Calendar |
|---|---|
| 1 — Mapping doc + skeleton | 2 weeks |
| 2 — Read-shared | 3–4 weeks |
| 3 — Read-unique | 2–3 weeks |
| 4 — Release | 3 weeks |
| 5 — Snoop | 4 weeks |
| 6 — Atomics/CMO/prefetch | 3 weeks |
| 7 — Full verification + CI parity | 2 weeks |
| **Total** | **19–21 weeks** of focused work |

## 8. Status & next step

**Stages 1–3 landed 2026-05-29.**  Skeleton + spec + Makefile slot
(Stage 1), then the full read path covering NtoB / NtoT / BtoT /
AcquirePerm in a single acquire engine (Stages 2 & 3 collapsed into
one delivery since the divergence is opcode-selection-only).

The four open questions in §2 were settled as follows:
1. **DCT/DMT:** off for Stage 1; revisit at Stage 5.
2. **CHI HN model:** hand-rolled from the spec (landed in Stage 3
   at `test/cpp/tb_chi.cpp` and `cocotb/env_chi.py`).
3. **Multi-line atomics:** confirmed disallowed — bridge will enforce
   `a.size ≤ log2(lineBytes)` for atomics at elaboration.
4. **Cache line:** pinned at 64 B.

**Next step is a separate go-ahead** to start Stage 4 (release path:
`Release(TtoB)` → `WriteCleanFull`, `ReleaseData(TtoN)` →
`WriteBackFull`, `Release(TtoN, clean)` / `Release(BtoN)` →
`Evict`, with CHI `Comp` → TL `ReleaseAck`).  Budget: 3 weeks.
Will need:
- A release engine in `TLCToCHI.scala` parallel to the existing
  acquire engine (C-channel intake + REQ issue + DAT write + RSP
  consumption + D-channel `ReleaseAck`).
- TL master driver extension in `tb_chi.cpp` and `env_chi.py` to
  emit C-channel Release / ReleaseData traffic and consume the
  resulting D-channel `ReleaseAck`.
- F-CHI-4 (every Release path produces exactly one ReleaseAck)
  and F-CHI-5 (data preservation across WriteBack → ReadShared
  roundtrip).
- One cocotb test (`test_acquire_ntob`) and 5+ directed C++ jobs.
