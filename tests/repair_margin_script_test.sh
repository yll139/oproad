#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_contains() {
  local file="$1"
  local expected="$2"

  if ! grep -Fq "$expected" "$REPO_ROOT/$file"; then
    echo "Expected $file to contain:" >&2
    echo "  $expected" >&2
    exit 1
  fi
}

require_not_contains() {
  local file="$1"
  local unexpected="$2"

  if grep -Fq "$unexpected" "$REPO_ROOT/$file"; then
    echo "Expected $file not to contain:" >&2
    echo "  $unexpected" >&2
    exit 1
  fi
}

require_contains "flow/scripts/cts.tcl" "CTS_SETUP_SLACK_MARGIN"
require_contains "flow/scripts/cts.tcl" "CTS_HOLD_SLACK_MARGIN"
require_contains "flow/scripts/global_route.tcl" "GLOBAL_ROUTE_SETUP_SLACK_MARGIN"
require_contains "flow/scripts/global_route.tcl" "GLOBAL_ROUTE_HOLD_SLACK_MARGIN"
require_contains "flow/scripts/synth.tcl" "sanitize_generated_instance_names"
require_contains "flow/scripts/synth.tcl" "module_name_map"
require_contains "flow/scripts/synth.tcl" "stable_token_hash"
require_contains "flow/scripts/synth.tcl" "sanitize_escaped_tokens_in_line"
require_contains "flow/scripts/synth.tcl" "strip_yosys_attribute_line"
