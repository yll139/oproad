# ================================================================
# Platform Liberty time_unit: "1ns".
# Target 1.0 GHz = 1.0000 ns = 1.0000 ns.
create_clock -name clk -period 1.0000 [get_ports clk]

set_clock_uncertainty -setup 0.1000 [get_clocks clk]
set_clock_uncertainty -hold  0.0500 [get_clocks clk]

set_false_path -from [get_ports rst_n]

set_input_delay  0.0500 -clock clk [get_ports {a b}]
set_output_delay 0.0500 -clock clk [all_outputs]

# PDK-independent input model.
# Avoid hard-coding cells such as BUF_X4.
set_input_transition 0.0500 [get_ports {a b rst_n}]
set_load 0.05 [all_outputs]

set_max_transition 0.3500 [current_design]
set_max_fanout 20 [current_design]

