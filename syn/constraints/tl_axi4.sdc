# tl_axi4.sdc — timing constraints for the TileLink->AXI4 bridges (generated SV).
# T0/T2 collateral (tapeout-readiness program). Run on OpenSTA (pathfind) or
# PrimeTime (sign-off) against a target liberty — neither exists in this workspace.
#
# SINGLE clock domain: Chisel emits `clock` + synchronous `reset`. No CDC.
# Apply per bridge top (TLUHToAXI4 | TLULToAXILite | TLUCToAXI4). Note: the
# TLUHToAXI4 / TLUCToAXI4 atomic+arith cone is combinationally deep (~125 generic
# levels) — the real timing watch item; confirm against the target library.

set CLK_PERIOD 2.0 ;# 500 MHz placeholder
create_clock -name clock -period $CLK_PERIOD [get_ports clock]

# Chisel synchronous reset: a normal timed input (NOT a false path).
# PrimeTime has remove_from_collection; OpenSTA (LibreLane/OpenROAD) has delete_from_list.
if {[llength [info commands remove_from_collection]]} {
  set all_in [remove_from_collection [all_inputs] [get_ports clock]]
} else {
  set all_in [delete_from_list [all_inputs] [get_ports clock]]
}
set_input_delay  -clock clock [expr {0.30*$CLK_PERIOD}] $all_in
set_output_delay -clock clock [expr {0.40*$CLK_PERIOD}] [all_outputs]
