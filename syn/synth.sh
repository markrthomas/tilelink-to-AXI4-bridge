#!/usr/bin/env bash
# syn/synth.sh — T1 synthesizability gate for the TileLink->AXI4 bridges (Chisel).
#
# Sign-off is on the EMITTED SystemVerilog: this runs `make elab` if needed, then
# Yosys-synthesizes each COMPLETE bridge top (TLUHToAXI4, TLULToAXILite, TLUCToAXI4),
# asserting latch-free and reporting cells / logic-depth against generous ceilings.
# TLCToCHI is excluded (coherence is WIP — only stage 1/7; include once it lands).
# Part of the tapeout-readiness program — see syn/SIGNOFF.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"; cd "$ROOT"
SYNTH_MAX_CELLS="${SYNTH_MAX_CELLS:-6000}"   # largest today ~4250 (TLUCToAXI4)
SYNTH_MAX_DEPTH="${SYNTH_MAX_DEPTH:-180}"    # deepest today ~125 (atomic/arith cone)
command -v yosys >/dev/null || { echo "[SYNTH] yosys not on PATH; SKIP"; exit 0; }

# Tops -> emitted SV (reproducible via `make elab`; the SV is a build artifact).
declare -A SV=( [TLUHToAXI4]=generated/TLUHToAXI4.sv \
                [TLULToAXILite]=generated/ulite/TLULToAXILite.sv \
                [TLUCToAXI4]=generated/uc/TLUCToAXI4.sv )
[ -f generated/TLUHToAXI4.sv ] || { echo "[SYNTH] elaborating Chisel -> SV..."; make elab >/dev/null; }

mkdir -p sim; rc=0
for TOP in "${!SV[@]}"; do
  f="${SV[$TOP]}"
  yosys -p "read_verilog -sv $f; synth -top $TOP -flatten; stat; ltp -noff; \
            write_verilog sim/synth_$TOP.v" > "sim/synth_$TOP.log" 2>&1
  if grep -qE '\$_DLATCH' "sim/synth_$TOP.log"; then echo "[SYNTH] $TOP FAIL: inferred latch!"; rc=1; continue; fi
  c=$(grep -oE '[0-9]+ cells$' "sim/synth_$TOP.log" | tail -1 | grep -oE '[0-9]+' || true)
  d=$(grep -oE 'length=[0-9]+' "sim/synth_$TOP.log" | tail -1 | grep -oE '[0-9]+' || true)
  st="PASS"
  { [ -n "$c" ] && [ "$c" -gt "$SYNTH_MAX_CELLS" ]; } && { st="FAIL(cells>$SYNTH_MAX_CELLS)"; rc=1; }
  { [ -n "$d" ] && [ "$d" -gt "$SYNTH_MAX_DEPTH" ]; } && { st="FAIL(depth>$SYNTH_MAX_DEPTH)"; rc=1; }
  echo "[SYNTH] $TOP: latch-free, cells=${c:-?} depth=${d:-?} -> $st"
done
[ "$rc" -eq 0 ] && echo "[SYNTH] T1 synthesizability gate PASSED (generated SV)."
exit $rc
