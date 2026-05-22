#!/bin/bash

###############################################################################
# Standalone ASIC Research Manager for OpenROAD-flow-scripts
# Strict and PDK-compatible version
#
# Features:
#   - Does not hard-code Nangate45 / ASAP7 library names
#   - Uses .asic_project PLATFORM/DESIGN strictly for report result directory
#   - Auto-loads current platform LEF/TLEF and Liberty files
#   - Avoids FAKE/noise/ccs/lvf/pocv/aocv Liberty files
#   - Robust timing parser + diagnostics when timing is N/A
#   - Multi-Liberty area/NAND2 lookup for ASAP7-style split libraries
###############################################################################

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

resolve_orfs_root() {
    if [ -n "${ORFS_ROOT:-}" ] && [ -d "${ORFS_ROOT:-}" ]; then
        cd "$ORFS_ROOT" 2>/dev/null && pwd
        return 0
    fi

    local candidate
    for candidate in \
        "${SCRIPT_DIR}/../flow" \
        "${SCRIPT_DIR}/../OpenROAD-flow-scripts/flow" \
        "$(pwd)/flow" \
        "$(pwd)/../flow" \
        "/OpenROAD-flow-scripts/flow"
    do
        if [ -d "$candidate" ] && [ -f "$candidate/Makefile" ] && [ -d "$candidate/platforms" ]; then
            cd "$candidate" 2>/dev/null && pwd
            return 0
        fi
    done
}

ORFS_ROOT=$(resolve_orfs_root)
DOCKER_IMAGE=${DOCKER_IMAGE:-openroad/orfs:v3.0-1305-g0aa3fe5d}
DOCKER_PLATFORM=${DOCKER_PLATFORM:-linux/amd64}
BASE=${BASE:-base}
VERBOSE_READS=${VERBOSE_READS:-0}
OPROAD_DOCKER_TTY=${OPROAD_DOCKER_TTY:-auto}
OPROAD_FINISH_MODE=${OPROAD_FINISH_MODE:-auto}
OPROAD_RUNNER=${OPROAD_RUNNER:-auto}

usage() {
    echo ""
    echo "Usage:"
    echo "  oproad new       <platform> <design> <freq_GHz> [parent_dir]"
    echo "  oproad sim       [project_dir]"
    echo "  oproad synth     [project_dir]"
    echo "  oproad implement [project_dir]"
    echo "  oproad report    [project_dir]"
    echo "  oproad clean     [project_dir]"
    echo "  oproad delete    [project_dir]"
    echo ""
    echo "Note:"
    echo "  Only 'oproad new' takes a platform/process argument."
    echo "  Other commands read PLATFORM and DESIGN from project_dir/.asic_project."
    echo ""
    exit 1
}

require_command() {
    local cmd="$1"
    local hint="$2"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd"
        [ -n "$hint" ] && echo "Hint : $hint"
        return 1
    fi
}

check_orfs() {
    if [ -z "$ORFS_ROOT" ] || [ ! -d "$ORFS_ROOT" ]; then
        echo "ERROR: ORFS_ROOT not found."
        echo "Set it manually:"
        echo "  export ORFS_ROOT=/path/to/OpenROAD-flow-scripts/flow"
        exit 1
    fi
}

docker_tty_args() {
    case "$OPROAD_DOCKER_TTY" in
        1|true|TRUE|yes|YES|on|ON)
            echo "-it"
            ;;
        0|false|FALSE|no|NO|off|OFF)
            echo "-i"
            ;;
        auto|AUTO|"")
            if [ -t 0 ] && [ -t 1 ]; then
                echo "-it"
            else
                echo "-i"
            fi
            ;;
        *)
            echo "-i"
            ;;
    esac
}

oproad_runner_mode() {
    case "$OPROAD_RUNNER" in
        local|LOCAL|native|NATIVE)
            echo "local"
            ;;
        docker|DOCKER)
            echo "docker"
            ;;
        auto|AUTO|"")
            if [ -f /.dockerenv ] || [ "${ORFS_ROOT#/OpenROAD-flow-scripts/}" != "$ORFS_ROOT" ]; then
                echo "local"
            else
                echo "docker"
            fi
            ;;
        *)
            echo "invalid"
            ;;
    esac
}

find_project() {
    if [ -n "$1" ]; then
        if [ ! -d "$1" ]; then
            if [ -n "$ORFS_ROOT" ] && [ -d "$ORFS_ROOT/platforms/$1" ]; then
                echo "ERROR: '$1' looks like a platform/process name, not a project directory."
                echo ""
                echo "Only project creation specifies the platform:"
                echo "  oproad new $1 <design> <freq_GHz> [parent_dir]"
                echo ""
                echo "After that, run commands inside the project or pass the project directory:"
                echo "  oproad synth [project_dir]"
                echo "  oproad implement [project_dir]"
                echo "  oproad report [project_dir]"
            else
                echo "ERROR: project_dir not found: $1"
            fi
            exit 1
        fi

        PROJECT_ROOT=$(cd "$1" && pwd)
    else
        PROJECT_ROOT=$(pwd)
        while [ "$PROJECT_ROOT" != "/" ]; do
            [ -f "$PROJECT_ROOT/.asic_project" ] && break
            PROJECT_ROOT=$(dirname "$PROJECT_ROOT")
        done
    fi

    if [ ! -f "$PROJECT_ROOT/.asic_project" ]; then
        echo "ERROR: .asic_project not found."
        echo "Run inside a project directory or pass project_dir."
        exit 1
    fi

    source "$PROJECT_ROOT/.asic_project"

    if [ -z "${PLATFORM:-}" ] || [ -z "${DESIGN:-}" ]; then
        echo "ERROR: malformed .asic_project in:"
        echo "  $PROJECT_ROOT/.asic_project"
        echo "Expected PLATFORM and DESIGN entries."
        exit 1
    fi

    if [ ! -d "$ORFS_ROOT/platforms/${PLATFORM}" ]; then
        echo "ERROR: platform from .asic_project is not available in this ORFS tree:"
        echo "  PLATFORM=${PLATFORM}"
        echo "  ORFS_ROOT=${ORFS_ROOT}"
        exit 1
    fi
}

remove_if_exists() {
    TARGET=$1
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        echo "  removed: $TARGET"
        rm -rf "$TARGET"
    else
        echo "  skipped: $TARGET"
    fi
}

config_file_for_design() {
    local design_dir="$1"
    echo "$PROJECT_ROOT/platform/${PLATFORM}/${design_dir}/config.mk"
}

get_design_name_for_dir() {
    local design_dir="$1"
    local cfg
    cfg="$(config_file_for_design "$design_dir")"

    if [ -f "$cfg" ]; then
        local val
        val=$(grep -E '^[[:space:]]*export[[:space:]]+DESIGN_NAME[[:space:]]*=' "$cfg" | \
              tail -1 | sed -E 's/^[[:space:]]*export[[:space:]]+DESIGN_NAME[[:space:]]*=[[:space:]]*//; s/[[:space:]]*$//')
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
    fi

    echo "$design_dir"
}

get_design_name() {
    get_design_name_for_dir "$DESIGN"
}

to_flow_path() {
    echo "$1" | sed "s#^${ORFS_ROOT}#/OpenROAD-flow-scripts/flow#"
}

###############################################################################
# Sync and Docker Make
###############################################################################

sync_project_to_orfs() {
    check_orfs

    echo ""
    echo "Syncing current project input files to ORFS..."

    if [ ! -d "$PROJECT_ROOT/platform/${PLATFORM}/${DESIGN}" ]; then
        echo "ERROR: platform config directory not found:"
        echo "  $PROJECT_ROOT/platform/${PLATFORM}/${DESIGN}"
        echo ""
        echo "Check .asic_project:"
        echo "  PLATFORM=${PLATFORM}"
        echo "  DESIGN=${DESIGN}"
        exit 1
    fi

    mkdir -p "$ORFS_ROOT/designs/src"
    mkdir -p "$ORFS_ROOT/designs/${PLATFORM}"
    mkdir -p "$ORFS_ROOT/designs/src/${DESIGN}"
    mkdir -p "$ORFS_ROOT/designs/${PLATFORM}/${DESIGN}"

    rsync -a --delete "$PROJECT_ROOT/src/" "$ORFS_ROOT/designs/src/${DESIGN}/" || { echo "ERROR: rsync src failed" >&2; return 1; }
    rsync -a --delete "$PROJECT_ROOT/platform/${PLATFORM}/${DESIGN}/" "$ORFS_ROOT/designs/${PLATFORM}/${DESIGN}/" || { echo "ERROR: rsync platform config failed" >&2; return 1; }

    echo "  synced src      -> $ORFS_ROOT/designs/src/${DESIGN}"
    echo "  synced platform -> $ORFS_ROOT/designs/${PLATFORM}/${DESIGN}"
}

