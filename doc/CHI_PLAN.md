# TL-C → CHI Bridge — Staged Implementation Plan

**Status:** Stages 1–6 landed 2026-05-29; Stage 7 pending.
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

### ~~Stage 4 — Release path~~ ✓ DONE 2026-05-29

Writes data back to memory through the CHI side.

**Mapping (as landed — refined from the original draft for CHI sanity)**
| TL | CHI |
|---|---|
| `Release(*)`             | `Evict`          |
| `ReleaseData(TtoN)`      | `WriteBackFull`  |
| `ReleaseData(TtoB)`      | `WriteCleanFull` |
| RSP `Comp` (for Evict)   | TL-D `ReleaseAck` |
| RSP `CompDBIDResp` → DAT `CopyBackWrData` → TL-D `ReleaseAck` (for WriteBack/Clean) | |

The original draft mapped `Release(TtoB) → WriteCleanFull (no data)`,
which is semantically nonsensical in CHI (WriteCleanFull always carries
data — it writes a dirty line back while retaining a clean copy).  The
implemented mapping uses `Release → Evict` regardless of param: a clean
downgrade has nothing to write back, so a silent Evict is the only
correct CHI representation.  `ReleaseData` carries dirty data and
routes through `WriteBackFull` (drop to I) or `WriteCleanFull`
(retain as SC) based on target permission.

**Deliverables (all landed)**
- Release engine in `TLCToCHI.scala` parallel to the acquire engine.
  5-state FSM (Idle → REQ → Rsp → DAT → Ack).  TxnID partition:
  acquire uses `{1'b0, source}`, release uses `{1'b1, source}` — keeps
  the two engines disjoint on the shared CHI rxrsp channel.
- C-channel intake: Release (no data) fires C in idle; ReleaseData
  snapshots in idle then forwards beats in DAT after the HN returns
  `CompDBIDResp`.
- TXDAT: `CopyBackWrData` beats with the HN-issued dbID; `resp` = SC
  for WriteCleanFull, I for WriteBackFull.
- D-channel arbitration: acquire-first priority; `ReleaseAck` issued
  from the release engine when in sRelAck.
- TB extension (`test/cpp/tb_chi.cpp`): TL-C driver, txdat collector,
  CHI HN model serves `Comp` for Evict and `CompDBIDResp` + 8-beat
  data collection for WriteBack/Clean.  4 new directed release jobs
  (Release TtoN, Release BtoN, ReleaseData TtoN, ReleaseData TtoB).
- Cocotb: new `test_release_mixed` covers all four release cases on
  Icarus.
- Formal additions (`tlctochi_props.sv`): F-CHI-1 extended with the
  release mapping, F-CHI-4 (txdat fires only with a release in
  flight, opcode = CopyBackWrData), F-CHI-5 (txnID partition — REQ
  opcodes match their txnID MSB).  Cover goals added for ReleaseAck,
  CopyBackWrData, Evict REQ, and WriteBackFull REQ.

**Exit criteria met**
- `make sim-chi` PASS: 8 directed jobs total (4 acquires + 4 releases).
- `make formal-chi` BMC depth 20 PASS, all 6 cover goals reached.
- `make cocotb-chi` PASS: 2 tests.
- `make regress` PASS with no regression.

### ~~Stage 5 — Snoop path~~ ✓ DONE 2026-05-29

Turn incoming CHI snoops into TL-B Probes; forward TL-C
`ProbeAck`/`ProbeAckData` back as CHI `SnpResp` / `SnpRespData`.

**Mapping (as landed)**
| CHI | TL |
|---|---|
| SNP `SnpShared` / `SnpClean` / `SnpNotSharedDirty` | TL-B `Probe(toB)` |
| SNP `SnpUnique` / `SnpCleanInvalid` / `SnpMakeInvalid` | TL-B `Probe(toN)` |
| TL-C `ProbeAck`     (clean retained)  | RSP `SnpResp(SC)` |
| TL-C `ProbeAck`     (`*N`)            | RSP `SnpResp(I)` |
| TL-C `ProbeAckData` (`TtoB`)          | DAT `SnpRespData(SC+PassDirty=0x5)` |
| TL-C `ProbeAckData` (`TtoN`)          | DAT `SnpRespData(I+PassDirty=0x4)` |

The probe param is derived purely from the snoop opcode (invalidating
snoops → `toN`, all others → `toB`); the snoop response code is derived
from the param the master returns on C.  `SnpOnce` is treated as a plain
`toB` probe.

