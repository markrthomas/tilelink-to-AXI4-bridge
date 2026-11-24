# SIGNOFF.md — tilelink_to_AXI4 tapeout sign-off checklist

Tracks the eight T-gates from the workspace program (`../DESIGN_READINESS.md`). A gate
passes only with a cited **artifact** (*no artifact = not verified*); `needs-license` /
`needs-pdk` items are authored here and run where the tools/PDK exist.

**Design facts:** Chisel-generated RTL — sign-off is on the **emitted SystemVerilog**
(`make elab` → `generated/`). Single clock domain (`clock` + synchronous `reset`), no
CDC. Complete bridge tops: `TLUHToAXI4` (3191 cells / depth 125), `TLULToAXILite`
(303 / 16), `TLUCToAXI4` (4250 / 124) — all latch-free. `TLCToCHI` is **WIP**
(coherence stage 1/7) and excluded from the gate until it lands.

| Gate | Status | Artifact / where | Notes |
|------|--------|------------------|-------|
| **T0** spec freeze | ◐ open | `doc/PLAN.md` tapeout section | **Freeze generation** (pin Chisel/firtool, hash-check `make elab`, archive emitted SV as a tagged release artifact). Decide `TLCToCHI` coherence scope (finish stages 2–7, or freeze non-coherent). Cite TileLink / AXI4 / CHI-E clauses. |
| **T1** synthesizable | ◐ **PASS** | `make syn` → `sim/synth_*.v`, `sim/synth_*.log` | Yosys generic synth of the 3 complete tops; latch-free + cell/depth ceilings. Liberty-mapped synth = `needs-pdk`. |
| **T1-CDC** | n/a | — | Single clock domain; no crossings. |
| **T2** STA | ◐ collateral | `syn/constraints/tl_axi4.sdc`, `syn/sta/opensta.tcl` | Single clock; Chisel sync reset is a timed input. **Watch item:** atomic/arith cone depth ~125 — confirm timing on the target library. Run = `needs-pdk`. |
| **T3** low-power | ☐ open | `lp/` (to author) | UPF if gated domains; else document n/a. `needs-license`. |
| **T4** DFT | ☐ open | `dft/` (to author) | Scan over the parallel read/write/atomic engines; RAM MBIST; ATPG. `needs-license`. |
| **T5** verif sign-off | ◐ partial | 183-job directed + 95.1% line cov + SymbiYosys formal + cocotb | Documented coverage model; **coherence DV** (CHI agent + multi-core soak) once `TLCToCHI` lands; licensed-sim parity. |
| **T6** GLS + PPA | ☐ open | — | SDF GLS, power, RTL↔netlist LEC, PPA. `needs-pdk`. |
| **T7** integration/pkg | ☐ open | `pkg/` (to author) | Target a real interconnect top (Chipyard/Rocket); diplomacy params; IP-XACT / Chisel-package deliverable. |

Legend: ✅ passed · ◑ authored-not-run · ◐ partial/pathfind · ☐ not started.
