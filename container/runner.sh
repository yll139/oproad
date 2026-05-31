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
OPROAD_REUSE_OUTPUTS=${OPROAD_REUSE_OUTPUTS:-1}
OPROAD_REPORT_DEEP_CHECKS=${OPROAD_REPORT_DEEP_CHECKS:-0}

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
    echo "Environment:"
    echo "  OPROAD_REUSE_OUTPUTS  reuse project results/logs/reports/objects before make, default: 1"
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

reuse_outputs_enabled() {
    case "$OPROAD_REUSE_OUTPUTS" in
        0|false|FALSE|no|NO|off|OFF)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

sync_project_outputs_to_orfs() {
    reuse_outputs_enabled || return 0

    local any=0

    for dir in results reports logs objects; do
        if [ -d "$PROJECT_ROOT/${dir}/${PLATFORM}/${DESIGN}" ]; then
            any=1
            mkdir -p "$ORFS_ROOT/${dir}/${PLATFORM}/${DESIGN}"
            rsync -a --delete \
                "$PROJECT_ROOT/${dir}/${PLATFORM}/${DESIGN}/" \
                "$ORFS_ROOT/${dir}/${PLATFORM}/${DESIGN}/" || {
                    echo "ERROR: rsync cached ${dir} failed" >&2
                    return 1
                }
            echo "  reused cached ${dir}/${PLATFORM}/${DESIGN}"
        fi
    done

    if [ "$any" -eq 1 ]; then
        echo "  existing project outputs are available to make dependency checks"
    fi
}

run_docker_make() {
    TARGETS=("$@")

    sync_project_to_orfs
    sync_project_outputs_to_orfs || return 1
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

find_run_area_libs() {
    local run_design="${1:-${DESIGN:-}}"
    local object_lib_dir=""

    if [ -n "${PROJECT_ROOT:-}" ] && [ -n "${PLATFORM:-}" ] && [ -n "$run_design" ]; then
        object_lib_dir="$PROJECT_ROOT/objects/${PLATFORM}/${run_design}/${BASE}/lib"
    fi

    {
        if [ -n "$object_lib_dir" ] && [ -d "$object_lib_dir" ]; then
            find "$object_lib_dir" -type f -iname "*.lib" 2>/dev/null | \
                grep -Evi 'FAKE|fake' | sort
        fi
        find_platform_area_libs
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
    done < <(find_run_area_libs)
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

extract_path_slack_for_delay() {
    local delay_type="$1"
    local file="$2"

    awk -v delay_type="$delay_type" '
        BEGIN { IGNORECASE = 1; in_section = 0 }
        {
            lower = tolower($0)

            if (lower ~ /report_checks/ && lower ~ /-path_delay/) {
                if (lower ~ "-path_delay[[:space:]]+" delay_type) {
                    in_section = 1
                } else if (in_section) {
                    exit
                }
            }

            if (in_section && /slack[[:space:]]+\((MET|VIOLATED)\)/) {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[-+]?[0-9]+(\.[0-9]+)?$/) {
                        print $i
                        exit
                    }
                }
            }
        }
    ' "$file" 2>/dev/null
}

extract_worst_path_slack_for_type() {
    local path_type="$1"
    local file="$2"

    awk -v path_type="$path_type" '
        function reset_path() {
            in_path = 0
            current_type = ""
        }
        function first_numeric_text(    i) {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[-+]?[0-9]+(\.[0-9]+)?$/) {
                    return $i
                }
            }
            return ""
        }
        BEGIN {
            IGNORECASE = 1
            target = tolower(path_type)
            reset_path()
        }
        /^[[:space:]]*Startpoint:/ {
            reset_path()
            in_path = 1
            next
        }
        in_path && /^[[:space:]]*Path Type:/ {
            line = tolower($0)
            sub(/^.*path type:[[:space:]]*/, "", line)
            split(line, parts, /[[:space:]]+/)
            current_type = parts[1]
            next
        }
        in_path && /slack[[:space:]]+\((MET|VIOLATED)\)/ {
            slack_text = first_numeric_text()
            if (slack_text != "" && current_type == target) {
                slack_value = slack_text + 0
                if (!found || slack_value < worst_value) {
                    worst_value = slack_value
                    worst_text = slack_text
                    found = 1
                }
            }
            reset_path()
        }
        END {
            if (found) print worst_text
        }
    ' "$file" 2>/dev/null
}

extract_worst_path_arrival_for_type() {
    local path_type="$1"
    local file="$2"

    awk -v path_type="$path_type" '
        function reset_path() {
            in_path = 0
            current_type = ""
            arrival_text = ""
        }
        function first_numeric_text(    i) {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[-+]?[0-9]+(\.[0-9]+)?$/) {
                    return $i
                }
            }
            return ""
        }
        BEGIN {
            IGNORECASE = 1
            target = tolower(path_type)
            reset_path()
        }
        /^[[:space:]]*Startpoint:/ {
            reset_path()
            in_path = 1
            next
        }
        in_path && /^[[:space:]]*Path Type:/ {
            line = tolower($0)
            sub(/^.*path type:[[:space:]]*/, "", line)
            split(line, parts, /[[:space:]]+/)
            current_type = parts[1]
            next
        }
        in_path && /data arrival time/ {
            value_text = first_numeric_text()
            if (value_text != "" && (value_text + 0) >= 0) {
                arrival_text = value_text
            }
            next
        }
        in_path && /slack[[:space:]]+\((MET|VIOLATED)\)/ {
            slack_text = first_numeric_text()
            if (slack_text != "" && arrival_text != "" && current_type == target) {
                slack_value = slack_text + 0
                if (!found || slack_value < worst_value) {
                    worst_value = slack_value
                    worst_arrival = arrival_text
                    found = 1
                }
            }
            reset_path()
        }
        END {
            if (found) print worst_arrival
        }
    ' "$file" 2>/dev/null
}

extract_worst_path_slack_all() {
    local file="$1"

    awk '
        /slack[[:space:]]+\((MET|VIOLATED)\)/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[-+]?[0-9]+(\.[0-9]+)?$/) {
                    val = $i + 0
                    if (!found || val < worst) {
                        worst = val
                        worst_text = $i
                        found = 1
                    }
                    break
                }
            }
        }
        END {
            if (found) print worst_text
        }
    ' "$file" 2>/dev/null
}

has_timing_path_type() {
    local path_type="$1"
    local file="$2"

    grep -qiE "Path Type:[[:space:]]*${path_type}([[:space:]]|$)|-path_delay[[:space:]]+${path_type}([[:space:]]|$)" "$file" 2>/dev/null
}

format_timing_value() {
    local value="$1"
    local unit="$2"
    local missing_text="${3:-N/A}"

    if [ -n "$value" ] && [ "$value" != "N/A" ]; then
        echo "${value} ${unit}"
    else
        echo "$missing_text"
    fi
}

derive_ths_from_hold_slack() {
    local hold_slack="$1"

    if [ -n "$hold_slack" ] && [ "$hold_slack" != "N/A" ]; then
        if awk -v v="$hold_slack" 'BEGIN { exit !(v ~ /^[-+]?[0-9]+(\.[0-9]+)?$/ && v + 0 >= 0) }' 2>/dev/null; then
            echo "0.00"
        fi
    fi
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

extract_named_section_number() {
    local section="$1"
    local file="$2"

    awk -v section="$section" '
        BEGIN {
            IGNORECASE = 1
            target = tolower(section)
            in_section = 0
        }
        {
            lower = tolower($0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lower)

            if (lower ~ /(^|[[:space:]])critical path delay[[:space:]]*$/ && lower !~ /slack div/) {
                if (target == "critical path delay") in_section = 1
                next
            }
            if (lower ~ /(^|[[:space:]])critical path slack[[:space:]]*$/) {
                if (target == "critical path slack") in_section = 1
                next
            }

            if (in_section) {
                if ($0 ~ /^=+/ && seen_value_line) exit
                if ($0 ~ /^[-]+$/ || $0 ~ /^[[:space:]]*$/) next

                seen_value_line = 1
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[-+]?[0-9]+(\.[0-9]+)?$/) {
                        print $i
                        exit
                    }
                }
            }
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
        echo "Action              : Check check_setup output in the active timing report."
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

unconstrained_endpoint_pins() {
    local rpt="$1"

    awk '
        /unconstrained endpoints/ {
            capture = 1
            next
        }
        capture && /^[[:space:]]+[^[:space:]]+\/[^[:space:]]+[[:space:]]*$/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
        }
        capture && NF == 0 {
            capture = 0
        }
    ' "$rpt" 2>/dev/null
}

