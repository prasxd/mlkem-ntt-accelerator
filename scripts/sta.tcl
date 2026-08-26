read_liberty $::env(LIB)
read_verilog docs/ntt_top_sky130.v
link_design ntt_top
create_clock -name clk -period 10 [get_ports clk]
set_input_delay  2.0 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 2.0 -clock clk [all_outputs]
report_checks -path_delay max -digits 3
report_checks -path_delay min -digits 3
report_wns
report_tns
