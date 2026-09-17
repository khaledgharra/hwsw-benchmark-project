# HWSW Project: Benchmark Optimization, Analysis, and Hardware Acceleration Proposal

Course: 00460882 - HW/SW Co-design
Author: Khaled Gharra

## Overview

This repository contains the analysis, optimization, and hardware acceleration
proposal for two benchmarks selected from the `pyperformance` framework, as
required by the course final project.

Selected benchmarks: TBD (2 of: Raytrace, Deepcopy, Mdp, Pathlib,
Pickle/pickle_dict, Pyflate, unpack_sequence, tornado_http, sqlite_synth,
Nbody, Btree, deepblue, go)

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
analysis, optimizations applied, performance comparison, and hardware
acceleration proposal for that benchmark.

## AI Tool Usage

All prompts/instructions given to AI tools during this project are logged in
`prompt.txt`, per course requirements.
