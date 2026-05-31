#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT="$TMP_DIR/timing_fixture"
mkdir -p \
  "$PROJECT/platform/nangate15/timing_fixture" \
  "$PROJECT/results/nangate15/timing_fixture/base" \
  "$PROJECT/reports/nangate15/timing_fixture/base" \
  "$PROJECT/logs/nangate15/timing_fixture/base"

cat > "$PROJECT/.asic_project" <<'EOF_PROJECT'
PLATFORM=nangate15
DESIGN=timing_fixture
FREQ=1.0
PERIOD=1000.0000
PERIOD_NS=1.0000
TIME_UNIT=ps
EOF_PROJECT

cat > "$PROJECT/platform/nangate15/timing_fixture/config.mk" <<'EOF_CONFIG'
export PLATFORM = nangate15
export DESIGN_NAME = timing_fixture
EOF_CONFIG

cat > "$PROJECT/platform/nangate15/timing_fixture/constraint.sdc" <<'EOF_SDC'
create_clock -name clk -period 1000 [get_ports clk]
set_input_delay 0 -clock clk [get_ports in]
set_output_delay 0 -clock clk [get_ports out]
EOF_SDC

cat > "$PROJECT/results/nangate15/timing_fixture/base/clock_period.txt" <<'EOF_CLOCK'
1000
EOF_CLOCK

touch \
  "$PROJECT/results/nangate15/timing_fixture/base/6_final.def" \
  "$PROJECT/results/nangate15/timing_fixture/base/6_final.odb" \
  "$PROJECT/results/nangate15/timing_fixture/base/6_final.sdc"

