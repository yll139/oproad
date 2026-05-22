#!/usr/bin/env bash
set -e

export ORFS_ROOT="${ORFS_ROOT:-/OpenROAD-flow-scripts/flow}"
export OPROAD_RUNNER="${OPROAD_RUNNER:-local}"
export OPROAD_DOCKER_TTY="${OPROAD_DOCKER_TTY:-0}"
export OPROAD_FINISH_MODE="${OPROAD_FINISH_MODE:-auto}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"

mkdir -p "$XDG_RUNTIME_DIR" /workspace /project

if [ "$#" -eq 0 ]; then
    exec bash
fi

case "$1" in
    new|sim|synth|implement|run|report|clean|delete)
        exec oproad-runner "$@"
        ;;
    oproad-runner)
        shift
        exec oproad-runner "$@"
        ;;
    bash|sh|make|openroad|yosys|python3|python)
        exec "$@"
        ;;
    *)
        exec "$@"
        ;;
esac
