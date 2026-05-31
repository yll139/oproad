#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/projects/dec_opt"
TMP_OUT="$(mktemp)"
TMP_SIM="$(mktemp)"
trap 'rm -f "$TMP_OUT" "$TMP_SIM"' EXIT

if [ "${OPROAD_RUN_DEC_OPT_GOAL_TEST:-0}" != "1" ]; then
  echo "SKIP: set OPROAD_RUN_DEC_OPT_GOAL_TEST=1 to run project-specific dec_opt goal checks."
  exit 0
fi

"$REPO_ROOT/oproad" report "$PROJECT" > "$TMP_OUT"
"$REPO_ROOT/oproad" sim "$PROJECT" > "$TMP_SIM"

extract_metric() {
  local label="$1"
  awk -v label="$label" '
    index($0, label) {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^-?[0-9]+(\.[0-9]+)?$/) {
          print $i
          exit
        }
      }
    }
  ' "$TMP_OUT"
}

require_nonnegative() {
  local label="$1"
  local value="$2"

  if ! awk -v v="$value" 'BEGIN { exit !(v + 0 >= 0) }'; then
    echo "$label is below zero: $value" >&2
    sed -n '13,55p;180,220p' "$TMP_OUT" >&2
    exit 1
  fi
}

require_below_or_equal() {
  local label="$1"
  local value="$2"
  local limit="$3"

  if ! awk -v v="$value" -v limit="$limit" 'BEGIN { exit !(v + 0 <= limit + 0) }'; then
    echo "$label is above target: $value > $limit" >&2
    sed -n '13,55p;180,220p' "$TMP_OUT" >&2
    exit 1
  fi
}

require_above_or_equal() {
  local label="$1"
  local value="$2"
  local limit="$3"

  if ! awk -v v="$value" -v limit="$limit" 'BEGIN { exit !(v + 0 >= limit + 0) }'; then
    echo "$label is below target: $value < $limit" >&2
    sed -n '13,55p;180,220p' "$TMP_OUT" >&2
    exit 1
  fi
}

setup_slack="$(extract_metric "Worst setup slack")"
hold_slack="$(extract_metric "WHS (hold)")"
worst_slack="$(extract_metric "Worst slack (all)")"
clock_period_ps="$(extract_metric "Target clock period")"
nand2_equiv="$(extract_metric "Estimated NAND2 equivalent")"
dff_count="$(extract_metric "DFF-like cells")"
latency_cycles="$(grep -m1 -Eo 'LAT=[0-9]+' "$TMP_SIM" | cut -d= -f2)"

require_nonnegative "Worst setup slack" "$setup_slack"
require_nonnegative "Hold WHS" "$hold_slack"
require_nonnegative "Worst slack" "$worst_slack"
require_above_or_equal "Hold WHS safety margin" "$hold_slack" "5"
require_below_or_equal "Target clock period" "$clock_period_ps" "1000"
require_below_or_equal "NAND2 equivalent" "$nand2_equiv" "150000"
require_below_or_equal "Decode latency" "$latency_cycles" "15"

if ! awk -v v="$dff_count" 'BEGIN { exit !(v + 0 > 0) }'; then
  echo "DFF count was not reported correctly: $dff_count" >&2
  sed -n '130,190p' "$TMP_OUT" >&2
  exit 1
fi

if ! grep -Fq "STA health result : PASS" "$TMP_OUT"; then
  echo "STA health did not pass" >&2
  sed -n '13,55p;180,220p' "$TMP_OUT" >&2
  exit 1
fi

if ! grep -Fq "Report stage       : POST-ROUTE" "$TMP_OUT"; then
  echo "Report is not using final post-route implementation data" >&2
  sed -n '1,80p' "$TMP_OUT" >&2
  exit 1
fi

if ! grep -Fq "Implementation result : PASS" "$TMP_OUT"; then
  echo "Implementation artifacts are incomplete" >&2
  sed -n '1,80p' "$TMP_OUT" >&2
  exit 1
fi

if ! grep -Fq "tb_decoder PASSED" "$TMP_SIM"; then
  echo "Decoder simulation did not pass" >&2
  sed -n '1,160p' "$TMP_SIM" >&2
  exit 1
fi
