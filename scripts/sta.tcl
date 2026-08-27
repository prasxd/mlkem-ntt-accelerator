set pdk $::env(HOME)/.ciel
read_lef $pdk/sky130A/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef
read_lef $pdk/sky130A/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef
read_lef $pdk/sky130A/libs.ref/sky130_fd_sc_hd/lef/sky130_ef_sc_hd.lef
read_liberty $::env(LIB)
read_verilog docs/ntt_top_sky130.v
link_design ntt_top

# Try 30ns first, then tighten later
create_clock -name clk -period 30 [get_ports clk]

set all_inputs_except_clk [lsearch -all -inline -not -exact [all_inputs] "clk"]
set_input_delay 2.0 -clock clk $all_inputs_except_clk
set_output_delay 2.0 -clock clk [all_outputs]

# Debug: check the bad net's fanout
report_fanout -max_depth 2 [get_nets -of [get_pins _11924_/Y]]

report_checks -path_delay max -digits 3
report_wns
report_tns
