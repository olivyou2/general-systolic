#!/usr/bin/env bash
set -euo pipefail

# Use a locale that is available in minimal containers.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

TOP_MODULE="${1:-fifo_tb}"
if [[ $# -gt 0 ]]; then
	shift
fi

# Collect SystemVerilog sources from ./src.
SV_FILES="$(find ./src -type f -name "*.sv")"

if [ -z "${SV_FILES}" ]; then
	echo "No .sv files found under ./src"
	exit 1
fi

verilator --binary -I./src --top-module "${TOP_MODULE}" ${SV_FILES}

SIM_BIN="./obj_dir/V${TOP_MODULE}"
if [[ ! -x "${SIM_BIN}" ]]; then
	echo "Built binary not found or not executable: ${SIM_BIN}"
	exit 1
fi

"${SIM_BIN}" "$@"
