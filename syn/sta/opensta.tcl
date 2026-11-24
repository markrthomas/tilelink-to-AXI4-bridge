# opensta.tcl — STA driver for a TileLink->AXI4 bridge top (T2 collateral; not run
# here: no OpenSTA/liberty). Set LIB, NETLIST (liberty-mapped), TOP (TLUHToAXI4 |
# TLULToAXILite | TLUCToAXI4). Run: sta -exit syn/sta/opensta.tcl
if {![info exists ::env(LIB)] || ![info exists ::env(NETLIST)] || ![info exists ::env(TOP)]} {
  puts "SKIP: set LIB + NETLIST + TOP. No liberty/OpenSTA in this workspace."; exit 0 }
read_liberty $::env(LIB)
read_verilog  $::env(NETLIST)
link_design   $::env(TOP)
read_sdc      [file join [file dirname [info script]] .. constraints tl_axi4.sdc]
report_checks -path_delay max -digits 4
report_worst_slack -max ; report_worst_slack -min
report_tns ; report_wns
