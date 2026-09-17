#!/usr/bin/env bash
# script_nbody.sh
# Environment setup, benchmark execution, profiling, and comparison for: nbody
#
# Intended to run on a Linux host with perf available (the course VM /
# naranja*.cslcs.technion.ac.il QEMU guest). perf's kernel sampling requires
# Linux; this will not work on macOS.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/reports/nbody_artifacts"
mkdir -p "$OUT_DIR"
cd "$REPO_ROOT"

# --- 1. Environment setup ---
# On the course VM image these are already present; kept here for
# reproducibility on a fresh machine.
apt update
apt install -y python3-pip python3-dbg linux-tools-common linux-tools-"$(uname -r)"
pip3 install pyperformance

# Quiet down background package-update jitter before measuring (see
# report_nbody.txt - unattended-upgrades caused ~87% I/O wait and unusable
# variance in early measurements).
sudo systemctl stop unattended-upgrades 2>/dev/null || true
sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# --- 2. Baseline run ---
python3 -m pyperformance run --bench nbody -o "$REPO_ROOT/reports/baseline.json"

# --- 3. Profiling (perf + flame graph) ---
# Hardware `cycles` sampling produces 0 samples on this KVM guest (PMI not
# forwarded to the guest even though counting mode works) - use the
# software cpu-clock event instead.
perf record -e cpu-clock -F 999 -g -o "$OUT_DIR/perf.data" -- \
  python3-dbg -m pyperformance run --bench nbody

perf report --stdio -i "$OUT_DIR/perf.data" > "$OUT_DIR/perf_report.txt"

if [ ! -d /tmp/FlameGraph ]; then
  git clone https://github.com/brendangregg/FlameGraph.git /tmp/FlameGraph
fi
perf script -i "$OUT_DIR/perf.data" > /tmp/nbody.perf
/tmp/FlameGraph/stackcollapse-perf.pl /tmp/nbody.perf > /tmp/nbody.folded
/tmp/FlameGraph/flamegraph.pl /tmp/nbody.folded > "$OUT_DIR/nbody_flamegraph.svg"
rm -f /tmp/nbody.perf /tmp/nbody.folded

# --- 4. Post-optimization run + comparison ---
python3 src/nbody_optimized.py -o "$REPO_ROOT/reports/nbody_optimized.json"
python3 -m pyperf compare_to "$REPO_ROOT/reports/baseline.json" "$REPO_ROOT/reports/nbody_optimized.json"

echo "Done. See $OUT_DIR and reports/report_nbody.txt"
