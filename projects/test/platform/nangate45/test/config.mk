export PLATFORM      = nangate45
export DESIGN_NAME   = test

export VERILOG_FILES = \
    $(wildcard ./designs/src/test/rtl/*.v)

export SDC_FILE = \
    ./designs/nangate45/test/constraint.sdc

export DESIGN_VCD = ./designs/src/test/tb/test.vcd

# Use an explicit minimum floorplan so the default Nangate45 M4 PDN straps fit.
# CORE_UTILIZATION must be empty; otherwise ORFS ignores DIE_AREA/CORE_AREA.
export DIE_AREA  = 0 0 80 80
export CORE_AREA = 8 8.4 72 71.4

export CORE_UTILIZATION =
export PLACE_DENSITY    = 0.20

export NUM_ROUTING_LAYERS = 6

export PWR_NETS_VOLTAGES = VDD 1.1
export GND_NETS_VOLTAGES = VSS 0.0

# Helpful for designs with many short paths / hold repair buffers.
export MAX_BUFFER_PERCENT = 80
export HOLD_SLACK_MARGIN  = 0.00
export SETUP_SLACK_MARGIN = 0.05