sync_orfs_to_project() {
    echo ""
    echo "Syncing current ORFS output files back to project..."

    mkdir -p "$PROJECT_ROOT/results/${PLATFORM}/${DESIGN}"
    mkdir -p "$PROJECT_ROOT/reports/${PLATFORM}/${DESIGN}"
    mkdir -p "$PROJECT_ROOT/logs/${PLATFORM}/${DESIGN}"
    mkdir -p "$PROJECT_ROOT/objects/${PLATFORM}/${DESIGN}"

    if [ -d "$ORFS_ROOT/results/${PLATFORM}/${DESIGN}" ]; then
        rsync -a --delete "$ORFS_ROOT/results/${PLATFORM}/${DESIGN}/" "$PROJECT_ROOT/results/${PLATFORM}/${DESIGN}/" || echo "  [WARN] rsync results failed" >&2
        echo "  synced results/${PLATFORM}/${DESIGN}"
    else
        echo "  skipped results/${PLATFORM}/${DESIGN}"
    fi

    if [ -d "$ORFS_ROOT/reports/${PLATFORM}/${DESIGN}" ]; then
        rsync -a --delete "$ORFS_ROOT/reports/${PLATFORM}/${DESIGN}/" "$PROJECT_ROOT/reports/${PLATFORM}/${DESIGN}/" || echo "  [WARN] rsync reports failed" >&2
        echo "  synced reports/${PLATFORM}/${DESIGN}"
    else
        echo "  skipped reports/${PLATFORM}/${DESIGN}"
    fi

    if [ -d "$ORFS_ROOT/logs/${PLATFORM}/${DESIGN}" ]; then
        rsync -a --delete "$ORFS_ROOT/logs/${PLATFORM}/${DESIGN}/" "$PROJECT_ROOT/logs/${PLATFORM}/${DESIGN}/" || echo "  [WARN] rsync logs failed" >&2
        echo "  synced logs/${PLATFORM}/${DESIGN}"
    else
        echo "  skipped logs/${PLATFORM}/${DESIGN}"
    fi

    if [ -d "$ORFS_ROOT/objects/${PLATFORM}/${DESIGN}" ]; then
        rsync -a --delete "$ORFS_ROOT/objects/${PLATFORM}/${DESIGN}/" "$PROJECT_ROOT/objects/${PLATFORM}/${DESIGN}/" || echo "  [WARN] rsync objects failed" >&2
        echo "  synced objects/${PLATFORM}/${DESIGN}"
    else
        echo "  skipped objects/${PLATFORM}/${DESIGN}"
    fi
}

run_docker_make() {
    TARGETS=("$@")

    sync_project_to_orfs
    cd "$ORFS_ROOT" || exit 1

    RUNNER_MODE=$(oproad_runner_mode)
    MAKE_ARGS=(DESIGN_CONFIG=./designs/${PLATFORM}/${DESIGN}/config.mk)
    if [ "${#TARGETS[@]}" -gt 0 ]; then
        MAKE_ARGS+=("${TARGETS[@]}")
    fi

    if [ "$RUNNER_MODE" = "local" ]; then
        require_command make "Install make or use the Docker image supplied by this repository." || return 127
        QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-offscreen} \
        XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-root} \
        make "${MAKE_ARGS[@]}"
        STATUS=$?
        sync_orfs_to_project
        return $STATUS
    fi

    if [ "$RUNNER_MODE" != "docker" ]; then
        echo "ERROR: invalid OPROAD_RUNNER=$OPROAD_RUNNER"
        echo "Use one of: auto, local, docker"
        return 1
    fi

    require_command docker "Install Docker Desktop, then retry after Docker is running." || return 127

    DOCKER_TTY_FLAGS=($(docker_tty_args))

    docker run --rm "${DOCKER_TTY_FLAGS[@]}" --platform "$DOCKER_PLATFORM" \
        -e QT_QPA_PLATFORM=offscreen \
        -e XDG_RUNTIME_DIR=/tmp/runtime-root \
        -v "$ORFS_ROOT":/OpenROAD-flow-scripts/flow \
        -w /OpenROAD-flow-scripts/flow \
        "$DOCKER_IMAGE" \
        make "${MAKE_ARGS[@]}"

    STATUS=$?
    sync_orfs_to_project
    return $STATUS
}

finish_mode_for_platform() {
    case "$OPROAD_FINISH_MODE" in
        full|FULL)
            echo "full"
            ;;
        light|LIGHT|report|REPORT)
            echo "light"
            ;;
        skip|SKIP|none|NONE)
            echo "skip"
            ;;
        auto|AUTO|"")
            if [ "$PLATFORM" = "nangate15" ]; then
                echo "light"
            else
                echo "full"
            fi
            ;;
        *)
            echo "invalid"
            ;;
    esac
}

run_finish_stage() {
    local mode
    mode=$(finish_mode_for_platform)

    case "$mode" in
        full)
            echo "Finish mode: full (final report + GDS/OAS through KLayout)"
            run_docker_make "do-finish"
            ;;
        light)
            echo "Finish mode: light (final report/netlist/DEF/ODB; skip GDS/KLayout merge)"
            run_docker_make "do-6_1_fill" "do-6_1_fill.sdc" "do-6_final.sdc" "do-6_report" "elapsed"
            ;;
        skip)
            echo "Finish mode: skip (route artifacts only)"
            sync_orfs_to_project
            return 0
            ;;
        *)
            echo "ERROR: invalid OPROAD_FINISH_MODE=$OPROAD_FINISH_MODE"
            echo "Use one of: auto, full, light, skip"
            return 1
            ;;
    esac
}

###############################################################################
# Platform discovery
###############################################################################

find_platform_lefs() {
    local platform_dir="$ORFS_ROOT/platforms/${PLATFORM}"

    if [ ! -d "$platform_dir" ]; then
        return 1
    fi

    {
        find "$platform_dir" -type f \( -iname "*.tlef" -o -iname "*tech*.lef" \) 2>/dev/null | sort
        find "$platform_dir" -type f -iname "*.lef" 2>/dev/null | grep -vi "tech" | sort
    } | awk '!seen[$0]++'
}

# LEFs needed for synthesis STA inside OpenROAD.
# OpenROAD needs a technology database before read_verilog/link_design.
# Keep this list compact: tech/tlef first, then non-memory stdcell LEFs.
find_platform_sta_lefs() {
    local platform_dir="$ORFS_ROOT/platforms/${PLATFORM}"

    if [ ! -d "$platform_dir" ]; then
        return 1
    fi

    {
        find "$platform_dir" -type f \( -iname "*.tlef" -o -iname "*tech*.lef" \) 2>/dev/null | sort
        find "$platform_dir" -type f -iname "*.lef" 2>/dev/null | \
            grep -Evi 'tech|fakeram|sram|ram|memory|mem' | sort
    } | awk '!seen[$0]++'
}

# Strict area libs: safest first pass.
# Excludes FAKE and special analysis/timing-variation libraries.
find_platform_area_libs_primary() {
    local platform_dir="$ORFS_ROOT/platforms/${PLATFORM}"

    if [ ! -d "$platform_dir" ]; then
        return 1
    fi

    find "$platform_dir" -type f -iname "*.lib" 2>/dev/null | \
        grep -Evi 'FAKE|fake|noise|ccs|lvf|pocv|aocv' | sort
}

# Fallback area libs: broader second pass.
# Still excludes FAKE, but allows CCS/LVF/AOCV/POCV/noise as fallback
# because their Liberty files may still contain valid "area" attributes.
find_platform_area_libs_fallback() {
    local platform_dir="$ORFS_ROOT/platforms/${PLATFORM}"

    if [ ! -d "$platform_dir" ]; then
        return 1
    fi

    find "$platform_dir" -type f -iname "*.lib" 2>/dev/null | \
        grep -Evi 'FAKE|fake' | sort
}

# Combined unique area library list:
#   first strict libs, then broader fallback libs.
find_platform_area_libs() {
    {
        find_platform_area_libs_primary
        find_platform_area_libs_fallback
    } | awk '!seen[$0]++'
}

find_platform_sta_libs() {
    local platform_dir="$ORFS_ROOT/platforms/${PLATFORM}"

    if [ ! -d "$platform_dir" ]; then
        return 1
    fi

    # Prefer NLDM TT/typical/nominal non-fake libs. Reading multiple split
    # Liberty files is useful for ASAP7-like platforms.
    local preferred
    preferred=$(find "$platform_dir" -type f -iname "*.lib" 2>/dev/null | \
        grep -Evi 'FAKE|fake|noise|ccs|lvf|pocv|aocv' | \
        grep -Ei 'nldm|typ|typical|_tt_|tt_|_tt|nom|nominal' | sort)

    if [ -n "$preferred" ]; then
        echo "$preferred"
        return 0
    fi

    find_platform_area_libs
}

find_platform_single_lib_for_display() {
    find_platform_sta_libs | head -1
}

get_platform_time_unit_decl() {
    local lib
    lib=$(find_platform_single_lib_for_display 2>/dev/null | head -1)

    if [ -f "$lib" ]; then
        awk -F'"' '/time_unit[[:space:]]*:/ {print $2; exit}' "$lib" 2>/dev/null
    fi
}

get_platform_time_unit() {
    local decl
    decl=$(get_platform_time_unit_decl)
    [ -z "$decl" ] && decl="1ns"

    echo "$decl" | sed -E 's/^[[:space:]]*[0-9.]+[[:space:]]*//; s/[[:space:]]*$//'
}

time_unit_decl_to_ns() {
    local decl="${1:-1ns}"

    awk -v decl="$decl" '
        BEGIN {
            gsub(/[[:space:]]/, "", decl)
            value = decl
            unit = decl
            sub(/[A-Za-z].*$/, "", value)
            sub(/^[0-9.]+/, "", unit)
            if (value == "") value = 1

            if (unit == "fs") scale = 0.000001
            else if (unit == "ps") scale = 0.001
            else if (unit == "ns" || unit == "") scale = 1
            else if (unit == "us") scale = 1000
            else scale = 1

            printf "%.12g", value * scale
        }
    '
}

ns_to_platform_time_scale() {
    local decl="${1:-$(get_platform_time_unit_decl)}"
    [ -z "$decl" ] && decl="1ns"

    local unit_ns
    unit_ns=$(time_unit_decl_to_ns "$decl")
    awk -v unit_ns="$unit_ns" 'BEGIN { if (unit_ns > 0) printf "%.12g", 1.0 / unit_ns; else print "1" }'
}

