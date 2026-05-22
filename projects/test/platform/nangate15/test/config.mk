export PLATFORM      = nangate15
export DESIGN_NAME   = test

export VERILOG_FILES = \
    $(wildcard ./designs/src/test/rtl/*.v)

export SDC_FILE = \
    ./designs/nangate15/test/constraint.sdc

# Tiny Nangate15 demos can auto-floorplan too small for the default PDN grid.
# Use an explicit minimum core so MINT4/MINT5 stripes fit during implement.
export CORE_UTILIZATION =
export DIE_AREA  = 0 0 80 80
export CORE_AREA = 8 7.68 72 72.96
export PLACE_DENSITY    = 0.30

export DESIGN_VCD = ./designs/src/test/tb/test.vcd
