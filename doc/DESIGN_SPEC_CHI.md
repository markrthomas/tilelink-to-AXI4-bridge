# TileLink-C → CHI Issue-E Bridge — Design Specification

This document defines the contract of the `TLCToCHI` bridge: signal
interfaces, opcode/permission mapping, transaction flows, ordering
rules, and the staged implementation status.  The Chisel source
(`src/main/scala/tlbridge/TLCToCHI.scala` + `CHIBundles.scala`) is the
implementation; this spec is the reference behavior.

**Status:** Stage 1 of `doc/CHI_PLAN.md` — module skeleton (all
channels wired, every output tied off) plus this mapping document.
Stage 2 onward will land functional behavior.

The TL side of this bridge reuses the bundles from the
[TL-UC bridge](DESIGN_SPEC_UC.md) (`TLUCSlaveIO` over `TLAChannel` /
`TLBChannel` / `TLCChannel` / `TLDChannel` / `TLEChannel`).  The new
work in this bridge is the **CHI side** plus the coherence semantics.

## 1. Role and topology

The bridge plays the **CHI RN-F** (Request Node, Fully coherent) role:
it sits at the boundary between a TL-C master upstream (e.g., a Rocket
or BOOM tile with an inclusive L1) and a CHI fabric downstream (e.g.,
an Arm-style coherent interconnect with a Home Node fronting memory).

```
            TL-C (A/B/C/D/E)              CHI Issue-E (REQ/RSP/DAT/SNP)
+---------+ ------------------> +-----------+ ------------------> +----------+
|  TL-C   |     A (req)         |           |    txreq            |   CHI    |
|  HOST   |  <----------------- |  TLCToCHI |  <----------------- | HOME NODE|
| (cached |     B (probe)       |   (RN-F)  |    rxsnp            |   (HN)   |
|  RN-F)  | ------------------> |           | ------------------> |          |
|         |     C (release)     |           |    txrsp            |          |
|         |  <----------------- |           |  <----------------- |          |
|         |     D (resp)        |           |    rxrsp / rxdat    |          |
|         | ------------------> |           | ------------------> |          |
|         |     E (grant-ack)   |           |    txdat            |          |
+---------+                     +-----------+                     +----------+
```

Stage 1 scope:
- **Single TL-C master upstream**, single HN downstream.  Multi-master
  is out of scope forever.
- **No DCT / DMT** advertisement.  The HN always sources data; no
  direct cache-to-cache or memory-to-RN paths.
- **Cache line pinned at 64 B**; data path 64-bit; 8 beats per line.
- **Atomics restricted to single cache line** (CHI Issue-E baseline).
- **MTE / RAS / DVM / persistent CMO** all out of scope for Stage 1–7.

## 2. Parameters

`CHIBridgeParams` (`src/main/scala/tlbridge/CHIBundles.scala`):

| Parameter | Default | Notes |
|-----------|---------|-------|
| `addrBits` | 48 | CHI Issue-E permits 32–52 |
| `dataBits` | 64 | Pinned at 64 for RN-F baseline |
| `lineBytes` | 64 | Pinned for Stage 1; widens with the snoop path |
| `txnIDBits` | 8 | Standard Issue-E width |
| `nodeIDBits` | 7 | NodeID space ≤ 128 |
| `sourceBits` | 4 | TL-C `a.source` / `c.source` / `d.source` |
| `sizeBits` | 6 | TL-C `a.size` envelope (64 B max) |

Derived: `beatBytes=8`, `beatsPerLine=8`, `dataIDBits=3`, `sizeFld=3`.

Sideband fields (memAttr, allowRetry, expCompAck, etc.) are present in
the bundles but Stage 1 ties them to zero / off.  Stage 2 will start
driving the ones the read-shared path needs (`expCompAck=1`,
`memAttr=NormalNC`, `order=0`).

## 3. Coherence-state mapping