**Deliverables (all landed)**
- Snoop engine in `TLCToCHI.scala`: a 5-state FSM
  (Idle → Probe → WaitC → DataFwd → Rsp) running in parallel with the
  acquire and release engines.  rxsnp intake → TL-B Probe →
  TL-C ProbeAck/ProbeAckData → CHI SnpResp (txrsp) / SnpRespData (txdat).
- Shared-channel arbitration extended: txrsp = acquire (CompAck) >
  snoop (SnpResp); txdat = release (CopyBackWrData) > snoop
  (SnpRespData).  C-channel intake routed by opcode — ProbeAck families
  to snoop, Release families to release — so a single C-beat is consumed
  by exactly one engine.
- TB extension (`test/cpp/tb_chi.cpp`): TL-B Probe sink, pre-loadable
  probe responses, CHI HN snoop injector + SnpResp/SnpRespData collector.
  4 new directed snoop jobs (SnpShared/SnpUnique × ProbeAck/ProbeAckData).
- Cocotb: `test_snoop_mixed` covers the same four cases on Icarus.
- Formal additions (`tlctochi_props.sv`): F-CHI-6 (snoop response
  conservation — SnpResp/SnpRespData only with a live snoop, txnID
  echo), F-CHI-7 (no Probe without a covering snoop; Probe addr/param
  match the snoop), F-CHI-8 (probe/release race determinism — each
  shared txrsp/txdat beat is exactly one engine's, no double-claim).
  Snoop "in flight" is derived from the DUT's own `rxsnp_ready`
  (=`sSnpIdle`) so the shadow can't desync from variable SnpRespData
  beat counts.  Cover goals added for Probe issued, SnpResp,
  SnpRespData, and snoop concurrent with acquire / release.

**Stage 5 limit — probe ↔ release race not collapsed.**  The original
plan called for the bridge to *collapse* a Probe that races a same-line
`Release` (drop the Probe, answer the snoop from the released state).
The implemented bridge instead keeps the snoop and release engines fully
independent: if a Release and a Probe for the same line are both in
flight, the TL master is expected to answer the Probe even though it just
issued the Release, and both transactions complete on their own.  F-CHI-8
proves the two engines never corrupt each other on the shared channels
and the cover goals show the both-in-flight window is reachable, but true
collapse (and the CHI §B2 ExpCompAck hazard interplay) is deferred.  This
is the documented behavior in `TLCToCHI.scala`'s Stage 5 header.

**Exit criteria met**
- `make sim-chi` PASS: 12 directed jobs (4 acquires + 4 releases + 4 snoops).
- `make formal-chi` BMC depth 20 PASS, all 11 cover goals reached
  (`chi` formal target now runs both `chi-bmc` and `chi-cover`, matching
  the ulite/uc variants).
- `make cocotb-chi` PASS: 3 tests.
- `make regress` PASS — TLUH 183 jobs, ULite 24, UC 11, CHI 12; all
  6 lint targets clean; no regression.

### ~~Stage 6 — Atomics, CMO, prefetch~~ ✓ DONE 2026-05-29

The TL-A uncached opcode space (Get/Put/Hint/Arithmetic/Logical), which
the bridge previously rejected, now flows through a fourth **uncached
engine** running in parallel with acquire/release/snoop.  Implemented in
one pass.

**Mapping (as landed)**
| TL-A | CHI REQ | flow |
|---|---|---|
| `Get`                | `ReadOnce` (0x03)           | → CompData → `AccessAckData` |
| `PutFullData`        | `WriteUniqueFull` (0x1B)    | → CompDBIDResp → NonCopyBackWrData → `AccessAck` |
| `PutPartialData`     | `WriteUniquePtl` (0x1A)     | (byte-enables from the TL mask) |
| `Hint(PrefetchRead)` | `CleanShared` (0x08)        | → Comp → `HintAck` (no data) |
| `Hint(PrefetchWrite)`| `CleanInvalid` (0x09)       | → Comp → `HintAck` (no data) |
| `ArithmeticData`     | `AtomicLoad{Add,Smin,Smax,Umin,Umax}` | → DBIDResp → NonCopyBackWrData(operand) → CompData(pre-op value) → `AccessAckData` |
| `LogicalData`        | `AtomicLoad{Eor,Set,Clr}` / `AtomicSwap` | AND→Clr with the operand inverted on the wire |

Decisions taken (the original draft left two open):
- **Prefetch = no-data CMO.**  Prefetch hints map to `CleanShared` /
  `CleanInvalid` (return only `Comp`), not `ReadOnce`/`PrefetchTgt` — the
  bridge never has to sink a prefetched line, and the TL master always
  gets a clean `HintAck`.
- **Atomics = AtomicLoad family.**  TileLink atomics always return the
  pre-op value, so they map to the CHI *Load* atomics (and `AtomicSwap`),
  never `AtomicStore`.  `AtomicCompare` is unused (TL has no CAS).  AND
  has no CHI form: it maps to `AtomicClr` with the operand bit-inverted
  on the wire (`Clr` computes `old & ~txdata`).

**Deliverables (all landed)**
- Uncached engine in `TLCToCHI.scala`: 7-state FSM
  (Idle → ACollect → REQ → WRsp → WData → Resp → DResp) with a line
  buffer for Put write-data and atomic operands.  TxnID partition
  extended to a 2-bit scheme (`{2'b01, source}` for uncached); txreq /
  txdat / rxrsp / rxdat / D arbitration all extended to the fourth engine
  with acquire/release-first priority.
- TB extension (`tb_chi.cpp`): HN models ReadOnce / WriteUnique* / CMO /
  Atomic flows (DBIDResp, NonCopyBackWrData collection, pre-op CompData);
  TL-A gains multi-beat write-data driving and AccessAckData collection.
  11 new directed jobs (Get×2, Put×2, Hint×2, Atomic×5 incl. AND-invert).
- Cocotb: `test_uncached_mixed` (Get/Put/Hint/Atomic-Add/Atomic-And).
- Formal: F-CHI-9 (uncached REQ opcode = documented map of the TL-A
  {opcode,param}), F-CHI-10 (NonCopyBackWrData only with a live uncached
  write/atomic), F-CHI-11 (AccessAck/AccessAckData/HintAck routing).
  F-CHI-1/4/5/8 extended for the new txnID partition and the
  NonCopyBackWrData txdat producer.  8 new cover goals.

**Stage 6 limits**
- Formal scopes TL-A to single-beat (`size ≤ beat`); the multi-beat Put
  line-buffer path is covered in sim/cocotb.
- error/`denied` is propagated only for Get/Atomic read-return, not for
  Put/Hint.
- no CAS (`AtomicCompare`), no `WriteUnique` CompAck ordering, no
  multi-line atomics (enforced single-beat).

**Exit criteria met**
- `make sim-chi` PASS: 23 directed jobs (4 acquire + 4 release + 4 snoop
  + 11 uncached/atomic).
- `make formal-chi` BMC depth 20 PASS, all 19 cover goals reached.
- `make cocotb-chi` PASS: 4 tests.
- `make regress` PASS — TLUH 183, ULite 24, UC 11, CHI 23; all 6 lints
  clean; no regression.

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

**Stages 1–6 landed 2026-05-29.**  Read path (Stages 1–3), release
path (Stage 4), snoop path (Stage 5), and uncached/atomic path
(Stage 6) all shipped the same day.  Four engines (acquire / release /
snoop / uncached) run in parallel.  TxnID is now a 2-bit partition
(`{2'b00,src}` acquire, `{2'b10,src}` release, `{2'b01,src}` uncached);
the snoop engine echoes the HN-chosen txnID.  Shared CHI channels are
arbitrated acquire/release-first; the TL D channel is acquire > release
> uncached.  F-CHI-1..11 hold at BMC depth 20 with 19 cover goals
reachable.

The four open questions in §2 were settled as follows:
1. **DCT/DMT:** off through Stage 6 — revisit only if a consumer needs it.
2. **CHI HN model:** hand-rolled from the spec.  TB and cocotb harness
   serve full Issue-E semantics for every opcode exercised (Read*,
   MakeUnique, Evict, WriteBack/Clean, Snp{Shared,Unique}, ReadOnce,
   WriteUnique*, CleanShared/Invalid, AtomicLoad*/Swap).
3. **Multi-line atomics:** disallowed — atomics are single-beat
   (`a.size ≤ beat`).
4. **Cache line:** pinned at 64 B.

**Next step is a separate go-ahead** to start Stage 7 (full verification
surface + CI parity: randomized sweep, BMC depth 30, coverage target,
`.github/workflows/ci.yml` chi job, ASSERTIONS.md §8 catalog).  Open
follow-ups carried forward:
- **Probe ↔ release collapse.**  Still not collapsed (Stage 5 limit);
  the engines complete independently.  Revisit if a real host needs it.
- **Snoop verification breadth.**  Remaining Snp* opcodes (SnpClean,
  SnpCleanInvalid, SnpMakeInvalid, SnpNotSharedDirty) are mapped and
  formal-legal but not yet directed-tested.
- **Stage 6 gaps.**  No CAS (`AtomicCompare`), no multi-beat Put in
  formal (sim/cocotb only), Put/Hint error not propagated to `denied`.
  Fold all into the Stage 7 sweep.