netlist_instance_pin_net() {
    local netlist="$1"
    local inst_name="$2"
    local pin_name="$3"

    awk -v want_inst="$inst_name" -v want_pin="$pin_name" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }

        function norm_inst(s) {
            s = trim(s)
            sub(/^\\/, "", s)
            return s
        }

        {
            line = $0
            sub(/\/\/.*/, "", line)

            if (!in_inst && line ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_$]*[[:space:]]+/) {
                rest = line
                sub(/^[[:space:]]*[A-Za-z_][A-Za-z0-9_$]*[[:space:]]+/, "", rest)
                sub(/[[:space:]]*\(.*/, "", rest)

                if (norm_inst(rest) == want_inst) {
                    in_inst = 1
                }
            }

            if (in_inst) {
                pin_re = "\\." want_pin "[[:space:]]*\\("
                if (line ~ pin_re) {
                    conn = line
                    sub("^.*\\." want_pin "[[:space:]]*\\(", "", conn)
                    sub("\\).*", "", conn)
                    conn = trim(conn)
                    sub(/^\\/, "", conn)
                    print conn
                    exit
                }

                if (line ~ /^[[:space:]]*\);/) {
                    in_inst = 0
                }
            }
        }
    ' "$netlist" 2>/dev/null
}

netlist_net_is_tie_driven() {
    local netlist="$1"
    local net_name="$2"

    if echo "$net_name" | grep -Eq "^[01]$|^[0-9]*'[bhdBHD][0-9a-fA-FxXzZ]+$"; then
        return 0
    fi

    awk -v want_net="$net_name" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }

        function norm_net(s) {
            s = trim(s)
            sub(/^\\/, "", s)
            return s
        }

        /^[[:space:]]*TIE[A-Za-z0-9_$]*[[:space:]]+/ {
            in_tie = 1
        }

        in_tie && /\.[A-Za-z0-9_]+[[:space:]]*\(/ {
            conn = $0
            sub(/^.*\(/, "", conn)
            sub(/\).*$/, "", conn)

            if (norm_net(conn) == want_net) {
                found = 1
                exit
            }
        }

        in_tie && /^[[:space:]]*\);/ {
            in_tie = 0
        }

        END {
            exit(found ? 0 : 1)
        }
    ' "$netlist" 2>/dev/null
}

count_constant_driven_unconstrained_endpoints() {
    local netlist="$1"
    local rpt="$2"
    local count=0
    local pin inst port net

    while IFS= read -r pin; do
        [ -n "$pin" ] || continue

        inst="${pin%/*}"
        port="${pin##*/}"
        net=$(netlist_instance_pin_net "$netlist" "$inst" "$port")

        if [ -n "$net" ] && netlist_net_is_tie_driven "$netlist" "$net"; then
            count=$((count + 1))
        fi
    done < <(unconstrained_endpoint_pins "$rpt")

    echo "$count"
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
    local time_unit_label="${10:-ns}"
    local report_stage="${11:-${REPORT_STAGE:-SYNTHESIS}}"

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
    if [ "$report_stage" = "POST-ROUTE" ]; then
        print_health_line "PASS" "read_liberty" "handled by OpenROAD implementation flow"
    elif [ -f "$rpt" ] && grep -qiE "OPROAD_READ_LIBERTY_COUNT=|READ LIBERTY FILES|read_liberty" "$rpt" 2>/dev/null; then
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

    if [ "$report_stage" = "POST-ROUTE" ]; then
        if [ -f "$sdc" ]; then
            print_health_line "PASS" "read_sdc" "final constraints present"
        else
            print_health_line "WARN" "read_sdc" "final report exists, but project SDC is missing"
            warn=$((warn + 1))
        fi
    elif [ -f "$rpt" ] && grep -qiE "OPROAD_READ_SDC=|READ SDC|read_sdc" "$rpt" 2>/dev/null; then
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
    if [ -n "$ws_val" ] && [ "$ws_val" != "N/A" ]; then
        if awk -v v="$ws_val" 'BEGIN { exit !(v + 0 < 0) }' 2>/dev/null; then
            print_health_line "FAIL" "worst path slack" "${ws_val} ${time_unit_label} (timing violation)"
            fail=$((fail + 1))
        else
            print_health_line "PASS" "worst path slack" "${ws_val} ${time_unit_label}"
        fi
    elif [ -n "$wns_val" ] && [ "$wns_val" != "N/A" ]; then
        if awk -v v="$wns_val" 'BEGIN { exit !(v + 0 < 0) }' 2>/dev/null; then
            print_health_line "FAIL" "worst path slack" "detail missing; WNS=${wns_val} ${time_unit_label} (timing violation)"
            fail=$((fail + 1))
        else
            print_health_line "WARN" "worst path slack" "detail missing; WNS=${wns_val} ${time_unit_label}"
            warn=$((warn + 1))
        fi
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
        if [ "$report_stage" = "POST-ROUTE" ]; then
            echo "Meaning           : Post-route STA report is present, constrained, and non-violating."
        else
            echo "Meaning           : Synthesis STA constraints look complete for single-clock exploration."
        fi
    fi
}

###############################################################################
# Netlist / area helpers
###############################################################################

