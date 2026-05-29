# TL-C → CHI Bridge — Staged Implementation Plan

**Status:** planning — not yet started
**As of:** 2026-05-28
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

### Stage 1 — Protocol mapping doc + skeleton

**Deliverables**
- `doc/DESIGN_SPEC_CHI.md` — full opcode/permission mapping, channel
  diagrams, FSM sketches, state encodings, the CHI §2 and §B ordering
  rules applied to the bridge
- `src/main/scala/tlbridge/CHIBundles.scala` — CHI REQ/RSP/DAT/SNP
  bundles and opcode constants
- `src/main/scala/tlbridge/TLCBundles.scala` (or extend `Bundles.scala`)
  — `TLBChannel`, `TLCChannel`, `TLEChannel`
- `src/main/scala/tlbridge/TLCToCHI.scala` — module skeleton with all 5
  TL channels + all 4 CHI channels wired, every output tied to a safe
  default, zero functional behavior
- `make lint-chi` clean
- `Makefile`, `cocotb/Makefile`, `verification/formal/Makefile` extended
  with the `chi` variant slot

**Exit criteria**
- Lint-clean elaboration of `TLCToCHI`
- Mapping doc reviewed
- No regression in TLUH / ULite paths

### Stage 2 — Read-shared path

The simplest end-to-end story: a cold `AcquireBlock(NtoB)` returns a
clean shared copy.  Proves the channel plumbing.

**Mapping**
| TL | CHI |
|---|---|
| TL-A `AcquireBlock(NtoB)` | REQ `ReadShared` |
| DAT `CompData(SC)` | TL-D `GrantData(toB)` |
| RSP `Comp` (when `ExpCompAck=1`) | TL-E `GrantAck` → CHI RSP `CompAck` |

**Deliverables**
- TL-A → REQ issue path with TxnID allocation table
- DAT → TL-D forwarding (byte enables, partial returns, beat assembly)
- TL-E → CHI RSP `CompAck` reverse path
- `test/cpp/tb_chi.cpp` — minimal CHI HN model that always returns `SC`
- 1 cocotb test (`test_acquire_ntob`)
- Formal: F-CHI-1 (TxnID conservation across REQ/DAT/RSP),
  F-CHI-2 (no GrantData without a matching prior AcquireBlock)

**Exit criteria**
- `make sim-chi` PASS on 5+ directed `AcquireBlock(NtoB)` jobs
- BMC depth 20 PASS
- 1 cocotb test green

### Stage 3 — Read-unique path

**Mapping**
| TL | CHI |
|---|---|
| TL-A `AcquireBlock(NtoT)` | REQ `ReadUnique` |
| TL-A `AcquireBlock(BtoT)` | REQ `MakeUnique` |
| TL-A `AcquirePerm(*)` | REQ `MakeUnique` |
| DAT `CompData(UC)` / `CompData(UD)` | TL-D `GrantData(toT)` |
| RSP `Comp` (UC, no data) | TL-D `Grant(toT)` |

**Verification additions**
- Permission upgrade cases (cold T, B→T)
- Cocotb: `test_acquire_ntot`, `test_make_unique_btot`
- Formal: F-CHI-3 (permission monotonicity — D.param consistent with
  request, modulo SC/UC ambiguity)

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

The plan is locked but no RTL has been written.  Next step is a separate
go-ahead from you on:

- The four open questions in §2
- Whether to start Stage 1 immediately or wait
- Whether stages 1–7 should also become GitHub issues with acceptance
  checklists (recommended once Stage 1 starts)