find_nand2_cell() {
    local lib_file="$1"

    awk '
        /^[[:space:]]*cell[[:space:]]*\(/ {
            line = $0
            sub(/^.*cell[[:space:]]*\(/, "", line)
            sub(/\).*$/, "", line)
            cell = line

            if (cell ~ /^NAND2/ || cell ~ /^NAND2x/ || cell ~ /^nand2/) {
                print cell
                exit
            }
        }
    ' "$lib_file"
}

find_nand2_cell_any() {
    while IFS= read -r lib; do
        [ -f "$lib" ] || continue
        cell=$(find_nand2_cell "$lib")
        if [ -n "$cell" ]; then
            echo "$lib|$cell"
            return 0
        fi
    done < <(find_platform_area_libs)
}

###############################################################################
# STA / parsing helpers
###############################################################################

extract_last_numeric_for_key() {
    local key="$1"
    local file="$2"

    awk -v key="$key" '
        BEGIN { IGNORECASE = 1 }
        {
            first = tolower($1)
            gsub(":", "", first)
            if (first == tolower(key)) {
                for (i = 2; i <= NF; i++) {
                    if ($i ~ /^[-+]?[0-9]+(\.[0-9]+)?$/) {
                        val = $i
                    }
                }
            }
        }
        END {
            if (val != "") print val
        }
    ' "$file" 2>/dev/null
}

extract_first_slack() {
    local file="$1"

    awk '
        /slack[[:space:]]+\((MET|VIOLATED)\)/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[-+]?[0-9]+(\.[0-9]+)?$/) {
                    print $i
                    exit
                }
            }
        }
    ' "$file" 2>/dev/null
}

extract_worst_slack_line() {
    local file="$1"

    awk '
        BEGIN { IGNORECASE = 1 }
        /worst[[:space:]]+slack/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[-+]?[0-9]+(\.[0-9]+)?$/) {
                    val = $i
                }
            }
        }
        END {
            if (val != "") print val
        }
    ' "$file" 2>/dev/null
}

