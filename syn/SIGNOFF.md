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
| **T2** STA | ◐ collateral | `syn/constraints/tl_axi4.sdc`, `syn/sta/opensta.tcl` | Single clock; Chisel sync reset is a timed input. **Watch item:** atomic/arith cone depth ~125 — confirm timing on the target library. **sky130 open-PDK run:** `make pnr` (LibreLane on the Chisel-emitted SV, CI `silicon.yml`, 3 tops) → `syn/pnr/reports/<top>.pnr.rpt` — 9-corner STA against this SDC, DRC/LVS/antenna, area/power, Fmax; FAIL on flow/DRC/LVS/hold, setup reported (500 MHz placeholder — owner's call). **First CI result pending.** Commercial-node STA = `needs-pdk`. |
| **T3** low-power | ◐ authored + OSS-lint | `make lp` → `syn/lp/tl_axi4.upf`, `syn/lp/LP_PLAN.md` | Single always-on domain (protocol bridge, single clock, no gating partition); LP = clock gating (RTL/SDC), power gating is the integrator's call. UPF consistency lint PASS. |
| **T4** DFT | ◐ **PASS** (scan-ready) | `make dft` → `syn/dft/reports/`, `syn/dft/DFT_PLAN.md` | All 3 tops latch-free + no comb loops; 313/128/413 flops, **100% reset-controllable**, 0 async, 0 RAM — ideal for scan (single clock, no MBIST). Scan stitch + ATPG = `needs-license`. |
| **T5** verif sign-off | ◐ partial | 183-job directed + 95.1% line cov + SymbiYosys formal + cocotb | Documented coverage model; **coherence DV** (CHI agent + multi-core soak) once `TLCToCHI` lands; licensed-sim parity. |
| **T6** PPA + GLS | ◐ **PPA PASS**; GLS recipe (n/a for iverilog) | `make ppa` → `syn/ppa/reports/<top>.ppa.rpt`; `syn/gls/T6_PLAN.md` | **PPA proxy PASS** (per top, from the Chisel-generated SV): TLUHToAXI4 3191 cells/319 ff/depth 147; TLULToAXILite 303/130/58; TLUCToAXI4 4248/421/272. **GLS:** the kit's iverilog zero-delay GLS is **not applicable** — this block's self-checking TBs are C++ Verilator harnesses, not Verilog directed TBs, so no hollow `make gls` is wired (a skip ≠ pass). The correct OSS path (Verilate the netlist + reuse the C++ harness) is authored as a recipe in T6_PLAN.md. **Post-route GLS (sky130): n/a** — Verilator cannot simulate the sky130_fd_sc_hd cell models (UDP primitives) and there is no Verilog TB for iverilog; not run, not a pass. SDF GLS, Liberty map, real area/power/STA, RTL↔netlist LEC = `needs-pdk`. |
| **T7** integration/pkg | ◐ **PASS** (IP-XACT + guide, gated) | `make pkg` → `pkg/check_ipxact.sh`; `pkg/ip-xact/{TLUHToAXI4,TLULToAXILite,TLUCToAXI4}.xml`, `pkg/INTEGRATION.md` | IP-XACT (IEEE 1685-2014) components for the three bridge tops — `TL` + `AXI` bus interfaces (grouped by `io_` prefix) + `clock`, full model ports. `make pkg` elaborates Chisel→SV then gates well-formed + structural + **IP-XACT↔SV port-sync** (53/36/68; fails on drift). Integration guide + config notes in `pkg/INTEGRATION.md`. No CSR RAL: pure protocol bridges (address pass-through). Chisel-parameterized at elaboration (no runtime SV params). **Full XSD:** `make pkg-xsd` (IEEE 1685-2014 from Accellera → eda.org → pinned GitHub copy, SHA-256 pinned) → XSD valid. **Release flow:** `make release-check` (reproducible bundle: Scala source + emitted SV recorded `generated_by: make elab`, `MANIFEST.json`; CI dry run) and `.github/workflows/release.yml`; publishing is **blocked until T0** (pre-flight requires `contract-v1.0` + `doc/design_contract.md`). |

Legend: ✅ passed · ◑ authored-not-run · ◐ partial/pathfind · ☐ not started.