logic_cells() {
    local netlist="$1"
    local top_name="${2:-${OPROAD_AREA_TOP:-}}"

    awk '
        function skip_cell_type(cell, lower, upper) {
            upper = toupper(cell)
            lower = tolower(cell)

            if (cell ~ /^(module|endmodule|assign|always|initial|input|output|inout|wire|reg|tri|supply0|supply1|parameter|localparam)$/)
                return 1
            if (upper ~ /^(FILLCELL|FILL|TAPCELL|TAP|DECAP|WELLTAP|ANTENNA|ENDCAP)/)
                return 1
            if (lower ~ /(^|__)fill(cap)?($|[_0-9])|(^|__)decap($|[_0-9])|(^|__)tap(cell)?($|[_0-9])|(^|__)endcap($|[_0-9])|antenna/)
                return 1

            return 0
        }

        function parse_instance_cell(raw, line, cell, rest) {
            line = raw
            sub(/\/\/.*/, "", line)

            # Accept both normal identifiers and Yosys backslash-escaped names
            if (line !~ /^[[:space:]]*(\\[^[:space:]]+|[A-Za-z_][A-Za-z0-9_$]*)[[:space:]]+/)
                return ""

            cell = line
            sub(/^[[:space:]]*/, "", cell)
            sub(/[[:space:]].*$/, "", cell)

            if (skip_cell_type(cell))
                return ""

            rest = line
            sub(/^[[:space:]]*(\\[^[:space:]]+|[A-Za-z_][A-Za-z0-9_$]*)[[:space:]]+/, "", rest)

            # Yosys/OpenROAD netlists often use escaped instance names such as
            # \state[3]$_DFF_PN0_ . Match the whole escaped token up to the
            # terminating whitespace before "(", instead of assuming only
            # identifier characters.
            if (rest !~ /^(\\[^[:space:]]+|[A-Za-z_][^[:space:]]*)[[:space:]]*\(/)
                return ""

            return cell
        }

        function add_instance(mod, cell) {
            inst_count[mod]++
            inst_type[mod SUBSEP inst_count[mod]] = cell
        }

        function emit_leaf_cells(mod, i, cell) {
            if (!(mod in modules))
                return
            if (visiting[mod])
                return

            visiting[mod] = 1
            for (i = 1; i <= inst_count[mod]; i++) {
                cell = inst_type[mod SUBSEP i]
                if (cell in modules) {
                    emit_leaf_cells(cell)
                } else {
                    print cell
                }
            }
            visiting[mod] = 0
        }

        /^[[:space:]]*module[[:space:]]+/ {
            current_module = $0
            sub(/^[[:space:]]*module[[:space:]]+/, "", current_module)
            sub(/[[:space:]#(;].*$/, "", current_module)
            gsub(/\\$/, "", current_module)

            modules[current_module] = 1
            if (first_module == "")
                first_module = current_module
            next
        }

        /^[[:space:]]*endmodule([[:space:]]|$)/ {
            current_module = ""
            next
        }

        {
            if (current_module == "")
                next

            cell = parse_instance_cell($0)
            if (cell != "")
                add_instance(current_module, cell)
        }

        END {
            top = requested_top
            if (top == "" || !(top in modules))
                top = first_module

            emit_leaf_cells(top)
        }
    ' requested_top="$top_name" "$netlist" 2>/dev/null
}

core_logic_cells() {
    logic_cells "$1" "${2:-${OPROAD_AREA_TOP:-}}" | grep -vi '^BUF' | grep -vi '^CLKBUF' | grep -vi '^INV'
}

lib_cell_area() {
    local lib_file="$1"
    local cell_name="$2"

    awk -v cell="$cell_name" '
        function brace_delta(s, tmp, opens, closes) {
            tmp = s
            opens = gsub(/\{/, "{", tmp)
            tmp = s
            closes = gsub(/\}/, "}", tmp)
            return opens - closes
        }

        /^[[:space:]]*cell[[:space:]]*\(/ {
            line = $0
            sub(/^.*cell[[:space:]]*\(/, "", line)
            sub(/\).*$/, "", line)
            gsub(/"/, "", line)
            current_cell = line
            in_cell = (current_cell == cell)
            depth = in_cell ? brace_delta($0) : 0
            next
        }

        in_cell && /^[[:space:]]*area[[:space:]]*:/ {
            line = $0
            sub(/^.*area[[:space:]]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]*;.*/, "", line)
            print line
            exit
        }

        in_cell {
            depth += brace_delta($0)
            if (depth <= 0) {
                in_cell = 0
            }
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
    done < <(find_run_area_libs)
}

sum_netlist_cell_area() {
    local netlist="$1"
    local top_name="${2:-${OPROAD_AREA_TOP:-}}"

    logic_cells "$netlist" "$top_name" | sort | uniq -c | \
    while read COUNT CELL; do
        CELL_AREA=$(lib_cell_area_any "$CELL")
        if [ -n "$CELL_AREA" ]; then
            awk "BEGIN {printf \"%.6f\n\", ${COUNT} * ${CELL_AREA}}"
        fi
    done | awk '{sum += $1} END {printf "%.6f", sum}'
}

extract_yosys_chip_area() {
    local stat_file="$1"

    awk '
        /Chip area for (top )?module/ {
            val = $NF
            gsub(/[^0-9.].*$/, "", val)
        }
        END {
            if (val != "") print val
        }
    ' "$stat_file" 2>/dev/null
}

synth_stat_total_cells() {
    local stat_file="$1"

    awk '
        /Number of cells:/ {
            val = $NF
        }
        END {
            if (val != "") print val
        }
    ' "$stat_file" 2>/dev/null
}

synth_stat_dff_count() {
    local stat_file="$1"

    synth_stat_cell_counts "$stat_file" | \
        awk '$2 ~ /DFF|SDFF|LATCH|LAT/ { sum += $1 } END { printf "%d", sum }'
}

synth_stat_cell_counts() {
    local stat_file="$1"

    awk '
        /Number of cells:/ {
            delete cells
            in_cells = 1
            next
        }
        in_cells && /^[[:space:]]+[^[:space:]]+[[:space:]]+[0-9]+[[:space:]]*$/ {
            cells[$1] = $2
            next
        }
        in_cells && NF == 0 {
            in_cells = 0
        }
        END {
            for (cell in cells) {
                print cells[cell], cell
            }
        }
    ' "$stat_file" 2>/dev/null
}

extract_openroad_design_area() {
    local f

    for f in "$@"; do
        [ -f "$f" ] || continue
        local val
        val=$(awk '
            /"[^"]*design__instance__area"[[:space:]]*:/ {
                line = $0
                sub(/^.*:[[:space:]]*/, "", line)
                sub(/,.*/, "", line)
                gsub(/[[:space:]]/, "", line)
                val = line
            }
            /Design area[[:space:]]+[0-9.]+/ {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
                        val = $i
                        break
                    }
                }
            }
            END {
                if (val != "") print val
            }
        ' "$f" 2>/dev/null)
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
    done
}

extract_openroad_utilization() {
    local f

    for f in "$@"; do
        [ -f "$f" ] || continue
        local val
        val=$(awk '
            /"[^"]*design__instance__utilization"[[:space:]]*:/ {
                line = $0
                sub(/^.*:[[:space:]]*/, "", line)
                sub(/,.*/, "", line)
                gsub(/[[:space:]]/, "", line)
                val = line
            }
            /Design area[[:space:]]+[0-9.]+.*utilization/ {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[0-9]+%$/) {
                        pct = $i
                        sub(/%$/, "", pct)
                        val = pct / 100.0
                        break
                    }
                }
            }
            END {
                if (val != "") print val
            }
        ' "$f" 2>/dev/null)
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
    done
}

extract_openroad_cell_type_count() {
    local label="$1"
    local f

    for f in "$@"; do
        [ -f "$f" ] || continue
        local val
        val=$(awk -v label="$label" '
            BEGIN { target = tolower(label) }
            /Cell type report:/ { in_report = 1; next }
            in_report {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+[0-9]+[[:space:]]*$/, "", line)
                if (tolower(line) == target) {
                    print $NF
                    exit
                }
                if ($0 ~ /^[[:space:]]*$/ && seen) {
                    exit
                }
                if ($0 ~ /^[[:space:]]*[A-Za-z]/) {
                    seen = 1
                }
            }
        ' "$f" 2>/dev/null)
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
    done
}

show_area_health_check() {
    local area="$1"
    local coverage="$2"
    local unmatched="$3"
    local native_area="$4"
    local native_source="$5"
    local report_stage="${6:-SYNTHESIS}"

    local fail=0
    local warn=0

    echo ""
    echo "========== AREA HEALTH CHECK =========="

    if [ "$report_stage" = "POST-ROUTE" ]; then
        if [ -n "$native_area" ] && awk "BEGIN {exit !(${native_area} > 0)}"; then
            print_health_line "PASS" "implemented physical area" "${native_area} μm² from ${native_source}"
        else
            print_health_line "FAIL" "implemented physical area" "missing final OpenROAD design area"
            fail=$((fail + 1))
        fi

        if [ -n "$area" ] && awk "BEGIN {exit !(${area} > 0)}"; then
            print_health_line "PASS" "logic Liberty area" "${area} μm²"
        else
            print_health_line "WARN" "logic Liberty area" "not available"
            warn=$((warn + 1))
        fi

        if [ -n "$coverage" ] && awk "BEGIN {exit !(${coverage} >= 99.5)}"; then
            print_health_line "PASS" "Liberty area coverage" "${coverage}% matched"
        else
            print_health_line "WARN" "Liberty area coverage" "${coverage:-0.00}% matched; unmatched=${unmatched:-0}"
            warn=$((warn + 1))
        fi

        if [ "${unmatched:-0}" = "0" ]; then
            print_health_line "PASS" "unmatched cells" "none"
        else
            print_health_line "WARN" "unmatched cells" "${unmatched} instance(s)"
            warn=$((warn + 1))
        fi

        if [ -n "$native_area" ] && [ -n "$area" ] && \
            awk "BEGIN {exit !(${native_area} > 0 && ${area} > 0)}"; then
            delta_pct=$(awk "BEGIN {d=100.0*(${native_area}-${area})/${native_area}; if (d < 0) d=-d; printf \"%.3f\", d}")
            print_health_line "INFO" "physical vs logic area" "delta=${delta_pct}%; physical area is report authority"
        fi

        echo ""
        if [ "$fail" -gt 0 ]; then
            echo "Area health result: FAIL (${fail} fail, ${warn} warn)"
            echo "Meaning           : Do not use area until FAIL items are fixed."
        elif [ "$warn" -gt 0 ]; then
            echo "Area health result: WARN (${warn} warn)"
            echo "Meaning           : Implemented area is available, but review warning items."
        else
            echo "Area health result: PASS"
            echo "Meaning           : Area is based on final OpenROAD implementation data."
        fi
        return
    fi

    # Summed area: if 0 but native tool area exists, it's a hierarchical netlist
    if [ -n "$area" ] && awk "BEGIN {exit !(${area} > 0)}"; then
        print_health_line "PASS" "summed netlist area" "${area} μm²"
    elif [ -n "$native_area" ] && awk "BEGIN {exit !(${native_area} > 0)}"; then
        print_health_line "INFO" "summed netlist area" "hierarchical netlist; native tool area is authoritative"
    else
        print_health_line "FAIL" "summed netlist area" "missing or zero"
        fail=$((fail + 1))
    fi

    if [ -n "$coverage" ] && awk "BEGIN {exit !(${coverage} >= 99.5)}"; then
        print_health_line "PASS" "Liberty area coverage" "${coverage}% matched"
    else
        print_health_line "WARN" "Liberty area coverage" "${coverage:-0.00}% matched; unmatched=${unmatched:-0}"
        warn=$((warn + 1))
    fi

    if [ "${unmatched:-0}" = "0" ]; then
        print_health_line "PASS" "unmatched cells" "none"
    else
        print_health_line "WARN" "unmatched cells" "${unmatched} instance(s)"
        warn=$((warn + 1))
    fi

    if [ -n "$native_area" ] && [ -n "$area" ] && \
        awk "BEGIN {exit !(${native_area} > 0 && ${area} > 0)}"; then
        local delta_pct
        delta_pct=$(awk "BEGIN {d=100.0*(${area}-${native_area})/${native_area}; if (d < 0) d=-d; printf \"%.3f\", d}")

        if awk "BEGIN {exit !(${delta_pct} <= 0.5)}"; then
            print_health_line "PASS" "native area cross-check" "${native_area} μm² from ${native_source}; delta=${delta_pct}%"
        else
            print_health_line "WARN" "native area cross-check" "${native_area} μm² from ${native_source}; delta=${delta_pct}%"
            print_health_line "INFO" "authoritative area" "keeping summed Liberty area, not native cross-check"
            warn=$((warn + 1))
        fi
    else
        print_health_line "WARN" "native area cross-check" "native tool area not found"
        warn=$((warn + 1))
    fi

    echo ""
    if [ "$fail" -gt 0 ]; then
        echo "Area health result: FAIL (${fail} fail, ${warn} warn)"
        echo "Meaning           : Do not use area until FAIL items are fixed."
    elif [ "$warn" -gt 0 ]; then
        echo "Area health result: WARN (${warn} warn)"
        echo "Meaning           : Design area remains Liberty-based; review coverage/cross-check warnings."
    else
        echo "Area health result: PASS"
        echo "Meaning           : Area is consistent with Liberty and native tool reports."
    fi
}