extract_clock_period() {
    local clock_file="$1"
    local sdc_file="$2"

    # Prefer the live SDC. clock_period.txt can be stale after users edit
    # constraints or when a platform uses non-ns Liberty time units.
    if [ -f "$sdc_file" ]; then
        local sdc_period
        sdc_period=$(awk '
            /^[[:space:]]*#/ { next }
            /create_clock/ {
                for (i = 1; i <= NF; i++) {
                    if ($i == "-period" && (i+1) <= NF) {
                        print $(i+1)
                        exit
                    }
                }
            }
        ' "$sdc_file" 2>/dev/null)
        if [ -n "$sdc_period" ]; then
            echo "$sdc_period"
            return 0
        fi
    fi

    if [ -f "$clock_file" ]; then
        local p
        p=$(awk 'NF {print $1; exit}' "$clock_file" 2>/dev/null)
        if [ -n "$p" ]; then
            echo "$p"
            return 0
        fi
    fi
}

show_sta_diagnostics() {
    local rpt="$1"

    echo ""
    echo "========== STA REPORT DIAGNOSTICS =========="

    if [ ! -f "$rpt" ]; then
        echo "STA report not found: $rpt"
        return
    fi

    echo "Important lines:"
    grep -niE "error|failed|not found|no paths found|unconstrained|unclocked|read_sdc|read_liberty|link_design|Warning" "$rpt" | head -100 || true

    echo ""
    echo "Last 80 lines of STA report:"
    tail -80 "$rpt"
}

extract_unconstrained_count() {
    local rpt="$1"

    grep -i "unconstrained endpoints" "$rpt" 2>/dev/null | tail -1 | \
        sed -E 's/.*There are[[:space:]]+([0-9]+)[[:space:]]+unconstrained endpoints.*/\1/I'
}

summarize_unconstrained_endpoints() {
    local rpt="$1"
    local max_lines="${2:-20}"

    if [ ! -f "$rpt" ]; then
        echo "Unconstrained detail: timing report not found."
        return
    fi

    local count
    count=$(extract_unconstrained_count "$rpt")

    if [ -z "$count" ]; then
        echo "Unconstrained detail: no check_setup unconstrained-endpoint count found."
        return
    fi

    if [ "$count" = "0" ]; then
        echo "Unconstrained detail: none reported by check_setup."
        return
    fi

    echo "Unconstrained count : ${count} endpoint(s) reported by check_setup."

    local section
    section=$(awk '
        /UNCONSTRAINED ENDPOINT DIAGNOSTIC RAW/ {in_sec=1; next}
        in_sec && /^=+$/ {sep_count++; if (sep_count >= 2) exit}
        in_sec {print}
    ' "$rpt" 2>/dev/null)

    if [ -z "$section" ]; then
        echo "Unconstrained detail: raw diagnostic section not found."
        echo "Action              : Check check_setup output in synth_sta.rpt."
        return
    fi

    local tmp
    tmp=$(mktemp 2>/dev/null || mktemp -t oproad_unconstr)
    printf "%s\n" "$section" > "$tmp"

    local explicit_count
    explicit_count=$(grep -c "Path is unconstrained" "$tmp" 2>/dev/null || true)

    local suspects
    suspects=$(awk '
        /^Endpoint:/ {
            line=$0
            sub(/^Endpoint:[[:space:]]*/, "", line)

            if (line !~ /clocked by/) {
                print line
            }
        }
    ' "$tmp" | sort -u | head -"$max_lines")

    if [ "$explicit_count" -gt 0 ]; then
        echo "Unconstrained detail: found explicit '(Path is unconstrained)' marker(s)."
    fi

    if [ -n "$suspects" ]; then
        echo "Likely unconstrained endpoint(s):"
        printf "%s\n" "$suspects" | sed 's/^/  - /'
        echo "Note                : These are filtered from the raw unconstrained diagnostic section."
        echo "                      Normal clk paths are ignored when their Endpoint line says 'clocked by'."
    else
        echo "Likely unconstrained endpoint(s): not identifiable from report format."
        echo "Note                : Your OpenROAD/OpenSTA may only report the count in check_setup."
    fi

    rm -f "$tmp"
}

print_health_line() {
    local status="$1"
    local item="$2"
    local detail="$3"

    printf "%-6s  %-34s  %s\n" "[$status]" "$item" "$detail"
}

count_sdc_command() {
    local sdc="$1"
    local cmd="$2"

    grep -E "^[[:space:]]*${cmd}[[:space:]]+" "$sdc" 2>/dev/null | \
        grep -Ev '^[[:space:]]*#' | wc -l | tr -d ' '
}

has_broad_false_path() {
    local sdc="$1"

    grep -E "^[[:space:]]*set_false_path[[:space:]]+" "$sdc" 2>/dev/null | \
        grep -Ev '^[[:space:]]*#' | \
        grep -E "all_inputs|all_outputs|current_design|get_ports[[:space:]]+\\*|\\[all_registers\\]" >/dev/null 2>&1
}

show_sta_health_check() {
    local rpt="$1"
    local sdc="$2"
    local top_name="$3"
    local netlist="$4"
    local ws_val="$5"
    local wns_val="$6"
    local no_paths_val="$7"
    local unclocked_val="$8"
    local unconstrained_val="$9"

    local fail=0
    local warn=0

    echo ""
    echo "========== STA HEALTH CHECK =========="

    # 1. STA report existence and hard errors.
    if [ ! -f "$rpt" ]; then
        print_health_line "FAIL" "STA report exists" "missing: $rpt"
        fail=$((fail + 1))
    else
        print_health_line "PASS" "STA report exists" "${rpt#$PROJECT_ROOT/}"

        local hard_errors report_warnings
        hard_errors=$(grep -niE "^(Error:|ERROR:|\\[ERROR)|invalid command name" "$rpt" 2>/dev/null | head -5)
        report_warnings=$(grep -niE "^(Warning:|\\[WARNING)" "$rpt" 2>/dev/null | head -5)

        if [ -n "$hard_errors" ]; then
            print_health_line "FAIL" "STA/OpenROAD errors" "error lines found"
            echo "$hard_errors" | sed 's/^/        /'
            fail=$((fail + 1))
        else
            print_health_line "PASS" "STA/OpenROAD errors" "none found"
        fi

        if [ -n "$report_warnings" ]; then
            print_health_line "WARN" "STA/OpenROAD warnings" "warning lines found"
            echo "$report_warnings" | sed 's/^/        /'
            warn=$((warn + 1))
        else
            print_health_line "PASS" "STA/OpenROAD warnings" "none found"
        fi
    fi

    # 2. Liberty / SDC / top link.
    if [ -f "$rpt" ] && grep -qiE "OPROAD_READ_LIBERTY_COUNT=|READ LIBERTY FILES|read_liberty" "$rpt" 2>/dev/null; then
        LIB_COUNT_IN_RPT=$(grep -i "OPROAD_READ_LIBERTY_COUNT=" "$rpt" 2>/dev/null | tail -1 | sed 's/.*OPROAD_READ_LIBERTY_COUNT=//; s/[^0-9].*//')
        if [ -n "$LIB_COUNT_IN_RPT" ]; then
            print_health_line "PASS" "read_liberty" "attempted; ${LIB_COUNT_IN_RPT} file(s)"
        else
            print_health_line "PASS" "read_liberty" "attempted"
        fi
    else
        print_health_line "WARN" "read_liberty" "not confirmed in report text"
        warn=$((warn + 1))
    fi

    if [ -f "$rpt" ] && grep -qiE "OPROAD_READ_SDC=|READ SDC|read_sdc" "$rpt" 2>/dev/null; then
        print_health_line "PASS" "read_sdc" "attempted"
    else
        print_health_line "WARN" "read_sdc" "not confirmed in report text"
        warn=$((warn + 1))
    fi

    if [ -f "$rpt" ] && grep -q "link_design ${top_name}" "$rpt" 2>/dev/null; then
        print_health_line "PASS" "link_design top" "$top_name"
    elif [ -f "$netlist" ] && grep -Eq "^[[:space:]]*module[[:space:]]+${top_name}([[:space:]#(;]|$)" "$netlist" 2>/dev/null; then
        print_health_line "PASS" "top module in netlist" "$top_name"
    else
        print_health_line "WARN" "link_design/top" "could not confirm top=$top_name"
        warn=$((warn + 1))
    fi

    # 3. SDC sanity.
    if [ ! -f "$sdc" ]; then
        print_health_line "FAIL" "constraint.sdc exists" "missing: $sdc"
        fail=$((fail + 1))
    else
        print_health_line "PASS" "constraint.sdc exists" "${sdc#$PROJECT_ROOT/}"

        local n_clock n_in_delay n_out_delay n_false_path
        n_clock=$(count_sdc_command "$sdc" "create_clock")
        n_in_delay=$(count_sdc_command "$sdc" "set_input_delay")
        n_out_delay=$(count_sdc_command "$sdc" "set_output_delay")
        n_false_path=$(count_sdc_command "$sdc" "set_false_path")

        if [ "$n_clock" -gt 0 ]; then
            print_health_line "PASS" "create_clock" "${n_clock} found"
        else
            print_health_line "FAIL" "create_clock" "missing"
            fail=$((fail + 1))
        fi

        if [ "$n_in_delay" -gt 0 ]; then
            print_health_line "PASS" "set_input_delay" "${n_in_delay} found"
        else
            print_health_line "WARN" "set_input_delay" "missing; input-to-reg paths may be optimistic"
            warn=$((warn + 1))
        fi

        if [ "$n_out_delay" -gt 0 ]; then
            print_health_line "PASS" "set_output_delay" "${n_out_delay} found"
        else
            print_health_line "WARN" "set_output_delay" "missing; reg-to-output paths may be optimistic"
            warn=$((warn + 1))
        fi

        if has_broad_false_path "$sdc"; then
            print_health_line "FAIL" "false_path scope" "too broad; may hide real data paths"
            fail=$((fail + 1))
        else
            print_health_line "PASS" "false_path scope" "no broad all-input/output/register false path found"
        fi

        if [ "$n_false_path" -gt 0 ]; then
            print_health_line "INFO" "set_false_path count" "${n_false_path} found; verify intentional paths only"
        fi
    fi

    # 4. Coverage of constrained paths.
    if [ -n "$no_paths_val" ]; then
        print_health_line "FAIL" "constrained timing paths" "No paths found"
        fail=$((fail + 1))
    else
        print_health_line "PASS" "constrained timing paths" "found"
    fi

    if [ -n "$unclocked_val" ]; then
        print_health_line "FAIL" "unclocked registers" "$unclocked_val"
        fail=$((fail + 1))
    else
        print_health_line "PASS" "unclocked registers" "none reported"
    fi

    if [ -n "$unconstrained_val" ]; then
        print_health_line "WARN" "unconstrained endpoints" "$unconstrained_val"
        warn=$((warn + 1))
    else
        print_health_line "PASS" "unconstrained endpoints" "none reported"
    fi

    # 5. Timing value availability.
    local time_unit_label="${10:-ns}"

    if [ -n "$ws_val" ] && [ "$ws_val" != "N/A" ]; then
        print_health_line "PASS" "worst path slack" "${ws_val} ${time_unit_label}"
    elif [ -n "$wns_val" ] && [ "$wns_val" != "N/A" ]; then
        print_health_line "WARN" "worst path slack" "detail missing; WNS=${wns_val} ${time_unit_label}"
        warn=$((warn + 1))
    else
        print_health_line "FAIL" "timing slack parsed" "missing WNS/slack"
        fail=$((fail + 1))
    fi

    echo ""
    if [ "$fail" -gt 0 ]; then
        echo "STA health result : FAIL (${fail} fail, ${warn} warn)"
        echo "Meaning           : Do not trust timing as final until FAIL items are fixed."
    elif [ "$warn" -gt 0 ]; then
        echo "STA health result : WARN (${warn} warn)"
        echo "Meaning           : Timing is usable for exploration, but review warning items."
    else
        echo "STA health result : PASS"
        echo "Meaning           : Synthesis STA constraints look complete for single-clock exploration."
    fi
}

run_synthesis_sta() {
    local run_design="${1:-$DESIGN}"

    local synth_netlist="$PROJECT_ROOT/results/${PLATFORM}/${run_design}/${BASE}/1_synth.v"
    local synth_sdc="$PROJECT_ROOT/platform/${PLATFORM}/${run_design}/constraint.sdc"
    local synth_sta_rpt="$PROJECT_ROOT/reports/${PLATFORM}/${run_design}/${BASE}/synth_sta.rpt"
    local synth_sta_tcl="$PROJECT_ROOT/logs/${PLATFORM}/${run_design}/${BASE}/synth_sta.tcl"

    mkdir -p "$PROJECT_ROOT/reports/${PLATFORM}/${run_design}/${BASE}"
    mkdir -p "$PROJECT_ROOT/logs/${PLATFORM}/${run_design}/${BASE}"

    if [ ! -f "$synth_netlist" ]; then
        echo "Synthesis netlist not found: $synth_netlist"
        return 1
    fi

    if [ ! -f "$synth_sdc" ]; then
        echo "Synthesis SDC not found: $synth_sdc"
        return 1
    fi

    local top_name
    top_name=$(get_design_name_for_dir "$run_design")

    # macOS ships Bash 3.2 by default, which does not support mapfile.
    # Use a Bash-3-compatible read loop instead.
    sta_libs=()
    while IFS= read -r lib; do
        [ -n "$lib" ] && sta_libs+=("$lib")
    done < <(find_platform_sta_libs)

    if [ "${#sta_libs[@]}" -eq 0 ]; then
        echo "ERROR: no suitable Liberty files found under:"
        echo "  $ORFS_ROOT/platforms/${PLATFORM}"
        echo ""
        LIB_COUNT=$(find "$ORFS_ROOT/platforms/${PLATFORM}" -type f -iname "*.lib" 2>/dev/null | wc -l | tr -d " ")
        echo "Existing .lib file count: ${LIB_COUNT}"
        echo "Hint: check ORFS_ROOT and platform directory."
        return 1
    fi

    lefs=()
    while IFS= read -r lef; do
        [ -n "$lef" ] && lefs+=("$lef")
    done < <(find_platform_sta_lefs)

    if [ "${#lefs[@]}" -eq 0 ]; then
        echo "ERROR: no suitable STA LEF/TLEF files found under:"
        echo "  $ORFS_ROOT/platforms/${PLATFORM}"
        echo ""
        LEF_COUNT=$(find "$ORFS_ROOT/platforms/${PLATFORM}" -type f \( -iname "*.lef" -o -iname "*.tlef" \) 2>/dev/null | wc -l | tr -d " ")
        echo "Existing LEF/TLEF file count: ${LEF_COUNT}"
        echo "Hint: check ORFS_ROOT and platform directory."
        return 1
    fi

    local runner_mode sta_project_path
    runner_mode=$(oproad_runner_mode)
    if [ "$runner_mode" = "local" ]; then
        sta_project_path="$PROJECT_ROOT"
    else
        sta_project_path="/project"
    fi

    {
        echo "# Auto-generated by oproad report"
        echo 'puts "========================================"'
        echo 'puts " SYNTHESIS STA"'
        echo 'puts "========================================"'
        echo 'puts "Note: pre-layout STA uses LEF technology + Liberty + gate-level netlist + SDC."'
        echo 'puts ""'

        echo 'puts "========================================"'
        echo 'puts " READ LEF TECHNOLOGY / STDCELL ABSTRACTS"'
        echo 'puts "========================================"'
        echo "puts \"OPROAD_READ_LEF_COUNT=${#lefs[@]}\""

        for lef in "${lefs[@]}"; do
            lef_flow=$(to_flow_path "$lef")
            if [ "$VERBOSE_READS" = "1" ]; then
                echo "puts \"read_lef ${lef_flow}\""
            fi
            echo "read_lef ${lef_flow}"
        done

        echo 'puts ""'
        echo 'puts "========================================"'
        echo 'puts " READ LIBERTY FILES"'
        echo 'puts "========================================"'
        echo "puts \"OPROAD_READ_LIBERTY_COUNT=${#sta_libs[@]}\""

        for lib in "${sta_libs[@]}"; do
            lib_flow=$(to_flow_path "$lib")
            if [ "$VERBOSE_READS" = "1" ]; then
                echo "puts \"read_liberty ${lib_flow}\""
            fi
            echo "read_liberty ${lib_flow}"
        done

        cat <<EOF

puts ""
puts "========================================"
puts " READ NETLIST / LINK DESIGN"
puts "========================================"
read_verilog ${sta_project_path}/results/${PLATFORM}/${run_design}/${BASE}/1_synth.v
link_design ${top_name}

puts ""
puts "========================================"
puts " READ SDC"
puts "========================================"
puts "OPROAD_READ_SDC=${sta_project_path}/platform/${PLATFORM}/${run_design}/constraint.sdc"
read_sdc ${sta_project_path}/platform/${PLATFORM}/${run_design}/constraint.sdc

puts ""
puts "========================================"
puts " SETUP CHECK"
puts "========================================"
check_setup

puts ""
puts "========================================"
puts " SYNTHESIS STA SUMMARY"
puts "========================================"
report_wns
report_tns

puts ""
puts "========================================"
puts " LONGEST SYNTHESIS PATHS"
puts "========================================"
report_checks -path_delay max -fields {slew cap input nets fanout} -digits 4 -group_count 10

puts ""
puts "========================================"
puts " UNCONSTRAINED ENDPOINT DIAGNOSTIC RAW"
puts "========================================"
puts "Note: This raw report is parsed by the outer script. It may include normal clk paths in some OpenROAD/OpenSTA versions."
report_checks -unconstrained -fields {slew cap input nets fanout} -digits 4 -group_count 20

EOF
    } > "$synth_sta_tcl"

    if [ "$runner_mode" = "local" ]; then
        OPENROAD_BIN=$(command -v openroad || find "$ORFS_ROOT/../tools/install" -name openroad -type f 2>/dev/null | head -1)

        if [ -z "$OPENROAD_BIN" ]; then
            echo "ERROR: openroad binary not found in container/local environment."
            return 1
        fi

        "$OPENROAD_BIN" -no_init -exit "$synth_sta_tcl" > "$synth_sta_rpt" 2>&1
        return $?
    fi

    require_command docker "Install Docker Desktop, then retry after Docker is running." || return 127

    docker run --rm -i --platform "$DOCKER_PLATFORM" \
        -v "$ORFS_ROOT":/OpenROAD-flow-scripts/flow \
        -v "$PROJECT_ROOT":/project \
        -w /OpenROAD-flow-scripts/flow \
        "$DOCKER_IMAGE" \
        bash -lc '
            OPENROAD_BIN=$(command -v openroad || find /OpenROAD-flow-scripts/tools/install -name openroad -type f | head -1)

            if [ -z "$OPENROAD_BIN" ]; then
                echo "ERROR: openroad binary not found in Docker image."
                exit 1
            fi

            "$OPENROAD_BIN" -no_init -exit /project/logs/'"${PLATFORM}"'/'"${run_design}"'/'"${BASE}"'/synth_sta.tcl \
                > /project/reports/'"${PLATFORM}"'/'"${run_design}"'/'"${BASE}"'/synth_sta.rpt 2>&1
        '

    return $?
}

###############################################################################
# Netlist / area helpers
###############################################################################

logic_cells() {
    awk '
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_$]*[[:space:]]+[A-Za-z_\\][A-Za-z0-9_$\\]*[[:space:]]*\(/ {
            cell = $1

            if (cell ~ /^(module|endmodule|assign|always|initial|input|output|inout|wire|reg)$/)
                next

            if (cell ~ /^(FILLCELL|FILL|TAPCELL|TAP|DECAP|WELLTAP|ANTENNA)/)
                next

            print cell
        }
    ' "$1" 2>/dev/null
}

core_logic_cells() {
    logic_cells "$1" | grep -vi '^BUF' | grep -vi '^CLKBUF' | grep -vi '^INV'
}

lib_cell_area() {
    local lib_file="$1"
    local cell_name="$2"

    awk -v cell="$cell_name" '
        /^[[:space:]]*cell[[:space:]]*\(/ {
            line = $0
            sub(/^.*cell[[:space:]]*\(/, "", line)
            sub(/\).*$/, "", line)
            current_cell = line
            in_cell = (current_cell == cell)
        }

        in_cell && /^[[:space:]]*area[[:space:]]*:/ {
            line = $0
            sub(/^.*area[[:space:]]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]*;.*/, "", line)
            print line
            exit
        }

        in_cell && /^[[:space:]]*}/ {
            in_cell = 0
        }
    ' "$lib_file"
}

lib_cell_area_any() {
    local cell="$1"

    while IFS= read -r lib; do
        [ -f "$lib" ] || continue
        area=$(lib_cell_area "$lib" "$cell")
        if [ -n "$area" ]; then
            echo "$area"
            return 0
        fi
    done < <(find_platform_area_libs)
}

sum_netlist_cell_area() {
    local netlist="$1"

    logic_cells "$netlist" | sort | uniq -c | \
    while read COUNT CELL; do
        CELL_AREA=$(lib_cell_area_any "$CELL")
        if [ -n "$CELL_AREA" ]; then
            awk "BEGIN {printf \"%.6f\n\", ${COUNT} * ${CELL_AREA}}"
        fi
    done | awk '{sum += $1} END {printf "%.6f", sum}'
}

# Write an area coverage report to a small key-value file.
# The report includes:
#   AREA
#   TOTAL_INST
#   MATCHED_INST
#   UNMATCHED_INST
#   COVERAGE
#   UNMATCHED_FILE
write_area_coverage_report() {
    local netlist="$1"
    local out_file="$2"
    local unmatched_file="${out_file}.unmatched"

    : > "$unmatched_file"

    local total_inst=0
    local matched_inst=0
    local unmatched_inst=0
    local area_sum="0.000000"

    logic_cells "$netlist" | sort | uniq -c | \
    while read COUNT CELL; do
        CELL_AREA=$(lib_cell_area_any "$CELL")

        if [ -n "$CELL_AREA" ]; then
            printf "MATCHED %s %s %s\n" "$COUNT" "$CELL" "$CELL_AREA"
        else
            printf "UNMATCHED %s %s\n" "$COUNT" "$CELL"
        fi
    done | \
    while read KIND COUNT CELL CELL_AREA; do
        total_inst=$((total_inst + COUNT))

        if [ "$KIND" = "MATCHED" ]; then
            matched_inst=$((matched_inst + COUNT))
            area_sum=$(awk "BEGIN {printf \"%.6f\", ${area_sum} + (${COUNT} * ${CELL_AREA})}")
        else
            unmatched_inst=$((unmatched_inst + COUNT))
            echo "$COUNT $CELL" >> "$unmatched_file"
        fi

        echo "AREA=${area_sum}" > "$out_file"
        echo "TOTAL_INST=${total_inst}" >> "$out_file"
        echo "MATCHED_INST=${matched_inst}" >> "$out_file"
        echo "UNMATCHED_INST=${unmatched_inst}" >> "$out_file"

        if [ "$total_inst" -gt 0 ]; then
            COVERAGE=$(awk "BEGIN {printf \"%.2f\", 100.0 * ${matched_inst} / ${total_inst}}")
        else
            COVERAGE="0.00"
        fi

        echo "COVERAGE=${COVERAGE}" >> "$out_file"
        echo "UNMATCHED_FILE=${unmatched_file}" >> "$out_file"
    done

    # If there were no cells at all, make sure the report still exists.
    if [ ! -f "$out_file" ]; then
        echo "AREA=0.000000" > "$out_file"
        echo "TOTAL_INST=0" >> "$out_file"
        echo "MATCHED_INST=0" >> "$out_file"
        echo "UNMATCHED_INST=0" >> "$out_file"
        echo "COVERAGE=0.00" >> "$out_file"
        echo "UNMATCHED_FILE=${unmatched_file}" >> "$out_file"
    fi
}

###############################################################################
# Main command dispatch
###############################################################################

[ $# -lt 1 ] && usage
CMD=$1

###############################################################################
# new
###############################################################################

if [ "$CMD" = "new" ]; then
    [ $# -lt 4 ] && usage

    PLATFORM=$2
    DESIGN=$3
    FREQ=$4
    PARENT_DIR=${5:-$(pwd)}

    if [ ! -d "$ORFS_ROOT/platforms/${PLATFORM}" ]; then
        echo "ERROR: unsupported platform/process: ${PLATFORM}"
        echo ""
        echo "Available platforms:"
        find "$ORFS_ROOT/platforms" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort | sed 's/^/  /'
        exit 1
    fi

    TIME_UNIT_DECL=$(get_platform_time_unit_decl)
    [ -z "$TIME_UNIT_DECL" ] && TIME_UNIT_DECL="1ns"
    TIME_UNIT=$(get_platform_time_unit)
    TIME_SCALE=$(ns_to_platform_time_scale "$TIME_UNIT_DECL")

    PERIOD_NS=$(awk "BEGIN {printf \"%.4f\", 1/${FREQ}}")
    PERIOD=$(awk "BEGIN {printf \"%.4f\", ${PERIOD_NS} * ${TIME_SCALE}}")
    CLK_UNCERT_SETUP=$(awk "BEGIN {printf \"%.4f\", 0.10 * ${TIME_SCALE}}")
    CLK_UNCERT_HOLD=$(awk "BEGIN {printf \"%.4f\", 0.05 * ${TIME_SCALE}}")
    IO_DELAY=$(awk "BEGIN {printf \"%.4f\", 0.05 * ${TIME_SCALE}}")
    INPUT_TRANSITION=$(awk "BEGIN {printf \"%.4f\", 0.05 * ${TIME_SCALE}}")
    MAX_TRANSITION=$(awk "BEGIN {printf \"%.4f\", 0.35 * ${TIME_SCALE}}")

    PARENT_DIR=$(cd "$PARENT_DIR" && pwd)
    PROJECT_ROOT="${PARENT_DIR}/${DESIGN}"

    if [ -e "$PROJECT_ROOT" ]; then
        echo "ERROR: project directory already exists:"
        echo "  $PROJECT_ROOT"
        exit 1
    fi

    mkdir -p "$PROJECT_ROOT/src/rtl"
    mkdir -p "$PROJECT_ROOT/src/tb"
    mkdir -p "$PROJECT_ROOT/src/include"
    mkdir -p "$PROJECT_ROOT/src/scripts"
    mkdir -p "$PROJECT_ROOT/platform/${PLATFORM}/${DESIGN}"
    mkdir -p "$PROJECT_ROOT/results/${PLATFORM}/${DESIGN}"
    mkdir -p "$PROJECT_ROOT/reports/${PLATFORM}/${DESIGN}"
    mkdir -p "$PROJECT_ROOT/logs/${PLATFORM}/${DESIGN}"
    mkdir -p "$PROJECT_ROOT/objects/${PLATFORM}/${DESIGN}"

cat > "$PROJECT_ROOT/.asic_project" <<EOF
PLATFORM=${PLATFORM}
DESIGN=${DESIGN}
FREQ=${FREQ}
PERIOD=${PERIOD}
PERIOD_NS=${PERIOD_NS}
TIME_UNIT=${TIME_UNIT}
EOF

cat > "$PROJECT_ROOT/src/rtl/${DESIGN}.v" <<EOF
module ${DESIGN} (
    input  wire clk,
    input  wire rst_n,
    input  wire [7:0] a,
    input  wire [7:0] b,
    output reg  [8:0] y
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        y <= 0;
    else
        y <= a + b;
end

endmodule
EOF

cat > "$PROJECT_ROOT/src/tb/tb_${DESIGN}.v" <<EOF
\`timescale 1ns/1ps

module tb_${DESIGN};

reg clk;
reg rst_n;
reg [7:0] a;
reg [7:0] b;
wire [8:0] y;

${DESIGN} dut (
    .clk(clk),
    .rst_n(rst_n),
    .a(a),
    .b(b),
    .y(y)
);

always #5 clk = ~clk;

initial begin
    \$dumpfile("src/tb/${DESIGN}.vcd");
    \$dumpvars(0, tb_${DESIGN});

    clk = 0;
    rst_n = 0;
    a = 0;
    b = 0;

    #20 rst_n = 1;
    #10 a = 8'd10;  b = 8'd20;
    #10 a = 8'd5;   b = 8'd7;
    #10 a = 8'd100; b = 8'd50;
    #10 a = 8'd255; b = 8'd1;
    #50 \$finish;
end

endmodule
EOF

cat > "$PROJECT_ROOT/platform/${PLATFORM}/${DESIGN}/constraint.sdc" <<EOF
# Platform Liberty time_unit: "${TIME_UNIT_DECL}".
# Target ${FREQ} GHz = ${PERIOD_NS} ns = ${PERIOD} ${TIME_UNIT}.
create_clock -name clk -period ${PERIOD} [get_ports clk]

set_clock_uncertainty -setup ${CLK_UNCERT_SETUP} [get_clocks clk]
set_clock_uncertainty -hold  ${CLK_UNCERT_HOLD} [get_clocks clk]

set_false_path -from [get_ports rst_n]

set_input_delay  ${IO_DELAY} -clock clk [get_ports {a b}]
set_output_delay ${IO_DELAY} -clock clk [all_outputs]

# PDK-independent input model.
# Avoid hard-coding cells such as BUF_X4.
set_input_transition ${INPUT_TRANSITION} [get_ports {a b rst_n}]
set_load 0.05 [all_outputs]

set_max_transition ${MAX_TRANSITION} [current_design]
set_max_fanout 20 [current_design]
EOF

PDN_MIN_DIE_AREA=""
PDN_MIN_CORE_AREA=""
PDN_MIN_PLACE_DENSITY=""

case "$PLATFORM" in
    nangate15)
        PDN_MIN_DIE_AREA="0 0 80 80"
        PDN_MIN_CORE_AREA="8 7.68 72 72.96"
        PDN_MIN_PLACE_DENSITY="0.30"
        ;;
    nangate45)
        PDN_MIN_DIE_AREA="0 0 80 80"
        PDN_MIN_CORE_AREA="8 8.4 72 71.4"
        PDN_MIN_PLACE_DENSITY="0.20"
        ;;
esac

if [ -n "$PDN_MIN_DIE_AREA" ]; then
    FLOORPLAN_CONFIG=$(cat <<EOF_FLOORPLAN
# Tiny demo designs can auto-floorplan too small for the default PDN grid.
# Use an explicit minimum core so power straps fit during implement.
export CORE_UTILIZATION =
export DIE_AREA  = ${PDN_MIN_DIE_AREA}
export CORE_AREA = ${PDN_MIN_CORE_AREA}
export PLACE_DENSITY    = ${PDN_MIN_PLACE_DENSITY}
EOF_FLOORPLAN
)
else
    FLOORPLAN_CONFIG=$(cat <<'EOF_FLOORPLAN'
export CORE_UTILIZATION = 50
export PLACE_DENSITY    = 0.60
EOF_FLOORPLAN
)
fi

cat > "$PROJECT_ROOT/platform/${PLATFORM}/${DESIGN}/config.mk" <<EOF
export PLATFORM      = ${PLATFORM}
export DESIGN_NAME   = ${DESIGN}

export VERILOG_FILES = \\
    \$(wildcard ./designs/src/${DESIGN}/rtl/*.v)

export SDC_FILE = \\
    ./designs/${PLATFORM}/${DESIGN}/constraint.sdc

${FLOORPLAN_CONFIG}

export DESIGN_VCD = ./designs/src/${DESIGN}/tb/${DESIGN}.vcd
EOF

cat > "$PROJECT_ROOT/README.md" <<EOF
# ${DESIGN}

Platform: ${PLATFORM}

Target frequency: ${FREQ} GHz

Clock period: ${PERIOD} ${TIME_UNIT} (${PERIOD_NS} ns)

## Basic Commands

\`\`\`bash
oproad sim
oproad synth
oproad implement
oproad report
oproad clean
\`\`\`
EOF

    echo ""
    echo "========================================"
    echo "PROJECT CREATED"
    echo "========================================"
    echo "Project  : $PROJECT_ROOT"
    echo "Design   : $DESIGN"
    echo "Platform : $PLATFORM"
    echo "Target   : $FREQ GHz"
    echo "Period   : $PERIOD ${TIME_UNIT} (${PERIOD_NS} ns)"
    echo ""

    exit 0
fi

###############################################################################
# sim
###############################################################################

if [ "$CMD" = "sim" ]; then
    find_project "$2"
    cd "$PROJECT_ROOT" || exit 1

    RTL_FILES=(src/rtl/*.v)
    TB_FILE="src/tb/tb_${DESIGN}.v"

    if [ ! -f "$TB_FILE" ]; then
        echo "ERROR: testbench not found:"
        echo "  $TB_FILE"
        echo ""
        echo "Available testbenches:"
        ls src/tb/*.v 2>/dev/null || true
        exit 1
    fi

    require_command iverilog "Install Icarus Verilog, for example: brew install icarus-verilog" || exit 127
    require_command vvp "Install Icarus Verilog, for example: brew install icarus-verilog" || exit 127

    echo ""
    echo "========================================"
    echo "RTL SIMULATION"
    echo "========================================"
    echo "RTL files:"
    printf "  %s\n" "${RTL_FILES[@]}"
    echo "Testbench:"
    echo "  $TB_FILE"
    echo ""

    iverilog -g2012 -o src/tb/sim.out "${RTL_FILES[@]}" "$TB_FILE" || exit 1
    vvp src/tb/sim.out || exit 1

    echo ""
    echo "Simulation finished."
    echo "VCD: src/tb/${DESIGN}.vcd"
    echo ""

    exit 0
fi

###############################################################################
# synth
###############################################################################

if [ "$CMD" = "synth" ]; then
    find_project "$2"

    echo ""
    echo "========================================"
    echo "SYNTHESIS ONLY"
    echo "========================================"

    run_docker_make "synth"
    exit $?
fi

###############################################################################
# implement / run
###############################################################################

if [ "$CMD" = "implement" ] || [ "$CMD" = "run" ]; then
    find_project "$2"

    echo ""
    echo "========================================"
    echo "STAGE 1: SYNTHESIS"
    echo "========================================"
    run_docker_make "synth" || exit 1

    echo ""
    echo "========================================"
    echo "STAGE 2: FLOORPLAN"
    echo "========================================"
    run_docker_make "do-floorplan" || exit 1

    echo ""
    echo "========================================"
    echo "STAGE 3: PLACEMENT"
    echo "========================================"
    run_docker_make "do-place" || exit 1

    echo ""
    echo "========================================"
    echo "STAGE 4: CTS"
    echo "========================================"
    run_docker_make "do-cts" || exit 1

    echo ""
    echo "========================================"
    echo "STAGE 5: ROUTING"
    echo "========================================"
    run_docker_make "do-route" || exit 1

    echo ""
    echo "========================================"
    echo "STAGE 6: FINISH"
    echo "========================================"
    run_finish_stage || exit 1

    echo ""
    echo "========================================"
    echo "IMPLEMENTATION FINISHED"
    echo "========================================"

    exit 0
fi

###############################################################################
# clean
###############################################################################

if [ "$CMD" = "clean" ]; then
    find_project "$2"

    echo ""
    echo "========================================"
    echo "CLEAN PROJECT & ORFS FILES"
    echo "========================================"
    echo "Project: $PROJECT_ROOT"

    echo ""
    echo "Removing optional ORFS run cache directories..."
    remove_if_exists "$ORFS_ROOT/runs/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/runs/${PLATFORM}/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/runs/${PLATFORM}/${DESIGN}_${BASE}"
    remove_if_exists "$ORFS_ROOT/runs/${DESIGN}_${BASE}"

    echo ""
    echo "Removing ORFS current project copy..."
    remove_if_exists "$ORFS_ROOT/designs/src/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/designs/${PLATFORM}/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/results/${PLATFORM}/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/reports/${PLATFORM}/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/logs/${PLATFORM}/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/objects/${PLATFORM}/${DESIGN}"

    echo ""
    echo "Removing local generated project directories..."
    remove_if_exists "$PROJECT_ROOT/results/${PLATFORM}/${DESIGN}"
    remove_if_exists "$PROJECT_ROOT/reports/${PLATFORM}/${DESIGN}"
    remove_if_exists "$PROJECT_ROOT/logs/${PLATFORM}/${DESIGN}"
    remove_if_exists "$PROJECT_ROOT/objects/${PLATFORM}/${DESIGN}"

    echo ""
    echo "Recreating local generated directories..."
    mkdir -p "$PROJECT_ROOT/results/${PLATFORM}/${DESIGN}"
    mkdir -p "$PROJECT_ROOT/reports/${PLATFORM}/${DESIGN}"
    mkdir -p "$PROJECT_ROOT/logs/${PLATFORM}/${DESIGN}"
    mkdir -p "$PROJECT_ROOT/objects/${PLATFORM}/${DESIGN}"

    echo "  created: $PROJECT_ROOT/results/${PLATFORM}/${DESIGN}"
    echo "  created: $PROJECT_ROOT/reports/${PLATFORM}/${DESIGN}"
    echo "  created: $PROJECT_ROOT/logs/${PLATFORM}/${DESIGN}"
    echo "  created: $PROJECT_ROOT/objects/${PLATFORM}/${DESIGN}"

    echo ""
    echo "Removing simulation artifacts..."
    remove_if_exists "$PROJECT_ROOT/src/tb/sim.out"

    if ls "$PROJECT_ROOT/src/tb/"*.vcd >/dev/null 2>&1; then
        for VCD in "$PROJECT_ROOT/src/tb/"*.vcd; do
            remove_if_exists "$VCD"
        done
    else
        echo "  skipped: $PROJECT_ROOT/src/tb/*.vcd"
    fi

    echo ""
    echo "Clean finished."
    echo ""

    exit 0
fi

###############################################################################
# delete
###############################################################################

if [ "$CMD" = "delete" ]; then
    find_project "$2"

    echo ""
    echo "========================================"
    echo "DELETE PROJECT"
    echo "========================================"
    echo "Project: $PROJECT_ROOT"

    echo ""
    echo "Removing optional ORFS run cache directories..."
    remove_if_exists "$ORFS_ROOT/runs/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/runs/${PLATFORM}/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/runs/${PLATFORM}/${DESIGN}_${BASE}"
    remove_if_exists "$ORFS_ROOT/runs/${DESIGN}_${BASE}"

    echo ""
    echo "Removing ORFS current project copy..."
    remove_if_exists "$ORFS_ROOT/designs/src/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/designs/${PLATFORM}/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/results/${PLATFORM}/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/reports/${PLATFORM}/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/logs/${PLATFORM}/${DESIGN}"
    remove_if_exists "$ORFS_ROOT/objects/${PLATFORM}/${DESIGN}"

    echo ""
    echo "Removing entire local project directory..."
    remove_if_exists "$PROJECT_ROOT"

    echo ""
    echo "Project deleted."
    echo ""

    exit 0
fi

###############################################################################
# report
###############################################################################

if [ "$CMD" = "report" ]; then
    find_project "$2"

    ACTIVE_DESIGN="$DESIGN"
    REPORT_DIR="$PROJECT_ROOT/reports/${PLATFORM}/${ACTIVE_DESIGN}/${BASE}"
    LOG_DIR="$PROJECT_ROOT/logs/${PLATFORM}/${ACTIVE_DESIGN}/${BASE}"
    RESULT_DIR="$PROJECT_ROOT/results/${PLATFORM}/${ACTIVE_DESIGN}/${BASE}"

    CLOCK_FILE="${RESULT_DIR}/clock_period.txt"
    SDC_FILE="$PROJECT_ROOT/platform/${PLATFORM}/${ACTIVE_DESIGN}/constraint.sdc"
    LIB_FILE=$(find_platform_single_lib_for_display)
    TIME_UNIT_DECL=$(get_platform_time_unit_decl)
    [ -z "$TIME_UNIT_DECL" ] && TIME_UNIT_DECL="1ns"
    TIME_UNIT=$(get_platform_time_unit)
    TIME_TO_NS=$(time_unit_decl_to_ns "$TIME_UNIT_DECL")

    if [ -f "${RESULT_DIR}/6_final.v" ] && [ -f "${REPORT_DIR}/6_finish.rpt" ]; then
        REPORT_STAGE="POST-ROUTE"
        TIMING_RPT="${REPORT_DIR}/6_finish.rpt"
        NETLIST="${RESULT_DIR}/6_final.v"
        REPORT_LOG="${LOG_DIR}/6_report.log"
        STAT_RPT="${REPORT_DIR}/6_finish.rpt"
    elif [ -f "${RESULT_DIR}/1_synth.v" ]; then
        REPORT_STAGE="SYNTHESIS"
        NETLIST="${RESULT_DIR}/1_synth.v"
        REPORT_LOG="${LOG_DIR}/1_1_yosys.log"
        STAT_RPT="${REPORT_DIR}/synth_stat.txt"

        if ! run_synthesis_sta "$ACTIVE_DESIGN"; then
            echo ""
            echo "Warning: synthesis STA failed. See:"
            echo "  reports/${PLATFORM}/${ACTIVE_DESIGN}/${BASE}/synth_sta.rpt"
        fi

        TIMING_RPT="${REPORT_DIR}/synth_sta.rpt"
    else
        echo ""
        echo "ERROR: No synthesis or implementation result found in the strict project directory."
        echo ""
        echo "Expected:"
        echo "  ${RESULT_DIR}/1_synth.v"
        echo "or:"
        echo "  ${RESULT_DIR}/6_final.v"
        echo ""
        echo "Available result files under current project/platform:"
        find "$PROJECT_ROOT/results/${PLATFORM}" -path "*/${BASE}/1_synth.v" -o -path "*/${BASE}/6_final.v" 2>/dev/null || true
        echo ""
        echo "Please run:"
        echo "  oproad synth"
        echo "or:"
        echo "  oproad implement"
        echo ""
        exit 1
    fi

    echo ""
    echo "========================================"
    echo "PROJECT  : $PROJECT_ROOT"
    echo "PLATFORM : $PLATFORM"
    echo "DESIGN   : $ACTIVE_DESIGN"
    echo "TOP      : $(get_design_name_for_dir "$ACTIVE_DESIGN")"
    echo "STAGE    : $REPORT_STAGE"
    echo "========================================"

    echo ""
    echo "========== TIMING =========="

    if [ -n "$TIMING_RPT" ] && [ -f "$TIMING_RPT" ]; then
        TNS=$(extract_last_numeric_for_key "tns" "$TIMING_RPT")
        WNS=$(extract_last_numeric_for_key "wns" "$TIMING_RPT")
        WS=$(extract_first_slack "$TIMING_RPT")

        if [ -z "$WS" ]; then
            WS=$(extract_worst_slack_line "$TIMING_RPT")
        fi

        NO_PATHS=$(grep -i "No paths found" "$TIMING_RPT" 2>/dev/null | tail -1)
        UNCLOCKED=$(grep -i "unclocked register/latch pins" "$TIMING_RPT" 2>/dev/null | tail -1)
        UNCONSTRAINED=$(grep -i "unconstrained endpoints" "$TIMING_RPT" 2>/dev/null | tail -1)

        if [ -z "$WS" ] && [ -z "$NO_PATHS" ] && [ -n "$WNS" ]; then
            WS="$WNS"
        fi

        # Some OpenROAD reports include "No paths found" for secondary groups or
        # diagnostics even when the main setup report has valid slack. Treat a
        # parsed slack/WNS value as evidence that constrained paths exist.
        if { [ -n "$WS" ] && [ "$WS" != "N/A" ]; } || { [ -n "$WNS" ] && [ "$WNS" != "N/A" ]; }; then
            NO_PATHS=""
        fi
    else
        TNS="N/A"
        WNS="N/A"
        WS="N/A"
        NO_PATHS=""
        UNCLOCKED=""
        UNCONSTRAINED=""
    fi

    echo "TNS summary        : ${TNS:-N/A} ${TIME_UNIT}"
    echo "WNS summary        : ${WNS:-N/A} ${TIME_UNIT}"
    echo "Worst path slack   : ${WS:-N/A} ${TIME_UNIT}"

    if [ "$REPORT_STAGE" = "SYNTHESIS" ]; then
        echo "Note        : synthesis STA is pre-layout and does not include routed parasitics."
        echo "STA report  : reports/${PLATFORM}/${ACTIVE_DESIGN}/${BASE}/synth_sta.rpt"

        if [ -n "$NO_PATHS" ]; then
            echo "Warning     : No constrained timing paths found. Check constraint.sdc."
        fi

        if [ -n "$UNCLOCKED" ]; then
            echo "Warning     : $UNCLOCKED"
        fi

        if [ -n "$UNCONSTRAINED" ]; then
            echo "Setup check : $UNCONSTRAINED"
            echo "Note        : This warning is from check_setup."
            summarize_unconstrained_endpoints "$TIMING_RPT" 20
        fi

        if { [ -z "$TNS" ] && [ -z "$WNS" ] && [ -z "$WS" ]; } || [ -n "$NO_PATHS" ]; then
            show_sta_diagnostics "$TIMING_RPT"
        fi
    fi

    show_sta_health_check "$TIMING_RPT" "$SDC_FILE" "$(get_design_name_for_dir "$ACTIVE_DESIGN")" "$NETLIST" "${WS:-N/A}" "${WNS:-N/A}" "$NO_PATHS" "$UNCLOCKED" "$UNCONSTRAINED" "$TIME_UNIT"

    echo ""
    echo "========== CONSTRAINT HEALTH =========="

    if [ -n "$NO_PATHS" ]; then
        echo "Constrained paths : NOT FOUND"
        echo "Action            : Check create_clock and I/O delays in constraint.sdc."
    else
        echo "Constrained paths : FOUND"
    fi

    if [ -n "$UNCONSTRAINED" ]; then
        echo "Unconstrained note: $UNCONSTRAINED"
        echo "Action            : Review the likely endpoint list above."
    else
        echo "Unconstrained note: none reported by check_setup"
    fi

    echo ""
    echo "========== CRITICAL PATH =========="

    CLOCK_PERIOD=$(extract_clock_period "$CLOCK_FILE" "$SDC_FILE")

    if [ -n "$CLOCK_PERIOD" ]; then
        if [ "$TIME_UNIT" = "ns" ]; then
            echo "Target clock period : ${CLOCK_PERIOD} ${TIME_UNIT}"
        else
            CLOCK_PERIOD_NS=$(awk "BEGIN {printf \"%.4f\", ${CLOCK_PERIOD} * ${TIME_TO_NS}}")
            echo "Target clock period : ${CLOCK_PERIOD} ${TIME_UNIT} (${CLOCK_PERIOD_NS} ns)"
        fi
    else
        echo "Target clock period : N/A"
    fi

    if [ -n "$NO_PATHS" ]; then
        echo "Critical path data  : N/A"
        echo "Estimated Fmax      : N/A"
        echo "Reason              : No constrained timing paths found."
    else
        SLACK_FOR_DELAY=""

        if [ -n "$WS" ] && [ "$WS" != "N/A" ]; then
            SLACK_FOR_DELAY="$WS"
        elif [ -n "$WNS" ] && [ "$WNS" != "N/A" ]; then
            SLACK_FOR_DELAY="$WNS"
        fi

        if [ -n "$CLOCK_PERIOD" ] && [ -n "$SLACK_FOR_DELAY" ]; then
            CRITICAL_DELAY=$(awk "BEGIN {d=${CLOCK_PERIOD}-(${SLACK_FOR_DELAY}); if (d < 0) d=0; printf \"%.4f\", d}")

            if awk "BEGIN {exit !(${CRITICAL_DELAY} > 0)}"; then
                CRITICAL_DELAY_NS=$(awk "BEGIN {printf \"%.6f\", ${CRITICAL_DELAY} * ${TIME_TO_NS}}")
                MAX_FREQ_MHZ=$(awk "BEGIN {printf \"%.2f\", 1000/${CRITICAL_DELAY_NS}}")
                MAX_FREQ_GHZ=$(awk "BEGIN {printf \"%.4f\", 1/${CRITICAL_DELAY_NS}}")

                if [ "$TIME_UNIT" = "ns" ]; then
                    echo "Critical path delay : ${CRITICAL_DELAY} ${TIME_UNIT}"
                else
                    echo "Critical path delay : ${CRITICAL_DELAY} ${TIME_UNIT} (${CRITICAL_DELAY_NS} ns)"
                fi
                echo "Estimated Fmax      : ${MAX_FREQ_MHZ} MHz (${MAX_FREQ_GHZ} GHz)"
                echo "Slack used          : ${SLACK_FOR_DELAY} ${TIME_UNIT}"
            else
                echo "Critical path delay : 0.0000 ${TIME_UNIT}"
                echo "Estimated Fmax      : N/A"
            fi
        else
            echo "Critical path data  : N/A"
            echo "Estimated Fmax      : N/A"
        fi
    fi

    echo ""
    echo "========== WORST PATH SUMMARY =========="

    if [ -n "$NO_PATHS" ]; then
        echo "No constrained worst path was reported."
        echo "Use the diagnostics above to debug missing SDC constraints."
    elif [ -n "$TIMING_RPT" ] && [ -f "$TIMING_RPT" ]; then
        grep -nE "Startpoint:|Endpoint:|data arrival time|slack \((MET|VIOLATED)\)" "$TIMING_RPT" | head -20

        START_LINE=$(grep -n "Startpoint:" "$TIMING_RPT" | head -1 | cut -d: -f1)
        if [ -n "$START_LINE" ]; then
            END_LINE=$(awk -v start="$START_LINE" '
                NR >= start && /slack \((MET|VIOLATED)\)/ {
                    print NR
                    exit
                }
            ' "$TIMING_RPT")

            if [ -n "$END_LINE" ]; then
                echo ""
                echo "Full path command:"
                echo "  sed -n '${START_LINE},${END_LINE}p' ${TIMING_RPT#$PROJECT_ROOT/}"
            fi
        fi
    else
        echo "Timing report not found."
    fi

    echo ""
    echo "========== AREA =========="

    AREA=""
    UTIL="N/A"
    AREA_SOURCE="N/A"
    AREA_TOTAL_INST="0"
    AREA_MATCHED_INST="0"
    AREA_UNMATCHED_INST="0"
    AREA_COVERAGE="0.00"
    AREA_UNMATCHED_FILE=""

    AREA_REPORT="${REPORT_DIR}/area_coverage.txt"

    if [ -f "$NETLIST" ]; then
        write_area_coverage_report "$NETLIST" "$AREA_REPORT"

        AREA=$(grep "^AREA=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)
        AREA_TOTAL_INST=$(grep "^TOTAL_INST=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)
        AREA_MATCHED_INST=$(grep "^MATCHED_INST=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)
        AREA_UNMATCHED_INST=$(grep "^UNMATCHED_INST=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)
        AREA_COVERAGE=$(grep "^COVERAGE=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)
        AREA_UNMATCHED_FILE=$(grep "^UNMATCHED_FILE=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)

        AREA_SOURCE="summed from netlist cell areas using multi-Liberty lookup"
    fi

    if [ "$REPORT_STAGE" = "POST-ROUTE" ]; then
        AREA_LINE=$(grep "Design area" "$REPORT_LOG" "$TIMING_RPT" 2>/dev/null | tail -1)
        UTIL=$(echo "$AREA_LINE" | grep -oE '[0-9]+% utilization')
    fi

    echo "Design area         : ${AREA:-N/A} μm²"
    echo "Area source         : ${AREA_SOURCE}"
    echo "Area-matched cells  : ${AREA_MATCHED_INST:-0}"
    echo "Area-unmatched cells: ${AREA_UNMATCHED_INST:-0}"
    echo "Area coverage       : ${AREA_COVERAGE:-0.00}%"

    if [ "$REPORT_STAGE" = "SYNTHESIS" ]; then
        echo "Utilization         : N/A for synthesis-only"
        echo "Note                : Utilization requires floorplan/placement information."
        echo "                      Run 'oproad implement' for post-route physical utilization."
    else
        echo "Utilization         : ${UTIL:-N/A}"
    fi

    if [ -n "$LIB_FILE" ]; then
        echo "Liberty hint        : ${LIB_FILE#$ORFS_ROOT/}"
        echo "Liberty mode        : strict libs first, then non-FAKE fallback for area"
    else
        echo "Liberty hint        : N/A"
    fi

    if [ -n "$AREA_UNMATCHED_FILE" ] && [ -f "$AREA_UNMATCHED_FILE" ] && [ "${AREA_UNMATCHED_INST:-0}" != "0" ]; then
        echo ""
        echo "Top unmatched cells for area:"
        sort -nr "$AREA_UNMATCHED_FILE" | head -10 | \
        while read COUNT CELL; do
            printf "%6s  %s\n" "$COUNT" "$CELL"
        done
    fi

    echo ""
    echo "========== SEQUENTIAL / LOGIC CELLS =========="

    DFF_COUNT=$(logic_cells "$NETLIST" | grep -Ei 'DFF|SDFF|DFX|LATCH|LAT' | wc -l | tr -d ' ')
    STD_CELL_COUNT=$(logic_cells "$NETLIST" | wc -l | tr -d ' ')
    CORE_LOGIC_COUNT=$(core_logic_cells "$NETLIST" | wc -l | tr -d ' ')

    echo "DFF-like cells             : ${DFF_COUNT}"
    echo "Standard cells             : ${STD_CELL_COUNT}"
    echo "Core logic cells no BUF/INV: ${CORE_LOGIC_COUNT}"
    echo "Note: DFF-like cell count is register count, not exact pipeline depth."

    echo ""
    echo "========== NAND2 EQUIVALENT =========="

    if [ -n "$AREA" ]; then
        NAND_PAIR=$(find_nand2_cell_any)

        if [ -n "$NAND_PAIR" ]; then
            NAND_LIB="${NAND_PAIR%%|*}"
            NAND2_CELL="${NAND_PAIR##*|}"
            NAND2_AREA=$(lib_cell_area "$NAND_LIB" "$NAND2_CELL")
        else
            NAND2_AREA=""
        fi

        if [ -n "$NAND2_AREA" ]; then
            NAND_EQ=$(awk "BEGIN {printf \"%.2f\", ${AREA}/${NAND2_AREA}}")
            echo "${NAND2_CELL} area              : ${NAND2_AREA} μm²"
            echo "Estimated NAND2 equivalent : ${NAND_EQ}"
            echo "NAND2 Liberty              : ${NAND_LIB#$ORFS_ROOT/}"
            echo "Note: NAND2 equivalent = summed standard-cell area / ${NAND2_CELL} area."
        else
            echo "NAND2-like cell area not found in platform Liberty files."
        fi
    else
        echo "NAND2 equivalent unavailable."
    fi

    echo ""
    echo "========== POWER SUMMARY =========="

    if [ "$REPORT_STAGE" = "POST-ROUTE" ]; then
        POWER_JSON="${LOG_DIR}/6_report.json"

        if [ ! -f "$POWER_JSON" ]; then
            POWER_JSON="${LOG_DIR}/5_1_grt.json"
        fi

        if [ -f "$POWER_JSON" ]; then
            INTERNAL=$(grep -E '"[^"]*power__internal__total"' "$POWER_JSON" | tail -1 | awk -F ':' '{print $2}' | tr -d ' ,')
            SWITCHING=$(grep -E '"[^"]*power__switching__total"' "$POWER_JSON" | tail -1 | awk -F ':' '{print $2}' | tr -d ' ,')
            LEAKAGE=$(grep -E '"[^"]*power__leakage__total"' "$POWER_JSON" | tail -1 | awk -F ':' '{print $2}' | tr -d ' ,')

            TOTAL=$(awk "BEGIN {printf \"%.8f\", ${INTERNAL:-0}+${SWITCHING:-0}+${LEAKAGE:-0}}")

            INTERNAL_MW=$(awk "BEGIN {printf \"%.4f\", ${INTERNAL:-0}*1000}")
            SWITCHING_MW=$(awk "BEGIN {printf \"%.4f\", ${SWITCHING:-0}*1000}")
            LEAKAGE_MW=$(awk "BEGIN {printf \"%.4f\", ${LEAKAGE:-0}*1000}")
            TOTAL_MW=$(awk "BEGIN {printf \"%.4f\", ${TOTAL:-0}*1000}")

            echo "Internal power  : ${INTERNAL_MW} mW"
            echo "Switching power : ${SWITCHING_MW} mW"
            echo "Leakage power   : ${LEAKAGE_MW} mW"
            echo "Total power     : ${TOTAL_MW} mW"
            echo "Note: raw OpenROAD power values are in W; this script reports mW."
            echo "Note: power accuracy depends on switching activity."
        else
            echo "Power report not found."
        fi
    else
        echo "N/A for synthesis-only report."
        echo "Run 'oproad implement' for post-route power estimate."
    fi

    echo ""
    echo "========== TOP 10 STANDARD CELLS WITH AREA =========="

    logic_cells "$NETLIST" | sort | uniq -c | sort -nr | head -10 | \
    while read COUNT CELL; do
        CELL_AREA=$(lib_cell_area_any "$CELL")

        if [ -n "$CELL_AREA" ]; then
            TOTAL_CELL_AREA=$(awk "BEGIN {printf \"%.3f\", ${COUNT}*${CELL_AREA}}")
            printf "%6s  %-32s  area/cell = %-10s μm²  total = %s μm²\n" \
                "$COUNT" "$CELL" "$CELL_AREA" "$TOTAL_CELL_AREA"
        else
            printf "%6s  %-32s  area/cell = N/A\n" "$COUNT" "$CELL"
        fi
    done

    echo ""
    echo "========================================"
    exit 0
fi

usage
