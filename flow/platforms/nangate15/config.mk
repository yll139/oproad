# Process node
export PROCESS = 15

# -----------------------------------------------------
# Tech/Libs
# -----------------------------------------------------
export TECH_LEF = $(PLATFORM_DIR)/lef/NanGate_15nm_OCL.tech.lef
export SC_LEF = $(PLATFORM_DIR)/lef/NanGate_15nm_OCL.macro.mod.lef

export LIB_FILES = $(PLATFORM_DIR)/lib/NanGate_15nm_OCL_typical.lib \
                     $(ADDITIONAL_LIBS)
export GDS_FILES = $(sort $(wildcard $(PLATFORM_DIR)/gds/*.gds)) \
                     $(ADDITIONAL_GDS)

# Physical-only and tri-state cells are kept out of generic synthesis mapping.
export DONT_USE_CELLS = ANTENNA FILLTIE TBUF_X1 TBUF_X2 TBUF_X4 TBUF_X8 TBUF_X12 TBUF_X16

# Fill cells used in fill cell insertion
export FILL_CELLS = FILL_X1 FILL_X2 FILL_X4 FILL_X8 FILL_X16

# -----------------------------------------------------
# Yosys
# -----------------------------------------------------
export MAX_UNGROUP_SIZE ?= 10000

export TIEHI_CELL_AND_PORT = TIEH Z
export TIELO_CELL_AND_PORT = TIEL ZN

export MIN_BUF_CELL_AND_PORTS = BUF_X1 I Z

export LATCH_MAP_FILE = $(PLATFORM_DIR)/cells_latch.v
export CLKGATE_MAP_FILE = $(PLATFORM_DIR)/cells_clkgate.v
export ADDER_MAP_FILE ?= $(PLATFORM_DIR)/cells_adders.v

export ABC_DRIVER_CELL = BUF_X1
# BUF_X1 input pin I capacitance is 0.850456 fF; use a conservative x4 load.
export ABC_LOAD_IN_FF = 3.401824

# -----------------------------------------------------
# Floorplan
# -----------------------------------------------------
export PLACE_SITE = NanGate_15nm_OCL

export IO_PLACER_H = MINT3
export IO_PLACER_V = MINT4

export PDN_TCL ?= $(PLATFORM_DIR)/grid_strategy-M1-MINT2-MINT5.tcl
export TAPCELL_TCL = $(PLATFORM_DIR)/tapcell.tcl

export MACRO_PLACE_HALO ?= 2 2
export MACRO_PLACE_CHANNEL ?= 2 2

# -----------------------------------------------------
# Place
# -----------------------------------------------------
export PLACE_DENSITY ?= 0.30

# -----------------------------------------------------
# Route
# -----------------------------------------------------
export MIN_ROUTING_LAYER = MINT1
export MAX_ROUTING_LAYER = MINT5
export DETAIL_ROUTING_MIN_LAYER = M1
export VIA_IN_PIN_MIN_LAYER = M1
export VIA_IN_PIN_MAX_LAYER = MINT1

export FASTROUTE_TCL ?= $(PLATFORM_DIR)/fastroute.tcl

# -----------------------------------------------------
# LVS/IR support
# -----------------------------------------------------
export CDL_FILE = $(PLATFORM_DIR)/cdl/NanGate_15nm_OCL.cdl

export TEMPLATE_PGA_CFG ?= $(PLATFORM_DIR)/template_pga.cfg

export PWR_NETS_VOLTAGES ?= "VDD 0.8"
export GND_NETS_VOLTAGES ?= "VSS 0.0"
export IR_DROP_LAYER ?= M1
