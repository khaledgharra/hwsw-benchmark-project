# HWSW Project: Benchmark Optimization, Analysis, and Hardware Acceleration Proposal

Course: 00460882 - HW/SW Co-design
Author: Khaled Gharra

## Overview

This repository contains the analysis, optimization, and hardware acceleration
proposal for two benchmarks selected from the `pyperformance` framework, as
required by the course final project.

Selected benchmarks: **Raytrace** and **Nbody**

## Repository Structure

```
.
├── reports/          # report_<benchmark>.txt for each selected benchmark
├── scripts/          # script_<benchmark>.sh - setup, run, profile, compare
├── hw/                # Hardware accelerator design files (Verilog/SystemVerilog/PyXHDL)
├── src/               # Supporting Python scripts, optimized benchmark code, configs
├── prompt.txt         # Log of AI tool prompts/instructions used throughout the project
└── README.md
```

## Reproducing Results

Each `scripts/script_<benchmark>.sh` handles:
1. Environment setup and dependency installation
2. Baseline benchmark execution via `pyperformance`
3. Profiling with `perf` and flame graph generation
4. Post-optimization benchmark execution and performance comparison

See each `reports/report_<benchmark>.txt` for the overview, profiling
analysis, optimizations applied, and performance comparison for that
benchmark. Both nbody (32.9% faster) and raytrace (13.3% faster) clear
the assignment's 7% improvement threshold.

The hardware acceleration proposal (`hw/nbody_accelerator.sv`,
`hw/nbody_block_diagram.svg`) targets nbody only, per course guidance
that one proposal is sufficient across the two selected benchmarks. It
is a Pairwise Gravity Accelerator: fixed-point (Q16.16) hardware that
holds all 5 bodies' state on-chip and runs the benchmark's entire
20,000-iteration force-update loop autonomously between two MMIO
round-trips, rather than accelerating a single arithmetic operation the
CPU would still have to dispatch through software for every one of the
~1.5M individual operations profiling identified as the real cost. Full
architecture, I/O spec, and a cycle-counted speedup estimate are in
`reports/report_nbody.txt` Section 5.

## AI Tool Usage

All prompts/instructions given to AI tools during this project are logged in
`prompt.txt`, per course requirements.
