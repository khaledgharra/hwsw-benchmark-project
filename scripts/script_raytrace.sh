#!/usr/bin/env bash
# script_raytrace.sh
# Environment setup, benchmark execution, profiling, and comparison for: raytrace
#
# Intended to run on a Linux host with perf available (the course VM /
# naranja*.cslcs.technion.ac.il QEMU guest). perf's kernel sampling requires
# Linux; this will not work on macOS.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/reports/raytrace_artifacts"
mkdir -p "$OUT_DIR"
cd "$REPO_ROOT"

# --- 1. Environment setup ---
apt update
apt install -y python3-pip python3-dbg linux-tools-common linux-tools-"$(uname -r)"
pip3 install pyperformance

sudo systemctl stop unattended-upgrades 2>/dev/null || true
sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# --- 2. Baseline run ---
python3 -m pyperformance run --bench raytrace -o "$REPO_ROOT/reports/baseline.json"

# --- 3. Profiling (perf + flame graph) ---
# Same vPMU/PMI limitation as nbody - use the software cpu-clock event.
perf record -e cpu-clock -F 999 -g -o "$OUT_DIR/perf.data" -- \
  python3-dbg -m pyperformance run --bench raytrace

perf report --stdio -i "$OUT_DIR/perf.data" > "$OUT_DIR/perf_report.txt"

if [ ! -d /tmp/FlameGraph ]; then
  git clone https://github.com/brendangregg/FlameGraph.git /tmp/FlameGraph
fi
perf script -i "$OUT_DIR/perf.data" > /tmp/raytrace.perf
/tmp/FlameGraph/stackcollapse-perf.pl /tmp/raytrace.perf > /tmp/raytrace.folded
/tmp/FlameGraph/flamegraph.pl /tmp/raytrace.folded > "$OUT_DIR/raytrace_flamegraph.svg"
rm -f /tmp/raytrace.perf /tmp/raytrace.folded

# --- 4. Post-optimization run + comparison ---
python3 src/raytrace_optimized.py -o "$REPO_ROOT/reports/raytrace_optimized.json"
python3 -m pyperf compare_to "$REPO_ROOT/reports/baseline.json" "$REPO_ROOT/reports/raytrace_optimized.json"

echo "Done. See $OUT_DIR and reports/report_raytrace.txt"