| TL-C | CHI | Notes |
|------|-----|-------|
| **N** (None) | **I** (Invalid) | Cache miss / post-Release |
| **B** (Branch / Shared) | **SC** (Shared Clean) | TL-B host can read |
| **B** with dirty | **SD** (Shared Dirty) | Bridge collapses SD → SC on Grant — host is told "clean" and the bridge writes back any dirty data eagerly.  This avoids carrying SD up into TL semantics where it has no equivalent |
| **T** (Tip / Modified) | **UC** (Unique Clean) | Permission only |
| **T** with dirty | **UD** (Unique Dirty) | Bridge tracks the PassDirty bit |

The `D.param` field on `Grant`/`GrantData` carries:

| D.param | Meaning | When emitted |
|---------|---------|--------------|
| `toT` (0) | Master now holds T | Bridge granted U (UC/UD) — typical for AcquireBlock(NtoT/BtoT) and AcquirePerm |
| `toB` (1) | Master now holds B | Bridge granted SC — typical for AcquireBlock(NtoB) |
| `toN` (2) | Permission denied | Bridge couldn't satisfy — used only with `denied=1` |

## 4. Opcode mapping

### 4.1 TL A-channel → CHI REQ

| TL A opcode | TL A.param | CHI REQ opcode | Notes |
|-------------|------------|----------------|-------|
| `AcquireBlock` | `NtoB` (0) | `ReadShared` (0x01) | Stage 2 |
| `AcquireBlock` | `NtoT` (1) | `ReadUnique` (0x07) | Stage 3 |
| `AcquireBlock` | `BtoT` (2) | `ReadUnique` (0x07) | Stage 3 — upgrade with data refetch |
| `AcquirePerm` | `NtoT` (1) | `MakeUnique` (0x0C) | Stage 3 — perm only, no data |
| `AcquirePerm` | `BtoT` (2) | `MakeUnique` (0x0C) | Stage 3 — perm upgrade |
| `Get` (4) | n/a | `ReadOnce` (0x03) | Stage 6 — non-allocating read |
| `PutFullData` (0) | n/a | `WriteUniqueFull` (0x1B) | Stage 6 — non-allocating write |
| `PutPartialData` (1) | n/a | `WriteUniquePtl` (0x1A) | Stage 6 |
| `Hint` (5) | `PrefetchRead` | `ReadOnce` w/ memAttr=cacheable | Stage 6 |
| `Hint` (5) | `PrefetchWrite` | `CleanInvalid` (0x09) | Stage 6 |
| `ArithmeticData` (2) | ADD/MIN/MAX/.. | `AtomicLoad_*` or `AtomicStore_*` (0x20+) | Stage 6 |
| `LogicalData` (3) | XOR/OR/AND/SWAP | `AtomicLoad_*` (XOR/OR/AND) or `AtomicSwap` | Stage 6 |

All requests carry `expCompAck=1` so the HN waits for our CompAck before
de-allocating its tracker.

### 4.2 TL C-channel → CHI REQ (releases as writes)

| TL C opcode | TL C.param | CHI REQ opcode | Notes |
|-------------|------------|----------------|-------|
| `Release` | `TtoB` (0) | `WriteCleanFull` (0x19) | Stage 4 — drop to shared, no data needed if not dirty |
| `Release` | `TtoN` (1) | `Evict` (0x0D) | Stage 4 — clean drop |
| `Release` | `BtoN` (2) | `Evict` (0x0D) | Stage 4 |
| `ReleaseData` | `TtoB` | `WriteCleanFull` (0x19) | Stage 4 — clean writeback |
| `ReleaseData` | `TtoN` | `WriteBackFull` (0x1D) | Stage 4 — dirty writeback + drop |

### 4.3 CHI SNP → TL B-channel (probes)

