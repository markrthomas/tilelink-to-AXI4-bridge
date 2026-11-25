# PPA plan (tilelink_to_AXI4)

PPA is part of the T6 sign-off. The full plan — what runs OSS here (`make ppa`) and what is
deferred (`needs-pdk`), plus why the iverilog GLS gate is not applicable to this
Chisel/C++-TB block (and the authored Verilator-netlist GLS recipe) — lives in
[`../gls/T6_PLAN.md`](../gls/T6_PLAN.md).

`make ppa` emits, per top (`syn/ppa/reports/<top>.ppa.rpt`), from the Chisel-generated SV:
- **area proxy** — generic cell count + flip-flop count (post-synth, flattened);
- **timing proxy** — longest topological logic path (`ltp`), i.e. combinational depth.

Baselines (current): TLUHToAXI4 3191 cells / 319 ff / depth 147; TLULToAXILite 303 / 130 / 58;
TLUCToAXI4 4248 / 421 / 272. `TLCToCHI` is excluded (coherence WIP), as in `syn/synth.sh`.
`make ppa` elaborates Chisel → SV first if `generated/` is missing.
