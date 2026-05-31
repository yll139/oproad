if {[expr [file exists $::env(REPORTS_DIR)/congestion.rpt] && \
    [file size $::env(REPORTS_DIR)/congestion.rpt] != 0]} {
  error "Global routing failed, run `make gui_grt` and load $::env(REPORTS_DIR)/congestion.rpt \
    in DRC viewer to view congestion"
}

source $::env(SCRIPTS_DIR)/load.tcl
load_design 5_1_grt.odb 4_cts.sdc

set_propagated_clock [all_clocks]

if {[info exists ::env(DETAILED_PLACEMENT_ARGS)] && $::env(DETAILED_PLACEMENT_ARGS) != ""} {
  detailed_placement {*}$::env(DETAILED_PLACEMENT_ARGS)
} else {
  detailed_placement
}

set fillcell_result [catch {filler_placement $::env(FILL_CELLS)} fillcell_msg]
if {$fillcell_result != 0} {
  if {[info exists ::env(ALLOW_FILLER_ONE_SITE_GAPS)] && \
      $::env(ALLOW_FILLER_ONE_SITE_GAPS) != 0 && \
      ([string match {*could not fill gap of size 1*} $fillcell_msg] || \
       [string match {*DPL-0002*} $fillcell_msg])} {
    utl::warn FLW 13 "Continuing with unfilled 1-site filler gap: $fillcell_msg"
  } else {
    error $fillcell_msg
  }
}
check_placement

write_db $::env(RESULTS_DIR)/5_2_fillcell.odb