| CHI SNP opcode | TL B opcode | TL B.param | Notes |
|----------------|-------------|------------|-------|
| `SnpShared` (0x01) | `Probe` | `toB` (1) | Stage 5 — demote to shared |
| `SnpNotSharedDirty` (0x04) | `Probe` | `toB` | Stage 5 — host may keep shared but must report dirty |
| `SnpClean` (0x02) | `Probe` | `toB` | Stage 5 — clean any dirty data, keep shared |
| `SnpOnce` (0x03) | `Probe` | `toB` (1) | Stage 5 — as-built issues a conservative `toB` probe (over-demotes; the ideal no-demotion `toT` mapping is a follow-up).  Not in the verified opcode set yet. |
| `SnpUnique` (0x07) | `Probe` | `toN` (2) | Stage 5 — invalidate |
| `SnpCleanInvalid` (0x09) | `Probe` | `toN` | Stage 5 — invalidate after clean |
| `SnpMakeInvalid` (0x0A) | `Probe` | `toN` | Stage 5 — invalidate, no data |

### 4.4 TL C-channel probe-acks → CHI RSP / DAT

| TL C opcode | TL C.param | CHI response | Notes |
|-------------|------------|--------------|-------|
| `ProbeAck` (4) | `TtoB` / `TtoN` / `BtoN` / `TtoT` / etc. | `SnpResp` (RSP 0x01) | Stage 5 — no data |
| `ProbeAckData` (5) | `TtoB` / `TtoN` | `SnpRespData` (DAT 0x01) | Stage 5 — with data, full line |

`SnpResp.resp[2:0]` and `SnpRespData.resp[2:0]` encode the cache state
the master holds after the snoop:

| Final state | resp[2:0] |
|-------------|-----------|
| I | `0b000` (I) |
| SC | `0b001` (SC) |
| UC | `0b010` (UC) |
| SD | `0b101` (SC + PassDirty) |
| UD | `0b110` (UC + PassDirty) |

### 4.5 CHI RSP / DAT → TL D-channel

| CHI source | TL D opcode | TL D.param | Notes |
|------------|-------------|------------|-------|
| RSP `Comp` (0x04) for ReadShared/ReadUnique | `Grant` (4) | `toT` / `toB` per resp | Stage 2/3 |
| DAT `CompData` (0x04) | `GrantData` (5) | per CHI resp[2:0] | Stage 2/3 — multi-beat |
| DAT `DataSepResp` (0x0B) | `GrantData` (5) | per CHI resp[2:0] | Stage 2/3 — alternative DAT-only flow |
| RSP `RetryAck` (0x03) | *(internal retry; not forwarded)* | — | Stage 2 — bridge retries with PCrdGrant |
| RSP `Comp` for WriteBack/WriteClean/Evict | `ReleaseAck` (6) | 0 | Stage 4 |
| RSP `CompDBIDResp` (0x05) | *(internal — triggers DAT write)* | — | Stage 4 |
| RSP `DBIDResp` (0x06) | *(internal — splits CompDBID flow)* | — | Stage 4 |

### 4.6 TL E-channel → CHI RSP

| TL E | CHI response | Notes |
|------|--------------|-------|
| `GrantAck` | `CompAck` (RSP 0x02) | Stage 2 — closes the acquire flow |

CompAck is sent unconditionally after every Grant/GrantData since the
bridge requests `expCompAck=1` on every read transaction.

## 5. Channel signal tables

### 5.1 TL-C side (reuses TL-UC bundles)

The TL-C side reuses the bundles from `Bundles.scala` — see
[`DESIGN_SPEC_UC.md`](DESIGN_SPEC_UC.md) §"TileLink-C interface" for
the signal tables.  The only differences:
- Address width is 48 bits (vs. 32 for the AXI4 bridges).
- `D.sink` width is still 1 bit (single acquire slot in Stage 1; Stage 7
  may widen as the bridge gains multi-outstanding capacity).

### 5.2 CHI REQ (RN → HN)

