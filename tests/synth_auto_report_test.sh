#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT="$TMP_DIR/synth_auto_report_fixture"
FAKE_ORFS="$TMP_DIR/orfs_tree"
mkdir -p \
  "$PROJECT/src/rtl" \
  "$PROJECT/platform/nangate15/synth_auto_report_fixture" \
  "$FAKE_ORFS/platforms/nangate15/lef" \
  "$FAKE_ORFS/platforms/nangate15/lib"

cat > "$PROJECT/.asic_project" <<'EOF_PROJECT'
PLATFORM=nangate15
DESIGN=synth_auto_report_fixture
FREQ=1.0
PERIOD=1000.0000
PERIOD_NS=1.0000
TIME_UNIT=ps
EOF_PROJECT

cat > "$PROJECT/platform/nangate15/synth_auto_report_fixture/config.mk" <<'EOF_CONFIG'
export PLATFORM = nangate15
export DESIGN_NAME = synth_auto_report_fixture
EOF_CONFIG

cat > "$PROJECT/platform/nangate15/synth_auto_report_fixture/constraint.sdc" <<'EOF_SDC'
create_clock -name clk -period 1000 [get_ports clk]
EOF_SDC

cat > "$PROJECT/src/rtl/synth_auto_report_fixture.v" <<'EOF_RTL'
module synth_auto_report_fixture(input clk, input in, output out);
  assign out = in;
endmodule
EOF_RTL

cat > "$FAKE_ORFS/platforms/nangate15/lef/fake.tech.lef" <<'EOF_LEF'
VERSION 5.8 ;
END LIBRARY
EOF_LEF

cat > "$FAKE_ORFS/platforms/nangate15/lib/Nangate_15nm_OCL_typical.lib" <<'EOF_LIB'
library(typical) {
  time_unit : "1ps";
  cell(NAND2_X1) { area : 1.0; }
}
EOF_LIB

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
	printf '%s\n' 'module synth_auto_report_fixture(input clk, input in, output out); assign out = in; endmodule' > "$$result_dir/1_synth.v"; \
	printf '%s\n' '=== synth_auto_report_fixture ===' 'Number of cells: 0' 'Chip area for top module: 0.0' > "$$report_dir/synth_stat.txt"; \
	printf '%s\n' 'There are 0 unconstrained endpoints.' > "$$report_dir/synth_unconstrained_endpoints.rpt"; \
	{ \
	  printf '%s\n' 'Post synthesis report_tns' 'tns 0.00' ''; \
	  printf '%s\n' 'Post synthesis report_wns' 'wns 0.00' ''; \
	  printf '%s\n' 'Post synthesis report_hold_summary' 'whs 6.00' 'ths 0.00' ''; \
	  printf '%s\n' 'Post synthesis report_checks -path_delay max' 'Startpoint: setup_launch' 'Endpoint: setup_capture' 'Path Group: clk' 'Path Type: max' '  500.00   data arrival time' '  500.00   slack (MET)' ''; \
	  printf '%s\n' 'Post synthesis report_checks -path_delay min' 'Startpoint: hold_launch' 'Endpoint: hold_capture' 'Path Group: clk' 'Path Type: min' '  6.00   slack (MET)'; \
	} > "$$report_dir/1_Post_synthesis.rpt"
EOF_MAKE

OUT="$TMP_DIR/synth.out"
if ! ORFS_ROOT="$FAKE_ORFS" OPROAD_RUNNER=local \
  bash "$REPO_ROOT/container/runner.sh" synth "$PROJECT" > "$OUT" 2>&1; then
  echo "Synth command failed unexpectedly." >&2
  sed -n '1,240p' "$OUT" >&2
  exit 1
fi

require_line() {
  local expected="$1"
  if ! grep -Fq -- "$expected" "$OUT"; then
    echo "Expected synth output to contain:" >&2
    echo "  $expected" >&2
    echo "" >&2
    echo "Actual output:" >&2
    sed -n '1,240p' "$OUT" >&2
    exit 1
  fi
}

reject_line() {
  local unexpected="$1"
  if grep -Fq -- "$unexpected" "$OUT"; then
    echo "Synth output should not contain:" >&2
    echo "  $unexpected" >&2
    echo "" >&2
    echo "Actual output:" >&2
    sed -n '1,240p' "$OUT" >&2
    exit 1
  fi
}

require_line "[1/2] Yosys synthesis (ABC tech-mapping)..."
require_line "STAGE 2: AUTO REPORT"
require_line "Report stage       : SYNTHESIS"
require_line "WHS (hold)         : 6.00 ps"
require_line "THS (hold)         : 0.00 ps"
reject_line "---------- Synthesis Results ----------"
reject_line "[2/2] OpenSTA static timing analysis"
reject_line "Setup slack        :"
reject_line "Hold slack         :"

if grep -Fq "run_synthesis_sta()" "$REPO_ROOT/container/runner.sh"; then
  echo "runner.sh should rely on the ORFS synth STA stage, not a custom synthesis STA helper." >&2
  exit 1
fi

if grep -Fq "synth_sta.rpt" "$REPO_ROOT/container/runner.sh"; then
  echo "runner.sh should not reference the removed custom synth_sta.rpt artifact." >&2
  exit 1
fi
