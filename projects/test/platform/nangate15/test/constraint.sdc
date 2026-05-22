# Platform Liberty time_unit: "1ps".
# Target 1.0 GHz = 1.0000 ns = 1000.0000 ps.
create_clock -name clk -period 1000.0000 [get_ports clk]

set_clock_uncertainty -setup 100.0000 [get_clocks clk]
set_clock_uncertainty -hold  50.0000 [get_clocks clk]

set_false_path -from [get_ports rst_n]

set_input_delay  50.0000 -clock clk [get_ports {a b}]
set_output_delay 50.0000 -clock clk [all_outputs]

# PDK-independent input model.
# Avoid hard-coding cells such as BUF_X4.
set_input_transition 50.0000 [get_ports {a b rst_n}]
set_load 0.05 [all_outputs]

set_max_transition 350.0000 [current_design]
set_max_fanout 20 [current_design]
