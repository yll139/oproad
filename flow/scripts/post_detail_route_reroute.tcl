utl::set_metrics_stage "detailedroute__post_hold_reroute"
source $::env(SCRIPTS_DIR)/load.tcl

# Run the post-detail hold ECO reroute in a fresh OpenROAD process.  Running
# detailed_route again from the same process that inserted the hold buffers can
# crash in TritonRoute's design update path on this dense decoder.
load_design 5_3_route.odb 4_cts.sdc
set_propagated_clock [all_clocks]

if {[info exist ::env(FASTROUTE_TCL)]} {
  source $::env(FASTROUTE_TCL)
} else {
  set_global_routing_layer_adjustment $::env(MIN_ROUTING_LAYER)-$::env(MAX_ROUTING_LAYER) 0.5
  set_routing_layers -signal $::env(MIN_ROUTING_LAYER)-$::env(MAX_ROUTING_LAYER)
  if {[info exist ::env(MACRO_EXTENSION)]} {
    set_macro_extension $::env(MACRO_EXTENSION)
  }
}

# The input ODB was written after an initial detailed route.  Clear old signal
# and clock route shapes before regenerating guides; otherwise FastRoute treats
# most nets as already routed and only emits guides for the newly added ECO nets.
set block [[[ord::get_db] getChip] getBlock]
set removed_wires 0
foreach db_net [$block getNets] {
  set sig_type [$db_net getSigType]
  if {"$sig_type" ne "POWER" && "$sig_type" ne "GROUND"} {
    set wire [$db_net getWire]
    if {"$wire" ne "NULL"} {
      odb::dbWire_destroy $wire
      incr removed_wires
    }
  }
}
puts "Post-detail hold ECO: removed routed wires from $removed_wires nets"

# The hold ECO changes the netlist after the original global route.  Regenerate
# route guides so the newly inserted hold buffers are covered before TritonRoute
# reads the design.
set route_nets {}
foreach net [get_nets *] {
  lappend route_nets [get_full_name $net]
}
puts "Post-detail hold ECO: regenerate guides for [llength $route_nets] nets"
set_nets_to_route $route_nets
set grt_args [concat [list \
  -guide_file $::env(RESULTS_DIR)/route.guide \
  -congestion_report_file $::env(REPORTS_DIR)/congestion_post_detail_hold.rpt] \
  [expr {[info exists ::env(GLOBAL_ROUTE_ARGS)] ? $::env(GLOBAL_ROUTE_ARGS) : \
  {-congestion_iterations 30 -congestion_report_iter_step 5 -verbose}}]]

log_cmd global_route {*}$grt_args
write_guides $::env(RESULTS_DIR)/route.guide

set additional_args ""
if { [info exists ::env(dbProcessNode)]} {
  append additional_args " -db_process_node $::env(dbProcessNode)"
}
if { [info exists ::env(OR_SEED)]} {
  append additional_args " -or_seed $::env(OR_SEED)"
}
if { [info exists ::env(OR_K)]} {
  append additional_args " -or_k $::env(OR_K)"
}

if { [info exists ::env(DETAIL_ROUTING_MIN_LAYER)]} {
  append additional_args " -bottom_routing_layer $::env(DETAIL_ROUTING_MIN_LAYER)"
} elseif { [info exists ::env(MIN_ROUTING_LAYER)]} {
  append additional_args " -bottom_routing_layer $::env(MIN_ROUTING_LAYER)"
}
if { [info exists ::env(MAX_ROUTING_LAYER)]} {
  append additional_args " -top_routing_layer $::env(MAX_ROUTING_LAYER)"
}
if { [info exists ::env(VIA_IN_PIN_MIN_LAYER)]} {
  append additional_args " -via_in_pin_bottom_layer $::env(VIA_IN_PIN_MIN_LAYER)"
}
if { [info exists ::env(VIA_IN_PIN_MAX_LAYER)]} {
  append additional_args " -via_in_pin_top_layer $::env(VIA_IN_PIN_MAX_LAYER)"
}
if { [info exists ::env(DISABLE_VIA_GEN)]} {
  append additional_args " -disable_via_gen"
}
if { [info exists ::env(REPAIR_PDN_VIA_LAYER)]} {
  append additional_args " -repair_pdn_vias $::env(REPAIR_PDN_VIA_LAYER)"
}

append additional_args " -save_guide_updates -verbose 1"

set arguments [expr {[info exists ::env(DETAILED_ROUTE_ARGS)] ? $::env(DETAILED_ROUTE_ARGS) : \
 [concat $additional_args {-drc_report_iter_step 5}]}]

set all_args [concat [list \
  -output_drc $::env(REPORTS_DIR)/5_route_drc_post_hold.rpt \
  -output_maze $::env(RESULTS_DIR)/maze_post_hold.log] \
  $arguments]

log_cmd detailed_route {*}$all_args

check_antennas -report_file $::env(REPORTS_DIR)/drt_antennas_post_hold.log

puts "Post-detail hold ECO: routed worst min path"
report_checks -path_delay min -group_count 5 -sort_by_slack

write_db $::env(RESULTS_DIR)/5_4_post_hold_route.odb
