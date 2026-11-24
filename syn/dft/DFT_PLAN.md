# DFT_PLAN.md — TileLink->AXI4 bridges DFT (T4)

DFT intent for the tapeout-readiness program (`../../DESIGN_READINESS.md`). Adopted from the
sign-off kit's DFT template. Like `syn/synth.sh`, sign-off is on the EMITTED SystemVerilog,
audited per complete bridge top. TLCToCHI is excluded (coherence WIP — only stage 1/7).

Two layers (program doctrine — *no artifact = not verified*):

1. **Scan-readiness audit — OSS, runs here now** (`make dft` → `scan_readiness.sh`).
   On the synthesized netlist of each top, asserts the structural conditions that must hold
   *before* scan insertion, and inventories the flops. Current result: **PASS** on all three.
2. **Scan insertion + ATPG — `needs-license`** (DFT Compiler / Tessent scan stitch; TestMAX
   / Tessent ATPG) on the PDK-mapped netlist. Authored here as the recipe.

## Scan-readiness result (per top)

| Top | flip-flops | reset-controllable | async set/reset | D-latches | comb loops | RAM |
|-----|-----------:|-------------------:|----------------:|----------:|-----------:|----:|
| **TLUHToAXI4**   | 313 | 100% | 0 | 0 | 0 | 0 |
| **TLULToAXILite**| 128 | 100% | 0 | 0 | 0 | 0 |
| **TLUCToAXI4**   | 413 | 100% | 0 | 0 | 0 | 0 |

These are near-ideal for scan: **single clock**, **100% reset-controllable** (the Chisel
emit resets every register synchronously), **no async set/reset**, **no latches**, **no RAM
macro**. That means one scan regime per top, no scan-reset-gating complication, no lock-up
latches (single clock domain), and no MBIST.

## Scan insertion + ATPG recipe (needs-license)

1. **Scan stitch** (DFT Compiler / Tessent) on the Liberty-mapped netlist (T6/`needs-pdk`):
   - `set_scan_configuration -style multiplexed_flip_flop`
   - a single clock-grouped chain per top (balance length across N chains for test time).
2. **Scan reset gating**: not required (reset is synchronous and already controllable; the
   `scan_enable` path stays clean).
3. **ATPG** (TestMAX / Tessent): stuck-at + transition; target ≥99% test coverage. With a
   single clock and full reset controllability, high coverage is expected without special
   constraints.
4. **MBIST**: none (no RAM macro in any top).

> If `make elab` output changes the register count materially, re-run `make dft`; the
> numbers above are regenerated into `syn/dft/reports/` on every run.

## Exit criteria (T4)

- Scan-readiness audit PASS on all shipped tops (here now).
- Scan chains stitched, DRC-clean (needs-license); ATPG coverage ≥99% stuck-at per top.
- TLCToCHI added to the audit once coherence lands.
