#!/usr/bin/env bash
# ppa.sh — T6 PPA (power/performance/area) proxy baseline (OSS, Yosys).
#
# Adopted from the shared sign-off kit (dv-swarm-kit/templates/signoff/ppa), tuned for
# this repo: the bridge tops are Chisel-elaborated SystemVerilog, one self-contained
# generated .sv per top (same per-top SV map as syn/synth.sh), so this iterates that map
# rather than a single flat RTL list. Real PPA needs a PDK (standard-cell Liberty + P&R) —
# that is needs-pdk (see PPA_PLAN.md). What runs HERE, no PDK, is a technology-independent
# proxy baseline that is a real, tracked artifact and moves monotonically with the real
# numbers:
#   - AREA proxy  = generic cell count + flop count (post-synth, flattened).
#   - TIMING proxy= longest topological logic path (`ltp`), i.e. combinational depth.
#   - POWER proxy = flop count (switching surface) — informational.
set -euo pipefail

# --- adopted defaults for tilelink_to_AXI4 (per-top generated SV; override via env) ---
declare -A SV=( [TLUHToAXI4]=generated/TLUHToAXI4.sv
                [TLULToAXILite]=generated/ulite/TLULToAXILite.sv
                [TLUCToAXI4]=generated/uc/TLUCToAXI4.sv )
TOPS="${TOPS:-TLUHToAXI4 TLULToAXILite TLUCToAXI4}"   # TLCToCHI excluded (coherence WIP), as in syn/synth.sh
OUT="${OUT:-syn/ppa/reports}"; mkdir -p "$OUT"

command -v yosys >/dev/null || { echo "[PPA] yosys not on PATH — SKIP"; exit 0; }
# Elaborate Chisel -> SV if the generated sources are missing (same as syn/synth.sh).
[ -f generated/TLUHToAXI4.sv ] || { echo "[PPA] elaborating Chisel -> SV..."; make elab >/dev/null; }

rc=0
for TOP in $TOPS; do
  echo "[PPA] === $TOP ==="
  rfile="${SV[$TOP]:-}"
  [ -n "$rfile" ] && [ -f "$rfile" ] || { echo "[PPA] $TOP: FAIL — no generated SV ($rfile)"; rc=1; continue; }
  log="$OUT/$TOP.ppa.log"; rpt="$OUT/$TOP.ppa.rpt"
  if ! yosys -q -l "$log" -p "
      read_verilog -sv $rfile
      hierarchy -check -top $TOP
      proc
      synth -top $TOP -flatten
      tee -o $OUT/$TOP.ppa.stat.txt stat
      tee -o $OUT/$TOP.ppa.ltp.txt ltp
  "; then
    echo "[PPA] $TOP: FAIL — synthesis error (see $log)"; rc=1; continue
  fi
  cells=$( (grep -oE '[0-9]+ +cells' "$OUT/$TOP.ppa.stat.txt" || true) | tail -1 | grep -oE '[0-9]+' || echo "?")
  flops=$( (grep -oE '[0-9]+ +\$_(S?DFF|DLATCH)[A-Z0-9_]*' "$OUT/$TOP.ppa.stat.txt" || true) | awk '{s+=$1} END{print s+0}')
  depth=$( (grep -oiE 'length=[0-9]+' "$OUT/$TOP.ppa.ltp.txt" || true) | tail -1 | grep -oE '[0-9]+' || echo "?")
  {
    echo "# $TOP — PPA proxy baseline (T6, OSS technology-independent)"
    echo "# generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "  AREA proxy   — generic cells ........ ${cells}"
    echo "  AREA proxy   — flip-flops ........... ${flops}"
    echo "  TIMING proxy — logic depth (ltp) .... ${depth}"
    echo "  real PPA (ns / mW / um^2) ........... needs-pdk (see PPA_PLAN.md)"
  } > "$rpt"
  echo "[PPA] $TOP: cells=${cells} flops=${flops} logic-depth=${depth} (report: $rpt)"
done
[ $rc -eq 0 ] && echo "[PPA] T6 PPA proxy baseline emitted (OSS; real node PPA = needs-pdk)."
exit $rc