# Write an area coverage report to a small key-value file.
# The report includes:
#   AREA
#   TOTAL_INST
#   MATCHED_INST
#   UNMATCHED_INST
#   COVERAGE
#   UNMATCHED_FILE
#   AUTHORITY
write_area_coverage_report() {
    local netlist="$1"
    local out_file="$2"
    local top_name="${3:-${OPROAD_AREA_TOP:-}}"
    local unmatched_file="${out_file}.unmatched"
    local authority="summed Liberty cell areas"

    if [ "${PLATFORM:-}" = "nangate15" ]; then
        authority="summed Nangate15 Liberty cell areas"
    fi

    : > "$unmatched_file"

    local total_inst=0
    local matched_inst=0
    local unmatched_inst=0
    local area_sum="0.000000"

    logic_cells "$netlist" "$top_name" | sort | uniq -c | \
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
        echo "AUTHORITY=${authority}" >> "$out_file"
    done

    # If there were no cells at all, make sure the report still exists.
    if [ ! -f "$out_file" ]; then
        echo "AREA=0.000000" > "$out_file"
        echo "TOTAL_INST=0" >> "$out_file"
        echo "MATCHED_INST=0" >> "$out_file"
        echo "UNMATCHED_INST=0" >> "$out_file"
        echo "COVERAGE=0.00" >> "$out_file"
        echo "UNMATCHED_FILE=${unmatched_file}" >> "$out_file"
        echo "AUTHORITY=${authority}" >> "$out_file"
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
    echo "SYNTHESIS"
    echo "========================================"
    echo ""

    echo "[1/2] Yosys synthesis (ABC tech-mapping)..."
    run_docker_make "synth" || exit 1

    echo ""
    echo "========================================"
    echo "STAGE 2: AUTO REPORT"
    echo "========================================"
    echo "Running post-synthesis summary for this project..."
    "$0" report "$PROJECT_ROOT"

    exit $?
fi

###############################################################################
# implement / run
###############################################################################

if [ "$CMD" = "implement" ] || [ "$CMD" = "run" ]; then
    find_project "$2"

    BASE_RPT="$PROJECT_ROOT/reports/${PLATFORM}/${DESIGN}/${BASE}"

    echo ""
    echo "========================================"
    echo "STAGE 1: SYNTHESIS"
    echo "  → Yosys: RTL → gate-level netlist"
    echo "  → Flow report: synthesis timing and area metrics"
    echo "========================================"
    run_docker_make "synth" || exit 1

    echo ""
    echo "========================================"
    echo "STAGE 2: FLOORPLAN"
    echo "  → Define core area, I/O pads, macro placement"
    echo "========================================"
    run_docker_make "do-floorplan" || exit 1

    echo ""
    echo "========================================"
    echo "STAGE 3: PLACEMENT"
    echo "  → Place standard cells"
    echo "  → OpenSTA: estimated wire-length delay check"
    echo "========================================"
    run_docker_make "do-place" || exit 1

    echo ""
    echo "========================================"
    echo "STAGE 4: CTS (Clock Tree Synthesis)"
    echo "  → Build clock tree, insert buffers"
    echo "  → OpenSTA: check clock skew, hold timing"
    echo "========================================"
    run_docker_make "do-cts" || exit 1

    echo ""
    echo "========================================"
    echo "STAGE 5: ROUTING"
    echo "  → Connect all cells with metal wires"
    echo "========================================"
    run_docker_make "do-route" || exit 1

    echo ""
    echo "========================================"
    echo "STAGE 6: FINISH + SIGN-OFF STA"
    echo "  → Fill cells, final netlist"
    echo "  → OpenSTA: extract real RC parasitics, full timing sign-off"
    echo "========================================"
    run_finish_stage || exit 1

    echo ""
    echo "========================================"
    echo "IMPLEMENTATION COMPLETE"
    echo "========================================"
    echo ""
    echo "  Post-route sign-off report:"
    echo "    ${BASE_RPT}/6_finish.rpt"
    echo "  Final netlist:"
    echo "    results/${PLATFORM}/${DESIGN}/${BASE}/6_final.v"
    echo ""
    echo "========================================"
    echo "STAGE 7: AUTO REPORT"
    echo "========================================"
    echo "Running post-implementation summary for this project..."
    "$0" report "$PROJECT_ROOT"

    exit $?
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

show_stage_header() {
    local stage="$1"
    local available="$2"
    local rpt="$3"
    local rpt_short="$4"
    if [ "$available" = "1" ] && [ -f "$rpt" ]; then
        echo "  [ok]    $stage  --  $rpt_short"
    else
        echo "  [-----] $stage  --  not available (run 'oproad implement')"
    fi
}

if [ "$CMD" = "report" ]; then
    find_project "$2"

    ACTIVE_DESIGN="$DESIGN"
    REPORT_DIR="$PROJECT_ROOT/reports/${PLATFORM}/${ACTIVE_DESIGN}/${BASE}"
    LOG_DIR="$PROJECT_ROOT/logs/${PLATFORM}/${ACTIVE_DESIGN}/${BASE}"
    RESULT_DIR="$PROJECT_ROOT/results/${PLATFORM}/${ACTIVE_DESIGN}/${BASE}"
    SYNTH_TIMING_RPT="${REPORT_DIR}/1_Post_synthesis.rpt"
    SYNTH_TIMING_SHORT="reports/.../1_Post_synthesis.rpt"

    CLOCK_FILE="${RESULT_DIR}/clock_period.txt"
    SDC_FILE="$PROJECT_ROOT/platform/${PLATFORM}/${ACTIVE_DESIGN}/constraint.sdc"
    LIB_FILE=$(find_platform_single_lib_for_display)
    TIME_UNIT_DECL=$(get_platform_time_unit_decl)
    [ -z "$TIME_UNIT_DECL" ] && TIME_UNIT_DECL="1ns"
    TIME_UNIT=$(get_platform_time_unit)
    TIME_TO_NS=$(time_unit_decl_to_ns "$TIME_UNIT_DECL")

    echo ""
    echo "========================================"
    echo "PROJECT  : $PROJECT_ROOT"
    echo "PLATFORM : $PLATFORM"
    echo "DESIGN   : $ACTIVE_DESIGN"
    echo "TOP      : $(get_design_name_for_dir "$ACTIVE_DESIGN")"
    echo "========================================"
    echo ""
    echo "Stage availability:"
    show_stage_header "Post-Synthesis STA" "1" "$SYNTH_TIMING_RPT" "$SYNTH_TIMING_SHORT"
    show_stage_header "Post-Placement" "1" "${REPORT_DIR}/3_detailed_place.rpt" "reports/.../3_detailed_place.rpt"
    show_stage_header "Post-CTS" "1" "${REPORT_DIR}/4_cts_final.rpt" "reports/.../4_cts_final.rpt"
    show_stage_header "Post-Route" "1" "${REPORT_DIR}/6_finish.rpt" "reports/.../6_finish.rpt"
    echo ""

    # Determine which detailed timing to show
    if [ -f "${RESULT_DIR}/6_final.v" ] && [ -f "${REPORT_DIR}/6_finish.rpt" ]; then
        TIMING_RPT="${REPORT_DIR}/6_finish.rpt"
        NETLIST="${RESULT_DIR}/6_final.v"
        REPORT_LOG="${LOG_DIR}/6_report.log"
        STAT_RPT="${REPORT_DIR}/6_finish.rpt"
        UNCONSTRAINED_RPT=""
        REPORT_STAGE="POST-ROUTE"
    elif [ -f "${RESULT_DIR}/1_synth.v" ] && [ -f "$SYNTH_TIMING_RPT" ]; then
        TIMING_RPT="$SYNTH_TIMING_RPT"
        NETLIST="${RESULT_DIR}/1_synth.v"
        REPORT_LOG="${LOG_DIR}/1_1_yosys.log"
        STAT_RPT="${REPORT_DIR}/synth_stat.txt"
        UNCONSTRAINED_RPT="${REPORT_DIR}/synth_unconstrained_endpoints.rpt"
        REPORT_STAGE="SYNTHESIS"
    else
        echo "No synthesis or implementation results found."
        echo "Run 'oproad synth' or 'oproad implement' first."
        exit 1
    fi

    echo "Report stage       : ${REPORT_STAGE}"
    if [ "$REPORT_STAGE" = "POST-ROUTE" ]; then
        missing_impl=0
        for artifact in \
            "${RESULT_DIR}/6_final.v" \
            "${RESULT_DIR}/6_final.def" \
            "${RESULT_DIR}/6_final.odb" \
            "${RESULT_DIR}/6_final.sdc" \
            "${REPORT_DIR}/6_finish.rpt"; do
            if [ ! -f "$artifact" ]; then
                missing_impl=$((missing_impl + 1))
            fi
        done

        if [ "$missing_impl" -eq 0 ]; then
            echo "Implementation result : PASS"
            echo "Implementation data   : final routed artifacts present"
        else
            echo "Implementation result : FAIL (${missing_impl} artifact(s) missing)"
            echo "Implementation data   : incomplete final routed artifacts"
        fi
    else
        echo "Implementation result : NOT_RUN"
        echo "Implementation data   : using synthesis-only artifacts"
    fi
    echo ""
    echo "========== TIMING =========="

    if [ -n "$TIMING_RPT" ] && [ -f "$TIMING_RPT" ]; then
        TNS=$(extract_last_numeric_for_key "tns" "$TIMING_RPT")
        WNS=$(extract_last_numeric_for_key "wns" "$TIMING_RPT")
        SETUP_SLACK=$(extract_worst_path_slack_for_type "max" "$TIMING_RPT")
        [ -z "$SETUP_SLACK" ] && SETUP_SLACK=$(extract_path_slack_for_delay "max" "$TIMING_RPT")
        [ -z "$SETUP_SLACK" ] && SETUP_SLACK=$(extract_worst_slack_line "$TIMING_RPT")
        HOLD_SLACK=$(extract_worst_path_slack_for_type "min" "$TIMING_RPT")
        [ -z "$HOLD_SLACK" ] && HOLD_SLACK=$(extract_path_slack_for_delay "min" "$TIMING_RPT")
        WHS=$(extract_last_numeric_for_key "whs" "$TIMING_RPT")
        [ -z "$WHS" ] && WHS="$HOLD_SLACK"
        THS=$(extract_last_numeric_for_key "ths" "$TIMING_RPT")
        [ -z "$THS" ] && THS=$(derive_ths_from_hold_slack "$WHS")
        WS=$(extract_worst_path_slack_all "$TIMING_RPT")
        CRITICAL_REPORT_DELAY=$(extract_named_section_number "critical path delay" "$TIMING_RPT")
        CRITICAL_REPORT_SLACK=$(extract_named_section_number "critical path slack" "$TIMING_RPT")
        CRITICAL_PATH_DELAY=$(extract_worst_path_arrival_for_type "max" "$TIMING_RPT")
        [ -z "$CRITICAL_REPORT_DELAY" ] && CRITICAL_REPORT_DELAY="$CRITICAL_PATH_DELAY"
        HOLD_SLACK_MISSING_TEXT="N/A"

        if [ -z "$HOLD_SLACK" ] && ! has_timing_path_type "min" "$TIMING_RPT"; then
            HOLD_SLACK_MISSING_TEXT="N/A (min-path report missing)"
        fi

        if [ -z "$WS" ]; then
            WS="$SETUP_SLACK"
        fi

        NO_PATHS=$(grep -i "No paths found" "$TIMING_RPT" 2>/dev/null | tail -1)
        UNCLOCKED=$(grep -i "unclocked register/latch pins" "$TIMING_RPT" 2>/dev/null | tail -1)
        UNCONSTRAINED=$(grep -i "unconstrained endpoints" "$TIMING_RPT" 2>/dev/null | tail -1)
        CONSTANT_UNCONSTRAINED_NOTE=""

        if [ "$REPORT_STAGE" = "SYNTHESIS" ] && [ -n "$UNCONSTRAINED_RPT" ] && [ -f "$UNCONSTRAINED_RPT" ]; then
            RAW_UNCONSTRAINED=$(grep -i "unconstrained endpoints" "$UNCONSTRAINED_RPT" 2>/dev/null | tail -1)
            RAW_UNCONSTRAINED_COUNT=$(extract_unconstrained_count "$UNCONSTRAINED_RPT")

            if [ -n "$RAW_UNCONSTRAINED" ] && [ -n "$RAW_UNCONSTRAINED_COUNT" ] && [ "$RAW_UNCONSTRAINED_COUNT" != "0" ]; then
                if [ "$OPROAD_REPORT_DEEP_CHECKS" = "1" ] && [ "$RAW_UNCONSTRAINED_COUNT" -le 200 ] 2>/dev/null; then
                    CONST_UNCONSTRAINED_COUNT=$(count_constant_driven_unconstrained_endpoints "$NETLIST" "$UNCONSTRAINED_RPT")
                else
                    echo "  (skipping detailed constant-driven check; set OPROAD_REPORT_DEEP_CHECKS=1 to enable)"
                    CONST_UNCONSTRAINED_COUNT=""
                fi

                if [ "$CONST_UNCONSTRAINED_COUNT" = "$RAW_UNCONSTRAINED_COUNT" ]; then
                    UNCONSTRAINED=""
                    CONSTANT_UNCONSTRAINED_NOTE="${RAW_UNCONSTRAINED_COUNT} constant-driven endpoint(s) excluded from STA health"
                elif [ -z "$CONST_UNCONSTRAINED_COUNT" ]; then
                    UNCONSTRAINED=""
                    CONSTANT_UNCONSTRAINED_NOTE="${RAW_UNCONSTRAINED_COUNT} unchecked endpoint(s); deep constant-driven check skipped for fast report"
                else
                    UNCONSTRAINED="$RAW_UNCONSTRAINED"
                fi
            fi
        fi

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
        SETUP_SLACK="N/A"
        HOLD_SLACK="N/A"
        WHS="N/A"
        THS="N/A"
        HOLD_SLACK_MISSING_TEXT="N/A"
        WS="N/A"
        CRITICAL_REPORT_DELAY=""
        CRITICAL_REPORT_SLACK=""
        CRITICAL_PATH_DELAY=""
        NO_PATHS=""
        UNCLOCKED=""
        UNCONSTRAINED=""
        CONSTANT_UNCONSTRAINED_NOTE=""
    fi

    SETUP_SLACK_DISPLAY=$(format_timing_value "${SETUP_SLACK:-N/A}" "$TIME_UNIT" "N/A")
    HOLD_SLACK_DISPLAY=$(format_timing_value "${HOLD_SLACK:-N/A}" "$TIME_UNIT" "${HOLD_SLACK_MISSING_TEXT:-N/A}")
    WHS_DISPLAY=$(format_timing_value "${WHS:-N/A}" "$TIME_UNIT" "${HOLD_SLACK_MISSING_TEXT:-N/A}")
    THS_DISPLAY=$(format_timing_value "${THS:-N/A}" "$TIME_UNIT" "N/A")
    WS_DISPLAY=$(format_timing_value "${WS:-N/A}" "$TIME_UNIT" "N/A")

    echo "TNS (OpenSTA)     : ${TNS:-N/A} ${TIME_UNIT}"
    echo "WNS (OpenSTA)     : ${WNS:-N/A} ${TIME_UNIT}"
    echo "Worst setup slack : ${SETUP_SLACK_DISPLAY}"
    echo "WHS (hold)         : ${WHS_DISPLAY}"
    echo "THS (hold)         : ${THS_DISPLAY}"
    echo "Worst slack (all)  : ${WS_DISPLAY}"

    if [ "$REPORT_STAGE" = "SYNTHESIS" ]; then
        echo "Note        : synthesis STA is pre-layout and does not include routed parasitics."
        echo "STA report  : ${TIMING_RPT#$PROJECT_ROOT/}"

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

        if [ -n "$CONSTANT_UNCONSTRAINED_NOTE" ]; then
            echo "Setup note  : $CONSTANT_UNCONSTRAINED_NOTE"
            if echo "$CONSTANT_UNCONSTRAINED_NOTE" | grep -q "unchecked"; then
                echo "Note        : Fast report mode skipped the netlist-wide constant-driver scan."
            else
                echo "Note        : These endpoints are driven only by tie/constant nets."
            fi
        fi

        if { [ -z "$TNS" ] && [ -z "$WNS" ] && [ -z "$WS" ]; } || [ -n "$NO_PATHS" ]; then
            show_sta_diagnostics "$TIMING_RPT"
        fi
    fi

    if [ "$REPORT_STAGE" = "POST-ROUTE" ]; then
        if [ -f "${RESULT_DIR}/6_final.spef" ]; then
            echo "Parasitics         : SPEF found (${RESULT_DIR#$PROJECT_ROOT/}/6_final.spef)"
            POST_ROUTE_ACCURACY_TITLE="Stage: POST-ROUTE (extracted RC STA)"
            POST_ROUTE_ACC3="[signoff] WNS/TNS/WHS/THS Post-route, extracted RC"
            POST_ROUTE_ACC4="[signoff] Worst slack    SPEF-based timing"
            POST_ROUTE_FOOT="Signoff-quality. Use these numbers for final reports."
        else
            echo "Warning            : final SPEF not found; post-route timing uses tool-estimated routing parasitics."
            POST_ROUTE_ACCURACY_TITLE="Stage: POST-ROUTE (estimated RC STA)"
            POST_ROUTE_ACC3="[route]   WNS/TNS/WHS/THS Post-route, estimated RC"
            POST_ROUTE_ACC4="[route]   Worst slack    No final SPEF available"
            POST_ROUTE_FOOT="Exploration result; SPEF needed for signoff."
        fi
    fi

    show_sta_health_check "$TIMING_RPT" "$SDC_FILE" "$(get_design_name_for_dir "$ACTIVE_DESIGN")" "$NETLIST" "${WS:-N/A}" "${WNS:-N/A}" "$NO_PATHS" "$UNCLOCKED" "$UNCONSTRAINED" "$TIME_UNIT" "$REPORT_STAGE"

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
    elif [ -n "$CONSTANT_UNCONSTRAINED_NOTE" ]; then
        if echo "$CONSTANT_UNCONSTRAINED_NOTE" | grep -q "unchecked"; then
            echo "Unconstrained note: deep endpoint classification skipped"
        else
            echo "Unconstrained note: none after ignoring constant-driven endpoint(s)"
        fi
        echo "Constant endpoints: $CONSTANT_UNCONSTRAINED_NOTE"
    else
        echo "Unconstrained note: none reported by check_setup"
    fi

    echo ""
    echo "========== CRITICAL PATH =========="

    CRITICAL_DELAY_SUMMARY="N/A"
    MAX_FREQ_GHZ="N/A"
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
        SETUP_SLACK_FOR_PERIOD=""

        if [ -n "$CRITICAL_REPORT_SLACK" ] && [ "$CRITICAL_REPORT_SLACK" != "N/A" ]; then
            SETUP_SLACK_FOR_PERIOD="$CRITICAL_REPORT_SLACK"
        elif [ -n "$SETUP_SLACK" ] && [ "$SETUP_SLACK" != "N/A" ]; then
            SETUP_SLACK_FOR_PERIOD="$SETUP_SLACK"
        elif [ -n "$WNS" ] && [ "$WNS" != "N/A" ]; then
            SETUP_SLACK_FOR_PERIOD="$WNS"
        fi

        if [ -n "$CRITICAL_REPORT_DELAY" ] && [ "$CRITICAL_REPORT_DELAY" != "N/A" ]; then
            CRITICAL_DELAY=$(awk "BEGIN {printf \"%.4f\", ${CRITICAL_REPORT_DELAY}}")
            CRITICAL_DELAY_NS=$(awk "BEGIN {printf \"%.6f\", ${CRITICAL_REPORT_DELAY} * ${TIME_TO_NS}}")

            if awk "BEGIN {exit !(${CRITICAL_DELAY} > 0)}"; then
                if [ "$TIME_UNIT" = "ns" ]; then
                    echo "Critical path delay : ${CRITICAL_DELAY} ${TIME_UNIT}"
                    CRITICAL_DELAY_SUMMARY="${CRITICAL_DELAY} ns"
                else
                    echo "Critical path delay : ${CRITICAL_DELAY} ${TIME_UNIT} (${CRITICAL_DELAY_NS} ns)"
                    CRITICAL_DELAY_SUMMARY="${CRITICAL_DELAY_NS} ns"
                fi
            else
                echo "Critical path delay : N/A"
            fi
        else
            echo "Critical path delay : N/A"
        fi

        if [ -n "$CLOCK_PERIOD" ] && [ -n "$SETUP_SLACK_FOR_PERIOD" ]; then
            SETUP_LIMITED_PERIOD=$(awk "BEGIN {d=${CLOCK_PERIOD}-(${SETUP_SLACK_FOR_PERIOD}); if (d < 0) d=0; printf \"%.4f\", d}")

            if awk "BEGIN {exit !(${SETUP_LIMITED_PERIOD} > 0)}"; then
                SETUP_LIMITED_PERIOD_NS=$(awk "BEGIN {printf \"%.6f\", ${SETUP_LIMITED_PERIOD} * ${TIME_TO_NS}}")
                MAX_FREQ_MHZ=$(awk "BEGIN {printf \"%.2f\", 1000/${SETUP_LIMITED_PERIOD_NS}}")
                MAX_FREQ_GHZ=$(awk "BEGIN {printf \"%.4f\", 1/${SETUP_LIMITED_PERIOD_NS}}")

                if [ "$TIME_UNIT" = "ns" ]; then
                    echo "Setup-limited period: ${SETUP_LIMITED_PERIOD} ${TIME_UNIT}"
                else
                    echo "Setup-limited period: ${SETUP_LIMITED_PERIOD} ${TIME_UNIT} (${SETUP_LIMITED_PERIOD_NS} ns)"
                fi
                echo "Estimated Fmax      : ${MAX_FREQ_MHZ} MHz (${MAX_FREQ_GHZ} GHz)"
                echo "Fmax basis          : setup-limited period"
                echo "Slack used          : ${SETUP_SLACK_FOR_PERIOD} ${TIME_UNIT}"
            else
                echo "Setup-limited period: 0.0000 ${TIME_UNIT}"
                echo "Estimated Fmax      : N/A"
            fi
        else
            echo "Setup-limited period: N/A"
            echo "Estimated Fmax      : N/A"
        fi
    fi

    echo ""
    echo "========== OVERALL WORST PATH SUMMARY =========="

    if [ -n "$NO_PATHS" ]; then
        echo "No constrained worst path was reported."
        echo "Use the diagnostics above to debug missing SDC constraints."
    elif [ -n "$TIMING_RPT" ] && [ -f "$TIMING_RPT" ]; then
        grep -nE "Startpoint:|Endpoint:|Path Type:|data arrival time|slack \((MET|VIOLATED)\)" "$TIMING_RPT" | head -24

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
    NATIVE_AREA=""
    NATIVE_AREA_SOURCE="N/A"
    if [ "$PLATFORM" = "nangate15" ]; then
        AREA_AUTHORITY="summed Nangate15 Liberty cell areas"
    else
        AREA_AUTHORITY="summed Liberty cell areas"
    fi
    AREA_TOP="$(get_design_name_for_dir "$ACTIVE_DESIGN")"

    AREA_REPORT="${REPORT_DIR}/area_coverage.txt"

    if [ -f "$NETLIST" ]; then
        if [ ! -f "$AREA_REPORT" ] || [ "$NETLIST" -nt "$AREA_REPORT" ]; then
            write_area_coverage_report "$NETLIST" "$AREA_REPORT" "$AREA_TOP"
        else
            echo "Area cache          : using existing reports/${PLATFORM}/${ACTIVE_DESIGN}/${BASE}/area_coverage.txt"
        fi

        AREA=$(grep "^AREA=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)
        AREA_TOTAL_INST=$(grep "^TOTAL_INST=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)
        AREA_MATCHED_INST=$(grep "^MATCHED_INST=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)
        AREA_UNMATCHED_INST=$(grep "^UNMATCHED_INST=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)
        AREA_COVERAGE=$(grep "^COVERAGE=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)
        AREA_UNMATCHED_FILE=$(grep "^UNMATCHED_FILE=" "$AREA_REPORT" 2>/dev/null | tail -1 | cut -d= -f2)

        AREA_SOURCE="top-expanded netlist cell areas using multi-Liberty lookup"
    fi

    if [ "$REPORT_STAGE" = "SYNTHESIS" ]; then
        HIER_STAT="$PROJECT_ROOT/reports/${PLATFORM}/${ACTIVE_DESIGN}/${BASE}/synth_hier_stat.txt"
        NATIVE_AREA=$(extract_yosys_chip_area "$STAT_RPT")
        if [ -n "$NATIVE_AREA" ]; then
            NATIVE_AREA_SOURCE="Yosys synth_stat.txt"
        else
            NATIVE_AREA=$(extract_yosys_chip_area "$HIER_STAT")
            if [ -n "$NATIVE_AREA" ]; then
                NATIVE_AREA_SOURCE="Yosys synth_hier_stat.txt"
            fi
        fi
    else
        NATIVE_AREA=$(extract_openroad_design_area \
            "${LOG_DIR}/6_report.json" \
            "${LOG_DIR}/6_report.log" \
            "${REPORT_DIR}/6_finish.rpt" \
            "${LOG_DIR}/5_3_route.json" \
            "${LOG_DIR}/3_5_place_dp.json" \
            "${LOG_DIR}/2_1_floorplan.json" \
            "${LOG_DIR}/2_1_floorplan.log")
        if [ -n "$NATIVE_AREA" ]; then
            NATIVE_AREA_SOURCE="OpenROAD metrics/report"
        fi
    fi

    if [ "$REPORT_STAGE" = "POST-ROUTE" ]; then
        UTIL_FRACTION=$(extract_openroad_utilization \
            "${LOG_DIR}/6_report.json" \
            "${LOG_DIR}/6_report.log" \
            "${REPORT_DIR}/6_finish.rpt" \
            "${LOG_DIR}/5_3_route.json" \
            "${LOG_DIR}/3_5_place_dp.json" \
            "${LOG_DIR}/2_1_floorplan.json" \
            "${LOG_DIR}/2_1_floorplan.log")
        if [ -n "$UTIL_FRACTION" ]; then
            UTIL=$(awk "BEGIN {printf \"%.2f%% utilization\", ${UTIL_FRACTION} * 100.0}")
        fi
    fi

    REPORT_AREA=""
    REPORT_AREA_SOURCE=""

    if [ "$REPORT_STAGE" = "POST-ROUTE" ] && [ -n "$NATIVE_AREA" ]; then
        REPORT_AREA="$NATIVE_AREA"
        REPORT_AREA_SOURCE="$NATIVE_AREA_SOURCE"
    elif [ -n "$AREA" ] && [ "$AREA" != "0" ] && [ "$AREA" != "0.000000" ]; then
        REPORT_AREA="$AREA"
        REPORT_AREA_SOURCE="$AREA_SOURCE"
    else
        REPORT_AREA="$NATIVE_AREA"
        REPORT_AREA_SOURCE="$NATIVE_AREA_SOURCE"
    fi

    if [ "$REPORT_STAGE" = "POST-ROUTE" ]; then
        echo "Implemented design area : ${REPORT_AREA:-N/A} μm²  ← OpenROAD final physical database"
        echo "  Source                : ${REPORT_AREA_SOURCE:-N/A}"
        if [ -n "$AREA" ] && [ "$AREA" != "0" ] && [ "$AREA" != "0.000000" ]; then
            echo "Logic cell area          : ${AREA} μm²"
            echo "  Source                : ${AREA_SOURCE}"
        fi
    elif [ "${AREA:-0}" = "0" ] || [ "${AREA:-0}" = "0.000000" ] || [ -z "$AREA" ]; then
        echo "Design area (Liberty): ${REPORT_AREA:-N/A} μm²  ← Yosys, authoritative"
        echo "  Source              : ${REPORT_AREA_SOURCE:-N/A}"
    else
        echo "Design area (Liberty): ${AREA} μm²  ← authoritative"
        echo "  Source              : ${AREA_SOURCE}"
    fi

    # OpenSTA/OpenROAD area cross-reference when it is not already the authority.
    STA_AREA=""
    if [ "$REPORT_STAGE" != "POST-ROUTE" ] && [ -n "$TIMING_RPT" ] && [ -f "$TIMING_RPT" ]; then
        STA_AREA=$(grep "Design area" "$TIMING_RPT" 2>/dev/null | tail -1 | awk '{print $3}')
        if [ -n "$STA_AREA" ]; then
            echo "Design area (LEF)    : ${STA_AREA} u²  ← OpenSTA, includes cell bounding box"
            echo "  Note               : LEF area is ~8% larger than Liberty. Use Liberty value."
        fi
    fi

    # Liberty-based cell matching: skip when 0 (hierarchical netlist)
    if [ "${AREA_MATCHED_INST:-0}" != "0" ] || [ "${AREA_UNMATCHED_INST:-0}" != "0" ]; then
        echo "Area-matched cells  : ${AREA_MATCHED_INST:-0}"
        echo "Area-unmatched cells: ${AREA_UNMATCHED_INST:-0}"
        echo "Area coverage       : ${AREA_COVERAGE:-0.00}%"
    fi

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

    show_area_health_check "${AREA:-}" "${AREA_COVERAGE:-0.00}" "${AREA_UNMATCHED_INST:-0}" "${NATIVE_AREA:-}" "$NATIVE_AREA_SOURCE" "$REPORT_STAGE"

    echo ""
    echo "========== SEQUENTIAL / LOGIC CELLS =========="

    PHYSICAL_CELL_COUNT=""
    SUMMARY_CELL_COUNT=""

    if [ "$REPORT_STAGE" = "SYNTHESIS" ] && [ -f "$STAT_RPT" ]; then
        DFF_COUNT=$(synth_stat_dff_count "$STAT_RPT")
        STD_CELL_COUNT=$(synth_stat_total_cells "$STAT_RPT")
        [ -z "$DFF_COUNT" ] && DFF_COUNT=0
        [ -z "$STD_CELL_COUNT" ] && STD_CELL_COUNT=0
        echo "DFF-like cells             : ${DFF_COUNT}  (from synth_stat.txt)"
        echo "Standard cells             : ${STD_CELL_COUNT}  (from synth_stat.txt)"
        SUMMARY_CELL_COUNT="$STD_CELL_COUNT"
    else
        PHYSICAL_CELL_COUNT=$(extract_openroad_cell_type_count "Total" \
            "${LOG_DIR}/6_report.log" \
            "${LOG_DIR}/6_report.json")
        PHYSICAL_SEQ_COUNT=$(extract_openroad_cell_type_count "Sequential cell" \
            "${LOG_DIR}/6_report.log" \
            "${LOG_DIR}/6_report.json")
        DFF_COUNT=$(logic_cells "$NETLIST" "$AREA_TOP" | grep -Ei 'DFF|SDFF|DFX|LATCH|LAT' | wc -l | tr -d ' ')
        STD_CELL_COUNT=$(logic_cells "$NETLIST" "$AREA_TOP" | wc -l | tr -d ' ')
        CORE_LOGIC_COUNT=$(core_logic_cells "$NETLIST" "$AREA_TOP" | wc -l | tr -d ' ')
        if [ -n "$PHYSICAL_SEQ_COUNT" ]; then
            DFF_COUNT="$PHYSICAL_SEQ_COUNT"
        fi
        if [ -n "$PHYSICAL_CELL_COUNT" ]; then
            echo "Physical cells           : ${PHYSICAL_CELL_COUNT}"
            SUMMARY_CELL_COUNT="$PHYSICAL_CELL_COUNT"
        else
            SUMMARY_CELL_COUNT="$STD_CELL_COUNT"
        fi
        echo "DFF-like cells             : ${DFF_COUNT}"
        echo "Logic cells in netlist     : ${STD_CELL_COUNT}"
        echo "Core logic cells no BUF/INV: ${CORE_LOGIC_COUNT}"
    fi
    if [ "$REPORT_STAGE" = "POST-ROUTE" ]; then
        echo "Cell count mode            : OpenROAD final cell type report when available"
    else
        echo "Cell count mode            : synthesis stat file when available"
    fi
    echo "Note: DFF-like cell count is register count, not exact pipeline depth."

    echo ""
    echo "========== NAND2 EQUIVALENT =========="

    NAND2_AREA_SRC="${REPORT_AREA:-${AREA:-0}}"
    if [ "${NAND2_AREA_SRC}" = "0" ] || [ "${NAND2_AREA_SRC}" = "0.000000" ]; then
        NAND2_AREA_SRC="${NATIVE_AREA:-0}"
    fi
    if [ -n "$NAND2_AREA_SRC" ] && awk "BEGIN {exit !(${NAND2_AREA_SRC} > 0)}" 2>/dev/null; then
        NAND_PAIR=$(find_nand2_cell_any)
        if [ -n "$NAND_PAIR" ]; then
            NAND_LIB="${NAND_PAIR%%|*}"
            NAND2_CELL="${NAND_PAIR##*|}"
            NAND2_AREA=$(lib_cell_area "$NAND_LIB" "$NAND2_CELL")
        else
            NAND2_AREA=""
        fi
        if [ -n "$NAND2_AREA" ]; then
            NAND_EQ=$(awk "BEGIN {printf \"%.2f\", ${NAND2_AREA_SRC}/${NAND2_AREA}}")
            echo "${NAND2_CELL} area              : ${NAND2_AREA} μm²"
            echo "Estimated NAND2 equivalent : ${NAND_EQ}"
            echo "NAND2 Liberty              : ${NAND_LIB#$ORFS_ROOT/}"
            echo "Note: NAND2 equivalent = total cell area / ${NAND2_CELL} area."
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

    if [ "$REPORT_STAGE" = "SYNTHESIS" ] && [ -f "$STAT_RPT" ]; then
        TOP_CELL_COUNTS=$(synth_stat_cell_counts "$STAT_RPT")
    else
        TOP_CELL_COUNTS=$(logic_cells "$NETLIST" "$AREA_TOP" | sort | uniq -c | awk '{print $1, $2}')
    fi

    printf "%s\n" "$TOP_CELL_COUNTS" | sort -nr | head -10 | \
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
    # ============================================================
    # Summary box
    # ============================================================
    CLK_NS="N/A"
    CLK_GHZ="N/A"
    if [ -f "$CLOCK_FILE" ]; then
        CLK_NS=$(awk '{printf "%.4f", $1/1000}' "$CLOCK_FILE" 2>/dev/null)
        CLK_GHZ=$(awk '{printf "%.2f", 1000/$1}' "$CLOCK_FILE" 2>/dev/null)
    fi
    [ -z "$CLK_NS" ] && CLK_NS="N/A"
    [ -z "$CLK_GHZ" ] && CLK_GHZ="N/A"

    STAGE_LABEL="📋  REPORT SUMMARY"
    ACCURACY_TITLE=""
    ACC1="" ACC2="" ACC3="" ACC4="" ACC5="" ACC_FOOT=""
    if [ "$REPORT_STAGE" = "SYNTHESIS" ]; then
        ACCURACY_TITLE="Stage: SYNTHESIS (pre-layout STA)"
        ACC1="[exact]   Cell count     From Yosys synth_stat.txt"
        ACC2="[exact]   Chip area      Sum of all submodule areas"
        ACC3="[optim.]  Timing margins Pre-layout, zero wire"
        ACC4="[optim.]  Worst slack    No RC parasitics included"
        ACC5="[est.]    Gate equiv     NAND2_X1 Liberty area estimate"
        ACC_FOOT="WNS 10-30% worse after P&R. Only post-route is signoff."
    else
        ACCURACY_TITLE="${POST_ROUTE_ACCURACY_TITLE:-Stage: POST-ROUTE (STA)}"
        ACC1="[exact]   Cell count     From OpenROAD final cell report"
        ACC2="[exact]   Chip area      OpenROAD final physical area"
        ACC3="${POST_ROUTE_ACC3:-[route]   Timing margins Post-route timing}"
        ACC4="${POST_ROUTE_ACC4:-[route]   Worst slack    Post-route timing}"
        ACC5="[est.]    Gate equiv     Physical area / NAND2 area"
        ACC_FOOT="${POST_ROUTE_FOOT:-Review parasitic source before final signoff.}"
    fi

    echo ""
    echo "  ┌──────────────────────────────────────────────────────┐"
    printf "  │ %-52s │\n" "  ${STAGE_LABEL}"
    echo "  ├──────────────────────────────────────────────────────┤"
    printf "  │  %-20s │ %-29s │\n" "PDK / platform" "${PLATFORM:-N/A}"
    printf "  │  %-20s │ %-29s │\n" "Clock period" "${CLK_NS} ns"
    printf "  │  %-20s │ %-29s │\n" "Clock frequency" "${CLK_GHZ} GHz"
    echo "  ├──────────────────────────────────────────────────────┤"
    printf "  │  %-20s │ %-29s │\n" "WNS (OpenSTA)" "${WNS:-N/A} ${TIME_UNIT}"
    printf "  │  %-20s │ %-29s │\n" "Worst setup slack" "${SETUP_SLACK_DISPLAY:-N/A}"
    printf "  │  %-20s │ %-29s │\n" "TNS (OpenSTA)" "${TNS:-N/A} ${TIME_UNIT}"
    printf "  │  %-20s │ %-29s │\n" "WHS (hold)" "${WHS_DISPLAY:-N/A}"
    printf "  │  %-20s │ %-29s │\n" "THS (hold)" "${THS_DISPLAY:-N/A}"
    printf "  │  %-20s │ %-29s │\n" "Worst slack (all)" "${WS_DISPLAY:-N/A}"
    printf "  │  %-20s │ %-29s │\n" "Critical delay" "${CRITICAL_DELAY_SUMMARY:-N/A}"
    printf "  │  %-20s │ %-29s │\n" "Est. Fmax" "${MAX_FREQ_GHZ:-N/A} GHz"
    echo "  ├──────────────────────────────────────────────────────┤"
    printf "  │  %-20s │ %-29s │\n" "Design area" "${REPORT_AREA:-N/A} μm²"
    printf "  │  %-20s │ %-29s │\n" "NAND2 equiv" "${NAND_EQ:-N/A}"
    printf "  │  %-20s │ %-29s │\n" "DFF count" "${DFF_COUNT:-N/A}"
    printf "  │  %-20s │ %-29s │\n" "Total cells" "${SUMMARY_CELL_COUNT:-${STD_CELL_COUNT:-N/A}}"
    echo "  ├──────────────────────────────────────────────────────┤"
    printf "  │  %-52s │\n" "  ${ACCURACY_TITLE}"
    printf "  │  %-52s │\n" "${ACC1}"
    printf "  │  %-52s │\n" "${ACC2}"
    printf "  │  %-52s │\n" "${ACC3}"
    printf "  │  %-52s │\n" "${ACC4}"
    printf "  │  %-52s │\n" "${ACC5}"
    echo "  ├──────────────────────────────────────────────────────┤"
    printf "  │  %-52s │\n" "${ACC_FOOT}"
    echo "  └──────────────────────────────────────────────────────┘"
    echo ""

    echo "========================================"
    exit 0
fi

usage