cat > "$PROJECT/results/nangate15/timing_fixture/base/6_final.v" <<'EOF_NETLIST'
module timing_fixture(input clk, input in, output out);
  wire n0;
  NAND2_X1 u0 (.A1(in), .A2(in), .ZN(n0));
  DFFRNQ_X1 u1 (.D(n0), .CLK(clk), .RN(1'b1), .Q(out));
endmodule
EOF_NETLIST

cat > "$PROJECT/logs/nangate15/timing_fixture/base/6_report.log" <<'EOF_REPORT_LOG'
Cell type report:
  Sequential cell                           1
  Multi-Input combinational cell            1
  Total                                     2

==========================================================================
finish report_design_area
--------------------------------------------------------------------------
Design area 100 u^2 12% utilization.
EOF_REPORT_LOG

cat > "$PROJECT/logs/nangate15/timing_fixture/base/2_1_floorplan.log" <<'EOF_FLOORPLAN_LOG'
==========================================================================
floorplan final report_design_area
--------------------------------------------------------------------------
Design area 10 u^2 1% utilization.
EOF_FLOORPLAN_LOG

cat > "$PROJECT/reports/nangate15/timing_fixture/base/6_finish.rpt" <<'EOF_RPT'
==========================================================================
finish report_tns
--------------------------------------------------------------------------
tns 0.00

==========================================================================
finish report_wns
--------------------------------------------------------------------------
wns 0.00

==========================================================================
finish report_worst_slack
--------------------------------------------------------------------------
worst slack 448.97

==========================================================================
finish report_checks -path_delay min
--------------------------------------------------------------------------
Startpoint: hold_launch
Endpoint: hold_capture
Path Group: clk
Path Type: min
  48.50   data arrival time
 -48.50   data arrival time
   3.10   slack (MET)

==========================================================================
finish report_checks -path_delay max
--------------------------------------------------------------------------
Startpoint: setup_launch
Endpoint: setup_capture
Path Group: clk
Path Type: max
 532.41   data arrival time
-532.41   data arrival time
 448.97   slack (MET)

==========================================================================
finish critical path delay
--------------------------------------------------------------------------
532.4137

==========================================================================
finish critical path slack
--------------------------------------------------------------------------
448.9655
EOF_RPT

OUT="$TMP_DIR/report.out"
ORFS_ROOT="$REPO_ROOT/flow" OPROAD_RUNNER=local bash "$REPO_ROOT/container/runner.sh" report "$PROJECT" > "$OUT"

require_line() {
  local expected="$1"
  if ! grep -Fq "$expected" "$OUT"; then
    echo "Expected report output to contain:" >&2
    echo "  $expected" >&2
    echo "" >&2
    echo "Actual output:" >&2
    sed -n '1,220p' "$OUT" >&2
    exit 1
  fi
}

reject_line() {
  local unexpected="$1"
  if grep -Fq "$unexpected" "$OUT"; then
    echo "Report output should not contain:" >&2
    echo "  $unexpected" >&2
    echo "" >&2
    echo "Actual output:" >&2
    sed -n '1,220p' "$OUT" >&2
    exit 1
  fi
}

require_line "WHS (hold)         : 3.10 ps"
require_line "THS (hold)         : 0.00 ps"
require_line "Worst slack (all)  : 3.10 ps"
require_line "Critical path delay : 532.4137 ps (0.532414 ns)"
require_line "Setup-limited period: 551.0345 ps (0.551034 ns)"
require_line "Fmax basis          : setup-limited period"
require_line "Implemented design area : 100 μm²  ← OpenROAD final physical database"
require_line "Physical cells           : 2"
require_line "Logic cell area          : 1.474560 μm²"
require_line "Area health result: PASS"
require_line "Path Type: min"
reject_line "Critical path delay : 551.0300 ps"
reject_line "Implemented design area : 10 μm²"
reject_line "Setup slack        :"
reject_line "Hold slack         :"

sed -i.bak 's/   3.10   slack (MET)/  -2.03   slack (VIOLATED)/' \
  "$PROJECT/reports/nangate15/timing_fixture/base/6_finish.rpt"
ORFS_ROOT="$REPO_ROOT/flow" OPROAD_RUNNER=local bash "$REPO_ROOT/container/runner.sh" report "$PROJECT" > "$OUT"

require_line "[FAIL]  worst path slack                    -2.03 ps (timing violation)"
require_line "STA health result : FAIL"

SYNTH_PROJECT="$TMP_DIR/synth_timing_fixture"
mkdir -p \
  "$SYNTH_PROJECT/platform/nangate15/synth_timing_fixture" \
  "$SYNTH_PROJECT/results/nangate15/synth_timing_fixture/base" \
  "$SYNTH_PROJECT/reports/nangate15/synth_timing_fixture/base" \
  "$SYNTH_PROJECT/logs/nangate15/synth_timing_fixture/base"

cat > "$SYNTH_PROJECT/.asic_project" <<'EOF_SYNTH_PROJECT'
PLATFORM=nangate15
DESIGN=synth_timing_fixture
FREQ=1.0
PERIOD=1000.0000
PERIOD_NS=1.0000
TIME_UNIT=ps
EOF_SYNTH_PROJECT

cat > "$SYNTH_PROJECT/platform/nangate15/synth_timing_fixture/config.mk" <<'EOF_SYNTH_CONFIG'
export PLATFORM = nangate15
export DESIGN_NAME = synth_timing_fixture
EOF_SYNTH_CONFIG

cat > "$SYNTH_PROJECT/platform/nangate15/synth_timing_fixture/constraint.sdc" <<'EOF_SYNTH_SDC'
create_clock -name clk -period 1000 [get_ports clk]
set_input_delay 0 -clock clk [get_ports in]
set_output_delay 0 -clock clk [get_ports out]
EOF_SYNTH_SDC

cat > "$SYNTH_PROJECT/results/nangate15/synth_timing_fixture/base/clock_period.txt" <<'EOF_SYNTH_CLOCK'
1000
EOF_SYNTH_CLOCK

cat > "$SYNTH_PROJECT/results/nangate15/synth_timing_fixture/base/1_synth.v" <<'EOF_SYNTH_NETLIST'
module synth_timing_fixture(input clk, input in, output out);
  wire n0;
  NAND2_X1 u0 (.A1(in), .A2(in), .ZN(n0));
  DFFRNQ_X1 u1 (.D(n0), .CLK(clk), .RN(1'b1), .Q(out));
endmodule
EOF_SYNTH_NETLIST

cat > "$SYNTH_PROJECT/reports/nangate15/synth_timing_fixture/base/synth_stat.txt" <<'EOF_SYNTH_STAT'
=== synth_timing_fixture ===

   Number of cells:                  2
     DFFRNQ_X1                       1
     NAND2_X1                        1

   Chip area for top module: 1.474560
EOF_SYNTH_STAT

cat > "$SYNTH_PROJECT/reports/nangate15/synth_timing_fixture/base/synth_unconstrained_endpoints.rpt" <<'EOF_SYNTH_UNCONSTRAINED'
There are 0 unconstrained endpoints.
EOF_SYNTH_UNCONSTRAINED

cat > "$SYNTH_PROJECT/reports/nangate15/synth_timing_fixture/base/1_Post_synthesis.rpt" <<'EOF_SYNTH_RPT'
========================================
 SYNTHESIS STA SUMMARY
========================================
wns 0.00
tns 0.00
Design area 1.474560 u^2 100% utilization.

========================================
 LONGEST SYNTHESIS PATHS
========================================
Startpoint: setup_launch
Endpoint: setup_capture
Path Group: clk
Path Type: max
 532.4137   data arrival time

 981.3792   data required time
-532.4137   data arrival time
 448.9655   slack (MET)
EOF_SYNTH_RPT

ORFS_ROOT="$REPO_ROOT/flow" OPROAD_RUNNER=local bash "$REPO_ROOT/container/runner.sh" report "$SYNTH_PROJECT" > "$OUT"

require_line "WHS (hold)         : N/A (min-path report missing)"
require_line "THS (hold)         : N/A"
require_line "Critical path delay : 532.4137 ps (0.532414 ns)"
require_line "Setup-limited period: 551.0345 ps (0.551034 ns)"
reject_line "Setup slack        :"
reject_line "Hold slack         :"
reject_line "Critical path delay : N/A"