| Signal | Width (default) | Notes |
|--------|-----------------|-------|
| `valid` / `ready` | 1 / 1 | Standard CHI handshake |
| `qos` | 4 | Quality of service hint |
| `tgtID` | 7 | Target node (HN's NodeID) |
| `srcID` | 7 | Source node (this RN's NodeID) |
| `txnID` | 8 | Transaction ID — must be unique within the RN's outstanding pool |
| `returnNID` | 7 | Used with DMT (Stage 5+) |
| `returnTxnID` | 8 | Used with DMT (Stage 5+) |
| `opcode` | 7 | See §4 |
| `size` | 3 | log2(transaction bytes); 6 for full line |
| `addr` | 48 | Byte address |
| `ns` | 1 | Non-secure |
| `likelyShared` | 1 | Hint to HN |
| `allowRetry` | 1 | If 0, HN must not return RetryAck |
| `order` | 2 | 0 = no ordering; bridge uses 0 for Stage 2 |
| `pCrdType` | 4 | For PCrdReturn flow |
| `memAttr` | 4 | NormalNC / Device / etc. — Stage 2 uses NormalNC for ReadShared |
| `snpAttr` | 1 | 1 = snoopable (cacheable) — Stage 2+ sets to 1 |
| `lpID` | 5 | Logical processor ID |
| `excl` | 1 | Exclusive access — Stage 6 for atomics |
| `expCompAck` | 1 | 1 = HN must send Comp and wait for CompAck.  Always 1 for Acquire flows |
| `traceTag` | 1 | Debug |

### 5.3 CHI RSP

Same bundle in both directions (tx and rx are separate Decoupled ports).

| Signal | Width (default) | Notes |
|--------|-----------------|-------|
| `valid` / `ready` | 1 / 1 | Standard handshake |
| `qos` | 4 | |
| `tgtID` | 7 | |
| `srcID` | 7 | |
| `txnID` | 8 | Echoes the matching request's txnID |
| `opcode` | 5 | See §4 |
| `respErr` | 2 | 0 = OK, 1 = exclusive failed, 2 = data error, 3 = non-data error |
| `resp` | 3 | Cache state code (see §3) for responses carrying state |
| `fwdState` | 3 | For DCT (off in Stage 1) |
| `cBusy` | 3 | Congestion hint |
| `dbID` | 8 | Used in CompDBIDResp / DBIDResp flows |
| `pCrdType` | 4 | |
| `traceTag` | 1 | |

### 5.4 CHI DAT

| Signal | Width (default) | Notes |
|--------|-----------------|-------|
| `valid` / `ready` | 1 / 1 | |
| `qos` | 4 | |
| `tgtID` | 7 | |
| `srcID` | 7 | |
| `txnID` | 8 | |
| `homeNID` | 7 | Required on writebacks |
| `opcode` | 4 | See §4 |
| `respErr` | 2 | |
| `resp` | 3 | Cache state |
| `fwdState` | 3 | DCT (off) |
| `cBusy` | 3 | |
| `dbID` | 8 | |
| `ccID` | 2 | Critical chunk |
| `dataID` | 3 | Which beat of the line (0..7) |
| `tagOp` | 2 | MTE — Stage 1 ties to 0 |
| `tag` | 1 | MTE — tied to 0 |
| `tu` | 1 | MTE — tied to 0 |
| `be` | 8 | Byte enables |
| `data` | 64 | Beat payload |
| `dataCheck` | 8 | Optional parity — tied to 0 |
| `poison` | 1 | RAS poison — tied to 0 |
| `traceTag` | 1 | |

### 5.5 CHI SNP

| Signal | Width (default) | Notes |
|--------|-----------------|-------|
| `valid` / `ready` | 1 / 1 | |
| `qos` | 4 | |
| `srcID` | 7 | |
| `txnID` | 8 | Snoop's own txnID; bridge echoes in SnpResp |
| `fwdNID` | 7 | For DCT-fwd snoops (off) |
| `fwdTxnID` | 8 | For DCT-fwd snoops (off) |
| `opcode` | 5 | See §4 |
| `addr` | 45 | Line-aligned: low 3 bits implicit zero |
| `ns` | 1 | |
| `doNotGoToSD` | 1 | If 1, master must not end in SD |
| `retToSrc` | 1 | If 1, must return data on SnpRespData |
| `traceTag` | 1 | |

## 6. Transaction flows

### 6.1 AcquireBlock(NtoB) — Stage 2

```
TL master                Bridge                  CHI HN
   |                       |                       |
   |  A: AcquireBlock(NtoB)|                       |
   |  size=6, source=S     |                       |
   |---------------------->|                       |
   |                       |  REQ: ReadShared      |
   |                       |  txnID=T, srcID=RN    |
   |                       |  expCompAck=1         |
   |                       |---------------------->|
   |                       |                       |
   |                       |  DAT: CompData(SC)    |
   |                       |  txnID=T, dataID=0    |
   |                       |<----------------------|
   |  D: GrantData(toB)    |                       |
   |  source=S, sink=0     |                       |
   |  beat 0..7            |                       |
   |<----------------------|                       |
   |                       |  ... 7 more DAT beats |
   |                       |<----------------------|
   |  ... 7 more D beats   |                       |
   |<----------------------|                       |
   |                       |                       |
   |  E: GrantAck(sink=0)  |                       |
   |---------------------->|                       |
   |                       |  RSP: CompAck         |
   |                       |  txnID=T, srcID=RN    |
   |                       |---------------------->|
```

CHI Issue-E permits the data path to use `DataSepResp + Comp` instead
of `CompData` for the response.  Bridge accepts both; the resp[2:0]
state on the data beats determines `D.param`.

### 6.2 AcquirePerm(NtoT) — Stage 3

```
TL master                Bridge                  CHI HN
   |  A: AcquirePerm(NtoT) |                       |
   |---------------------->|                       |
   |                       |  REQ: MakeUnique      |
   |                       |  size=6 (line), no data |
   |                       |---------------------->|
   |                       |                       |
   |                       |  RSP: Comp(UC)        |
   |                       |<----------------------|
   |  D: Grant(toT)        |                       |
   |<----------------------|                       |
   |  E: GrantAck          |                       |
   |---------------------->|                       |
   |                       |  RSP: CompAck         |
   |                       |---------------------->|
```

### 6.3 ReleaseData(TtoN) dirty writeback — Stage 4

```
TL master                Bridge                  CHI HN
   |  C: ReleaseData(TtoN) |                       |
   |  beat 0..7            |                       |
   |---------------------->|                       |
   |                       |  REQ: WriteBackFull   |
   |                       |---------------------->|
   |                       |                       |
   |                       |  RSP: CompDBIDResp    |
   |                       |  dbID=D               |
   |                       |<----------------------|
   |                       |  DAT: CopyBackWrData  |
   |                       |  txnID=D, dataID=0..7 |
   |                       |---------------------->|
   |  D: ReleaseAck        |                       |
   |<----------------------|                       |
```

The bridge MUST wait for `CompDBIDResp` (or `DBIDResp` if the HN
splits the flow) before sending data, because `dbID` is required on
`CopyBackWrData` and is allocated by the HN.

### 6.4 SnpShared with dirty data — Stage 5

```
TL master                Bridge                  CHI HN
   |                       |  SNP: SnpShared       |
   |                       |  addr=A, txnID=Tsnp   |
   |                       |<----------------------|
   |  B: Probe(toB,addr=A) |                       |
   |<----------------------|                       |
   |  C: ProbeAckData(TtoB,|                       |
   |     beat 0..7)        |                       |
   |---------------------->|                       |
   |                       |  DAT: SnpRespData     |
   |                       |  resp=SD, beat 0..7   |
   |                       |---------------------->|
```

The Probe ↔ Release race is the canonical TL-C deadlock pit: the host
may issue a `Release` for the same line just before the bridge
dispatches a `Probe`.  **As built (Stage 5), the bridge does not
collapse this race.**  The snoop and release engines stay fully
independent: the TL master is expected to answer the Probe even though
it just issued the Release, and both transactions complete on their own.
`F-CHI-8` proves the two engines never corrupt each other on the shared
`txrsp`/`txdat` channels (each beat is sourced by exactly one engine),
and the cover goals show the both-in-flight window is reachable.  True
*collapse* (drop the Probe, answer the snoop from the released state)
plus the CHI §B2 ExpCompAck hazard interplay is deferred — see the
Stage 5 limit in `doc/CHI_PLAN.md` and the `TLCToCHI.scala` header.

## 7. Ordering rules (CHI §B applied)

Per the Stage 1 baseline:
- `order = 0` on all REQs — no read ordering across transactions.
- `allowRetry = 1` on all REQs.  Bridge handles `RetryAck` by waiting
  for a matching `PCrdGrant` and re-issuing.
- `expCompAck = 1` on read REQs — HN keeps the tracker until CompAck.
- Snoops are unordered with respect to ongoing reads/writes.  The
  bridge does **not** collapse Probe ↔ Release races (Stage 5 limit);
  the snoop and release engines complete independently — see §6.4.
- For writeback flows, the bridge sends `CopyBackWrData` only after
  receiving `CompDBIDResp` / `DBIDResp` to allocate the `dbID`.

## 8. Stage status

| Stage | Scope | Status |
|-------|-------|--------|
| 1 | Mapping doc + skeleton + Makefile/lint slot | **✓ DONE 2026-05-28** |
| 2 | AcquireBlock(NtoB) → ReadShared → CompData → GrantData → GrantAck → CompAck | **✓ DONE 2026-05-29** |
| 3 | AcquireBlock(NtoT/BtoT) → ReadUnique / MakeUnique; AcquirePerm | **✓ DONE 2026-05-29** |
| 4 | Release / ReleaseData → WriteBack* / WriteClean* / Evict | **✓ DONE 2026-05-29** |
| 5 | SnpShared / SnpUnique → Probe → ProbeAck(Data) → SnpResp(Data) (probe ↔ release race *not* collapsed — see §6.4) | **✓ DONE 2026-05-29** |
| 6 | Atomic ops, CMO, prefetch | not started |
| 7 | Randomized sweep + BMC@30 + 90%+ coverage + CI parity | not started |

See [`doc/CHI_PLAN.md`](CHI_PLAN.md) for the per-stage deliverables and
exit criteria.

## 9. Limitations (Stage 1)

> **Historical:** this section describes the original Stage 1 skeleton.
> Stages 2–5 have since landed (see §8), so all of the tie-offs below are
> now driven functionally for the read, release, and snoop paths.  Kept
> as the record of the interface-locking milestone.

The skeleton has all channels wired but no functional behavior:
- `io_tl_a_ready` = 0 (no TL-A requests accepted)
- `io_tl_b_valid` = 0 (no probes issued — Stage 5 will drive)
- `io_tl_c_ready` = 0 (no C-channel acceptance)
- `io_tl_d_valid` = 0 (no D responses)
- `io_tl_e_ready` = 0 (no E acceptance)
- All `io_chi_tx*_valid` = 0
- All `io_chi_rx*_ready` = 0

This is intentional — Stage 1's goal is to lock the **interface shape**
so Stage 2+ can build functional logic without ABI churn.

## 10. References

- Arm IHI 0050E — *AMBA CHI Architecture Specification, Issue E* (or a
  later issue carrying the same opcode encodings).
- TileLink Specification §6 (TL-C cached profile) — channels, opcodes,
  permission semantics.
- `doc/CHI_PLAN.md` — staged roadmap and effort estimates.
- `doc/DESIGN_SPEC_UC.md` — sibling TL-UC bridge whose channel
  plumbing this bridge reuses.
- `doc/ASSERTIONS.md` — property catalog (Stage 7 will append §9 for
  the CHI bridge).
