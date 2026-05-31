#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT="$TMP_DIR/auto_report_fixture"
FAKE_ORFS="$TMP_DIR/fake_orfs"
mkdir -p \
  "$PROJECT/src/rtl" \
  "$PROJECT/platform/nangate15/auto_report_fixture" \
  "$FAKE_ORFS/platforms/nangate15"

cat > "$PROJECT/.asic_project" <<'EOF_PROJECT'
PLATFORM=nangate15
DESIGN=auto_report_fixture
FREQ=1.0
PERIOD=1000.0000
PERIOD_NS=1.0000
TIME_UNIT=ps
EOF_PROJECT

cat > "$PROJECT/platform/nangate15/auto_report_fixture/config.mk" <<'EOF_CONFIG'
export PLATFORM = nangate15
export DESIGN_NAME = auto_report_fixture
EOF_CONFIG

cat > "$PROJECT/platform/nangate15/auto_report_fixture/constraint.sdc" <<'EOF_SDC'
create_clock -name clk -period 1000 [get_ports clk]
EOF_SDC

cat > "$PROJECT/src/rtl/auto_report_fixture.v" <<'EOF_RTL'
module auto_report_fixture(input clk, input in, output out);
  assign out = in;
endmodule
EOF_RTL

cat > "$FAKE_ORFS/Makefile" <<'EOF_MAKE'
.DEFAULT:
	@set -e; \
	cfg="$(DESIGN_CONFIG)"; \
	design=$$(basename "$$(dirname "$$cfg")"); \
	platform=$$(basename "$$(dirname "$$(dirname "$$cfg")")"); \
	base=base; \
	result_dir="results/$$platform/$$design/$$base"; \
	report_dir="reports/$$platform/$$design/$$base"; \
	log_dir="logs/$$platform/$$design/$$base"; \
	object_dir="objects/$$platform/$$design/$$base"; \
	mkdir -p "$$result_dir" "$$report_dir" "$$log_dir" "$$object_dir"; \
	printf '%s\n' '1000' > "$$result_dir/clock_period.txt"; \
	printf '%s\n' 'module auto_report_fixture(input clk, input in, output out); assign out = in; endmodule' > "$$result_dir/1_synth.v"; \
	printf '%s\n' 'module auto_report_fixture(input clk, input in, output out); assign out = in; endmodule' > "$$result_dir/6_final.v"; \
	touch "$$result_dir/6_final.def" "$$result_dir/6_final.odb" "$$result_dir/6_final.sdc"; \
	printf '%s\n' '=== auto_report_fixture ===' 'Number of cells: 0' 'Chip area for top module: 0.0' > "$$report_dir/synth_stat.txt"; \
	printf '%s\n' 'Cell type report:' '  Total                                     0' '' 'finish report_design_area' 'Design area 42 u^2 10% utilization.' > "$$log_dir/6_report.log"; \
	{ \
	  printf '%s\n' 'finish report_tns' 'tns 0.00' ''; \
	  printf '%s\n' 'finish report_wns' 'wns 0.00' ''; \
	  printf '%s\n' 'finish report_hold_summary' 'whs 4.00' 'ths 0.00' ''; \
	  printf '%s\n' 'finish report_checks -path_delay min' 'Startpoint: hold_launch' 'Endpoint: hold_capture' 'Path Type: min' '  4.00   slack (MET)' ''; \
	  printf '%s\n' 'finish report_checks -path_delay max' 'Startpoint: setup_launch' 'Endpoint: setup_capture' 'Path Type: max' '  500.00   data arrival time' '  500.00   slack (MET)' ''; \
	} > "$$report_dir/6_finish.rpt"
EOF_MAKE

OUT="$TMP_DIR/implement.out"
ORFS_ROOT="$FAKE_ORFS" OPROAD_RUNNER=local OPROAD_FINISH_MODE=light \
  bash "$REPO_ROOT/container/runner.sh" implement "$PROJECT" > "$OUT" 2>&1

require_line() {
  local expected="$1"
  if ! grep -Fq "$expected" "$OUT"; then
    echo "Expected implement output to contain:" >&2
    echo "  $expected" >&2
    echo "" >&2
    echo "Actual output:" >&2
    sed -n '1,240p' "$OUT" >&2
    exit 1
  fi
}

require_line "IMPLEMENTATION COMPLETE"
require_line "STAGE 1: SYNTHESIS"
require_line "STAGE 2: FLOORPLAN"
require_line "STAGE 3: PLACEMENT"
require_line "STAGE 4: CTS (Clock Tree Synthesis)"
require_line "STAGE 5: ROUTING"
require_line "STAGE 6: FINISH + SIGN-OFF STA"
require_line "STAGE 7: AUTO REPORT"
require_line "Report stage       : POST-ROUTE"
require_line "Implementation result : PASS"
require_line "WNS (OpenSTA)     : 0.00 ns"
require_line "Worst setup slack : 500.00 ns"
require_line "WHS (hold)         : 4.00 ns"
require_line "THS (hold)         : 0.00 ns"
if grep -Fq "WNS summary        :" "$OUT" || grep -Fq "Setup slack        :" "$OUT" || grep -Fq "Hold slack         :" "$OUT"; then
  echo "Report output should not show standalone setup/hold slack rows." >&2
  sed -n '1,240p' "$OUT" >&2
  exit 1
fi
