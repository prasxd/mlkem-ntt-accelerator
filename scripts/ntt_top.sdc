set clk_period $::env(CLOCK_PERIOD)

create_clock -name clk -period $clk_period [get_ports clk]
set_clock_uncertainty 0.25 [get_clocks clk]
set_clock_transition  0.15 [get_clocks clk]

set io_delay [expr $clk_period * 0.2]

# Apply delay to all inputs, then reset the clock port to 0
set_input_delay  $io_delay -clock clk [all_inputs]
set_input_delay  0.0       -clock clk [get_ports clk]

set_output_delay $io_delay -clock clk [all_outputs]

# rst_n is asynchronous
set_false_path -from [get_ports rst_n]

set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y [all_inputs]
set_load 0.05 [all_outputs]
