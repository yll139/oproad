####################################
# global connections
####################################
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {^VDD$} -power
add_global_connection -net {VSS} -inst_pattern {.*} -pin_pattern {^VSS$} -ground
global_connect

####################################
# voltage domains
####################################
set_voltage_domain -name {CORE} -power {VDD} -ground {VSS}

####################################
# standard cell grid
####################################
define_pdn_grid -name {grid} -voltage_domains {CORE}
add_pdn_stripe -grid {grid} -layer {M1} -width {0.056} -pitch {1.536} -offset {0} -followpins
add_pdn_stripe -grid {grid} -layer {MINT2} -width {0.064} -pitch {6.4} -offset {1.6}
add_pdn_stripe -grid {grid} -layer {MINT3} -width {0.064} -pitch {6.4} -offset {1.6}
add_pdn_stripe -grid {grid} -layer {MINT4} -width {0.064} -pitch {12.8} -offset {3.2}
add_pdn_stripe -grid {grid} -layer {MINT5} -width {0.064} -pitch {12.8} -offset {3.2}
add_pdn_connect -grid {grid} -layers {M1 MINT2}
add_pdn_connect -grid {grid} -layers {MINT2 MINT3}
add_pdn_connect -grid {grid} -layers {MINT3 MINT4}
add_pdn_connect -grid {grid} -layers {MINT4 MINT5}
