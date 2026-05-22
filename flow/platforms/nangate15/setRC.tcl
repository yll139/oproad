# The released 15nm OCL tech LEF carries zero RC values. These estimates are
# intended for OpenROAD flow bring-up, not signoff extraction.
set_layer_rc -layer M1    -resistance 5.0e-02 -capacitance 8.0e-02
set_layer_rc -layer MINT1 -resistance 4.0e-02 -capacitance 8.0e-02
set_layer_rc -layer MINT2 -resistance 4.0e-02 -capacitance 8.0e-02
set_layer_rc -layer MINT3 -resistance 3.0e-02 -capacitance 7.0e-02
set_layer_rc -layer MINT4 -resistance 3.0e-02 -capacitance 7.0e-02
set_layer_rc -layer MINT5 -resistance 2.0e-02 -capacitance 6.0e-02

set_wire_rc -signal -layer MINT3
set_wire_rc -clock  -layer MINT5
