###############################################################################
# Created by write_sdc
###############################################################################
current_design test
###############################################################################
# Timing Constraints
###############################################################################
create_clock -name clk -period 1.0000 [get_ports {clk}]
set_clock_uncertainty -setup 0.1000 clk
set_clock_uncertainty -hold 0.0500 clk
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {a[0]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {a[1]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {a[2]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {a[3]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {a[4]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {a[5]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {a[6]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {a[7]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {b[0]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {b[1]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {b[2]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {b[3]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {b[4]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {b[5]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {b[6]}]
set_input_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {b[7]}]
set_output_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {y[0]}]
set_output_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {y[1]}]
set_output_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {y[2]}]
set_output_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {y[3]}]
set_output_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {y[4]}]
set_output_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {y[5]}]
set_output_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {y[6]}]
set_output_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {y[7]}]
set_output_delay 0.0500 -clock [get_clocks {clk}] -add_delay [get_ports {y[8]}]
set_false_path\
    -from [get_ports {rst_n}]
###############################################################################
# Environment
###############################################################################
set_load -pin_load 0.0500 [get_ports {y[8]}]
set_load -pin_load 0.0500 [get_ports {y[7]}]
set_load -pin_load 0.0500 [get_ports {y[6]}]
set_load -pin_load 0.0500 [get_ports {y[5]}]
set_load -pin_load 0.0500 [get_ports {y[4]}]
set_load -pin_load 0.0500 [get_ports {y[3]}]
set_load -pin_load 0.0500 [get_ports {y[2]}]
set_load -pin_load 0.0500 [get_ports {y[1]}]
set_load -pin_load 0.0500 [get_ports {y[0]}]
set_input_transition 0.0500 [get_ports {rst_n}]
set_input_transition 0.0500 [get_ports {a[7]}]
set_input_transition 0.0500 [get_ports {a[6]}]
set_input_transition 0.0500 [get_ports {a[5]}]
set_input_transition 0.0500 [get_ports {a[4]}]
set_input_transition 0.0500 [get_ports {a[3]}]
set_input_transition 0.0500 [get_ports {a[2]}]
set_input_transition 0.0500 [get_ports {a[1]}]
set_input_transition 0.0500 [get_ports {a[0]}]
set_input_transition 0.0500 [get_ports {b[7]}]
set_input_transition 0.0500 [get_ports {b[6]}]
set_input_transition 0.0500 [get_ports {b[5]}]
set_input_transition 0.0500 [get_ports {b[4]}]
set_input_transition 0.0500 [get_ports {b[3]}]
set_input_transition 0.0500 [get_ports {b[2]}]
set_input_transition 0.0500 [get_ports {b[1]}]
set_input_transition 0.0500 [get_ports {b[0]}]
###############################################################################
# Design Rules
###############################################################################
set_max_transition 0.3500 [current_design]
set_max_fanout 20.0000 [current_design]
