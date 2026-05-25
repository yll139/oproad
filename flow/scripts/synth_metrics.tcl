utl::set_metrics_stage "synth__{}"
source $::env(SCRIPTS_DIR)/load.tcl
load_design 1_1_yosys.v 1_synth.sdc
# ================== Authority Declaration ==================
# Area authority: area_coverage.txt (Liberty standard-cell area)
# Timing authority: OpenSTA static timing analysis (this report/log)
# Structural analysis is for debugging only - not authoritative for area
# ====================================================
puts {[INFO][FLOW] Area authority: area_coverage.txt (Liberty standard-cell area)}
puts {[INFO][FLOW] Timing authority: OpenSTA static timing analysis (this report/log)}
puts {[INFO][FLOW] Structural analysis is for debugging only - not authoritative for area}
report_metrics 1 "Post synthesis" false false
