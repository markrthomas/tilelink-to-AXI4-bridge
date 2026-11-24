# LP_PLAN.md — TileLink->AXI4 bridges low-power (T3)

Low-power intent for the tapeout-readiness program (`../../DESIGN_READINESS.md`). Adopted
from the sign-off kit's low-power template, tuned honestly to what this block is.

Two layers (program doctrine — *no artifact = not verified*):

1. **UPF consistency lint — OSS, runs here now** (`make lp` → `upf_lint.tcl tl_axi4.upf`).
   Current result: **PASS** (1 always-on domain, 1 PST state).
2. **Power-aware simulation + LEC — `needs-license`** (VCS `-upf`; Conformal/Formality
   RTL↔UPF LEC). For this block the semantics are trivial (single always-on domain); the
   licensed run is a formality that confirms no isolation/retention is missing.

## Power architecture — why a single domain

Unlike the memory-facing bridges in this program (DFI/DDR self-refresh, LPDDR5X low-power,
PCIe PIPE link states), a TileLink→AXI4 **protocol bridge** has **no internal power-gating
partition**:

- **Single clock** (`clock`) — there is no second clock domain to gate independently.
- **Combinational-dominant, low latency** — the datapath is a near-single-cycle translate;
  no sub-block is idle long enough, or isolated enough, to justify a switchable rail with
  its own isolation/retention boundary.
- **No memory macro** — nothing to retain across a power cycle.

So the honest T3 architecture is **one always-on domain** (`PD_CORE`). The block's real
low-power mechanism is **fine-grained clock gating**, which is expressed in RTL / SDC, not in
UPF — Chisel emits gated-enable registers, and synthesis inserts ICGs. Power *gating* of the
whole bridge, if wanted, is the **SoC integrator's** decision at the parent (gate the instance
when the TileLink side is quiescent); this UPF is the contract that says there is no gating
*inside* the IP. Inventing a switchable sub-domain here would be fiction, not sign-off.

## Power states

| Mode | VDD | Meaning |
|------|-----|---------|
| **P0 on** | ON | the only mode — always-on; low power via clock gating |

## Exit criteria (T3)

- UPF consistency lint PASS (here now).
- VCS `-upf` confirms the single-domain intent and that no isolation/retention is required
  (needs-license — expected trivial).
- Clock-gating coverage (ICG insertion / enable efficiency) is measured at T6/PPA on the
  mapped netlist, not here.
