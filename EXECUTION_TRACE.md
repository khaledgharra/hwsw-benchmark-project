# Full Execution Trace: One Complete Run, Cycle by Cycle

This traces the hardware from the moment the host writes data in, through
every state, to the moment the answer comes back out — with real cycle
counts computed from the actual FSM (not estimated).

## 1. Setup — the host writes in, before anything runs

The host CPU writes, over the MMIO bus, in any order:
- **35 body-state words** (`mmio_addr` 0x040–0x150) → routed by
  `nbody_accelerator`'s address decoder into `rf_host_we`/`rf_host_addr`/
  `rf_host_wdata` → land in `body_regfile.mem[0..34]`
- **DT** (0x010) → `core_dt`
- **N_ITER** (0x018) → `core_n_iter`

Then the host writes **CONTROL** (0x000) with bit 0 set. That pulses
`core_start` high for exactly one clock cycle — the only "go" signal
`nbody_core` needs.

## 2. `S_IDLE` → the FSM wakes up

`nbody_core` sees `start=1`: sets `busy<=1`, `iter_cnt<=n_iterations`
(20,000), `pair_idx<=0`, `sub<=0`, and jumps to `S_LOAD_I`.

## 3. One pair, completely, state by state

Take pair 0 = sun-jupiter (`pair_rom` returns `body_i=0, body_j=1` for
`pair_idx=0`).

| State | Cycles | What actually happens |
|---|---|---|
| `S_LOAD_I` | 7 | Read sun's 7 fields (x,y,z,vx,vy,vz,mass) from `body_regfile`, one per cycle, into `xi,yi,zi,vxi,vyi,vzi,mi` |
| `S_LOAD_J` | 7 | Same for jupiter → `xj,yj,zj,vxj,vyj,vzj,mj` |
| `S_SUB` | 3 | `fp_add` computes `dx=xi-xj`, `dy=yi-yj`, `dz=zi-zj` (one component per cycle) |
| `S_SQ_X/Y/Z` | 3 | `fp_mul` computes `dx²`, `dy²`, `dz²` |
| `S_SUM_1`, `S_SUM_2` | 2 | `fp_add` sums them: `d2 = dx²+dy²+dz²` |
| `S_SQRT_LAUNCH` | 1 | Trigger `fp_sqrt` with `d2` |
| `S_SQRT_WAIT` | 54 | Wait — `fp_sqrt` computes `√d2` digit by digit |
| `S_DENOM` | 1 | Trigger `fp_mul`: `d2 × √d2` |
| `S_DENOM_WAIT` | 1 | Capture `denom` |
| `S_DIV_LAUNCH` | 1 | Trigger `fp_div` with `dt / denom` |
| `S_DIV_WAIT` | 55 | Wait — `fp_div` computes `mag` digit by digit |
| `S_MASSMUL_I/J/WAIT` | 3 | `fp_mul`: `b_im = mj × mag`, `b_jm = mi × mag` |
| `S_VELUPD` | 6 | `fp_add`/`fp_mul` together update `vxi,vyi,vzi,vxj,vyj,vzj` scratch registers |
| `S_WB_I` | 3 | Write sun's 3 updated velocities back to `body_regfile` |
| `S_WB_J` | 3 | Write jupiter's 3 updated velocities back |
| `S_NEXTPAIR` | 1 | `pair_idx < 9` → loop back to `S_LOAD_I` for the next pair |
| **Total** | **151 cycles** | one complete pair |

Notice **109 of those 151 cycles (72%) are spent just waiting** on
`fp_sqrt` (54) and `fp_div` (55) — those two iterative units are the
dominant cost, by far, of processing a single pair.

This repeats **10 times** (once per pair) = **1,510 cycles**.

## 4. Position update — after all 10 pairs

`S_NEXTPAIR` sees `pair_idx==9` and jumps to `S_POSUPD` instead of looping.
For each of the 5 bodies (`body_idx` 0→4), 10 sub-steps: read vx/vy/vz,
multiply each by `dt` (`fp_mul`), add to the current x/y/z (`fp_add`,
pipelined one cycle behind), write the 3 new position values back.
**10 steps × 5 bodies = 50 cycles.**

## 5. One full iteration, and the whole run

```
1,510 cycles (10 pairs)  +  50 cycles (5-body position update)
= 1,560 cycles per timestep
```
`S_POSUPD`'s last step checks `iter_cnt`: if it was the last of the 20,000
iterations, asserts `done` and `busy<=0`, returns to `S_IDLE`. Otherwise
decrements `iter_cnt` and jumps straight back to `S_LOAD_I` for the next
timestep.

```
1,560 cycles/iteration × 20,000 iterations = 31,200,000 cycles total
```

## 6. Reading the answer back out

`nbody_accelerator` latches `core_done` into a **sticky** `DONE` bit (so a
slow host can't miss a one-cycle pulse) and raises `irq` for one cycle.
The host, once it notices (polling `STATUS` at 0x008, or via the interrupt),
reads all 35 words back out of `BODY_STATE` (0x040–0x150) — that's the
final position/velocity state after 20,000 timesteps.

## 7. The honest bottom line

```
31,200,000 cycles ÷ 200,000,000 Hz (200MHz) = 0.156 s = 156 ms
```

**This revises the earlier estimate.** The original ~76ms / "1.7-2x
faster" figure assumed ~75 cycles/pair (based on the simpler, earlier
Q16.16 design's 17-cycle sqrt + 48-cycle div). The real, fully-detailed
float64 FSM traced above comes out to **151 cycles/pair** — both because
IEEE-754 sqrt/div genuinely take longer (54/55 cycles, since there's more
precision to grind through) and because the real 21-state FSM has more
control overhead (register loads, write-backs, pipeline staging) than the
earlier back-of-envelope count accounted for.

**156ms vs. software's 155ms is, honestly, a tie — not a win** — for this
single-shared-datapath design. That's not a failure, though — it sharpens
the actual conclusion: **with only one copy of the expensive `fp_sqrt`/
`fp_div` units, hardware barely breaks even with well-optimized software.**
The real case for hardware here is the **parallelism trade-off** already
discussed: building 10 independent pair-processing datapaths (10×
`fp_sqrt`, 10× `fp_div`, etc.) so all 10 pairs of a timestep run
simultaneously instead of serially would cut the ~1,510-cycle pair-loop
down to roughly one pair's latency (~151 cycles) — turning the "tie" into
a real, substantial win, at the honestly-stated cost of ~10x the area and
power for those units. That's now the load-bearing argument for the
hardware proposal, not a secondary trade-off note.
