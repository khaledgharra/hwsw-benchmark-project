#!/usr/bin/env bash
# script_raytrace.sh
# Environment setup, benchmark execution, profiling, and comparison for: raytrace
set -euo pipefail

BENCH="raytrace"
OUT_DIR="$(dirname "$0")/../reports/raytrace_artifacts"
mkdir -p "$OUT_DIR"

# --- 1. Environment setup ---
# python3 -m venv .venv && source .venv/bin/activate
# pip install pyperformance

# --- 2. Baseline run ---
# pyperformance run --bench "$BENCH" -o "$OUT_DIR/baseline.json"

# --- 3. Profiling (perf + flame graph) ---
# perf record -F 999 -g -o "$OUT_DIR/perf.data" -- python3 -m pyperformance run --bench "$BENCH"
# perf report --stdio -i "$OUT_DIR/perf.data" > "$OUT_DIR/perf_report.txt"
# perf script -i "$OUT_DIR/perf.data" | report flamegraph > "$OUT_DIR/flamegraph.html"

# --- 4. Post-optimization run + comparison ---
# pyperformance run --bench "$BENCH" -o "$OUT_DIR/optimized.json"
# pyperformance compare_to "$OUT_DIR/baseline.json" "$OUT_DIR/optimized.json"

echo "TODO: implement script_raytrace.sh"
