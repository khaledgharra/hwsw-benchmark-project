# Hardware Accelerator — Full Explanation
# Architecture, datapath, FSM, MMIO interface, and numeric precision analysis

---

## 1. Why Build a Hardware Accelerator at All?

The software profiling showed that nbody is slow not because the math is hard,
but because Python pays a **per-operation interpreter cost** for every tiny
arithmetic step — roughly 1.5 million indexed list operations across 20,000
iterations. Loop unrolling cut that by 32.9% but still pays that cost for
every add/multiply in software.

The accelerator's answer: **take the CPU out of the loop entirely.**

The host writes the 5 bodies' initial state into the hardware and asserts
START. The hardware runs all 20,000 iterations autonomously. The host comes
back when it is done and reads the results. Two MMIO round-trips instead of
1.5 million individual software-dispatched operations.

---

## 2. The Number Format — Q16.16 Fixed Point

Every number in this design is a **32-bit signed Q16.16 fixed-point** value.

```
bit 31       bit 16  bit 15       bit 0
[ integer part 16b ][ fractional part 16b ]
```

The real value represented is: `stored_integer / 2^16`

Examples:

| Real value | Stored as |
|---|---|
| `0.01` (dt) | `0x0000_028F` (= 655) |
| `1.0` | `0x0001_0000` (= 65536) |
| `-3.5` | `0xFFFC_8000` |
| `39.5` (≈ SOLAR_MASS) | `0x0027_8000` |

**Why fixed point instead of IEEE-754 float?**
Every value in this benchmark (positions in AU, velocities scaled by
DAYS_PER_YEAR, masses up to SOLAR_MASS ≈ 39.5) fits within Q16.16's ±32768
range. Fixed point is dramatically simpler hardware — no exponent logic,
no normalization, no rounding modes, no NaN/Inf handling. For a design
exercise where the goal is to demonstrate the accelerator concept, it is
sufficient.

---

## 3. Q16.16 Precision vs. Float32 vs. Float64 — Does It Matter?

**Short answer: yes, Q16.16 is not precise enough for a production replacement
of the Python float64 simulation. For a real accelerator you would use
IEEE-754 float64.**

### What precision each format gives you

| Format | Bits | Decimal digits | Notes |
|---|---|---|---|
| Q16.16 (this design) | 32-bit | ~4–5 fractional digits | Fixed range ±32768 |
| IEEE-754 float32 | 32-bit | ~7 significant digits | Dynamic range ±3.4×10^38 |
| IEEE-754 float64 | 64-bit | ~15 significant digits | What Python uses |

### Why Q16.16 accumulates too much error for nbodyhow

The simulation runs 20,000 timesteps. Each step does roughly 75 multiply-add
operations. Rounding error accumulates at every step. With Q16.16's ~4-5
digits of fractional precision:

- Each operation introduces an error of up to 2^-16 ≈ 1.5×10^-5
- Over 20,000 × 75 = 1.5 million operations, that error builds up
- The final positions and velocities could be meaningfully wrong compared
  to the Python float64 reference

The energy conservation check in the software showed even two float64
implementations agreeing to ~12 significant digits. A Q16.16 implementation
would likely drift to only 3–4 digits of agreement after 20,000 steps.

### Why float32 is also borderline

Float32 gives ~7 significant digits. For a 20,000-step simulation where
positions span many AU and velocities are small (10^-3 to 10^-2 AU/day),
float32 would likely give acceptable results for this specific workload —
but it is still weaker than Python's float64 and would show measurable
drift in longer simulations.

### Why float64 is the right choice for correctness

Float64 matches Python's native `float` type exactly. The hardware result
would agree with the software result to the same ~12 significant digits
the software-to-software comparison showed. This is the standard used in
scientific computing accelerators (e.g., NVIDIA's CUDA tensor cores offer
float64 for exactly this reason).

### Why this design uses Q16.16 anyway

Building an IEEE-754 FPU in hardware is significantly more complex:
- Needs exponent alignment before add/subtract
- Needs mantissa normalization after multiply
- Needs rounding mode logic
- Denormals, NaN, and Inf handling
- Float64 doubles all of that to 64-bit datapaths

For this assignment (not synthesized or verified), Q16.16 was chosen because
it demonstrates the accelerator architecture clearly without the hardware
complexity of a full FPU. The report explicitly states this is a
"workload-specialized accelerator, not a general-purpose FPU."

**In a real production design, the fp_mul/fp_sqrt/fp_div modules would be
replaced with IEEE-754 float64 units (or licensed FPU hard macros), and
the body_regfile would store 64-bit words. Everything else — the FSM,
pair_rom, MMIO interface — stays identical.**

---

## 4. Module Overview

The design has 7 modules. From bottom to top:

```
nbody_accelerator  (top-level: MMIO interface + wiring)
├── body_regfile   (140 bytes of on-chip body state)
└── nbody_core     (FSM + datapath)
    ├── pair_rom   (lookup table: 10 fixed body pairs)
    ├── fp_mul     (combinational Q16.16 multiplier)
    ├── fp_sqrt    (iterative sqrt, 17 cycles)
    └── fp_div     (iterative divider, 48 cycles)
```

---

## 5. `fp_mul` — The Multiplier

**Type: combinational (zero latency)**

```systemverilog
logic signed [63:0] full;
assign full = a * b;       // Q32.32 intermediate
assign p    = full[47:16]; // truncate back to Q16.16
```

When you multiply two Q16.16 numbers, each representing `real × 2^16`:

```
result = (a_real × 2^16) × (b_real × 2^16) = (a_real × b_real) × 2^32
```

That is a Q32.32 result sitting in bits [63:0]. To get back to Q16.16, extract
bits [47:16] — discarding the top 16 overflow guard bits and the bottom 16
sub-resolution noise bits.

Because it is combinational, the FSM uses a "setup then read next cycle"
pattern: assign `mul_a`/`mul_b` in state N (non-blocking, takes effect at end
of clock edge), read `mul_p` in state N+1 (now reflects the new inputs).

---

## 6. `fp_sqrt` — Square Root

**Type: iterative, 17-cycle latency**

Uses a **non-restoring binary square root** — the hardware equivalent of the
long-division square root method, but in binary. It processes the 32-bit input
two bits at a time, from the most significant pair down to the least significant.

Each iteration (RUN state) decides whether the next result bit is 0 or 1:

```systemverilog
if ({rem[29:0], x[2*i +: 2]} >= {root[29:0], 2'b01}) begin
    rem  <= shifted_rem - trial;
    root <= {root[30:0], 1'b1};   // this bit is 1
end else begin
    rem  <= shifted_rem;
    root <= {root[30:0], 1'b0};   // this bit is 0
end
```

After 16 iterations, `root[15:0]` holds `isqrt(x)` — the integer square root
of the raw 32-bit Q16.16 value.

**Q16.16 output scaling derivation:**
- x represents `x_real = x / 2^16`
- We want `sqrt(x_real) = sqrt(x) / 2^8`
- In Q16.16 encoding: `sqrt(x_real) × 2^16 = isqrt(x) × 2^8 = isqrt(x) << 8`
- Hence: `assign result = {root[23:0], 8'b0}` — shifts the 16-bit result left
  by 8 into the correct Q16.16 position.

**State machine:** IDLE → RUN (16 cycles) → DONE (asserts `done` for 1 cycle) → IDLE

---

## 7. `fp_div` — Divider

**Type: iterative, 48-cycle latency**

Uses **restoring long division** in binary. To preserve precision for Q16.16,
the dividend is pre-shifted left by 16 bits to create a 48-bit value. The
division then runs 48 shift-compare-subtract iterations.

```
dividend = a << 16     (48 bits: shifts the numerator up by 16)
divisor  = b           (zero-extended to 48 bits)
→ 48 iterations → quotient[47:0]
→ result = quotient[31:0]   (the Q16.16 answer lives in the lower 32 bits)
```

Each RUN cycle: shift remainder left, bring in next dividend bit, compare
against divisor — if ≥, subtract and set quotient bit to 1, else set to 0.

The 48-cycle latency is the dominant bottleneck per pair (~59% of the per-pair
cycle count). A Newton-Raphson divider with a LUT seed could cut this to ~5
cycles, at the cost of more area.

**State machine:** IDLE → RUN (48 cycles) → DONE → IDLE

---

## 8. `body_regfile` — On-chip State Memory

Stores all 5 bodies' state on-chip. 35 words × 32 bits = 140 bytes.

**Layout: `address = body_index × 7 + field`**

| Field offset | What |
|---|---|
| 0, 1, 2 | pos.x, pos.y, pos.z |
| 3, 4, 5 | vel.x, vel.y, vel.z |
| 6 | mass |

Body indices: 0=sun, 1=jupiter, 2=saturn, 3=uranus, 4=neptune.

So for example: jupiter's vel.y is at address `1×7 + 4 = 11`.

**Dual-ported:** two independent access paths:
- **Host port** — used before/after a run via MMIO to load initial state and
  read back results
- **Core port** — used by `nbody_core` during a run to read/write velocities
  and positions

Host write takes priority over core write. In practice the host only touches
the regfile when `BUSY=0`, so there is no real conflict.

Reads are asynchronous (`assign host_rdata = mem[host_addr]`), writes are
registered — so a read sees the current stored value immediately, and a write
takes effect on the next clock edge.

---

## 9. `pair_rom` — The 10 Pair Table

A purely combinational lookup table. Address 0–9 maps to the 10 unique body
pairs, in exactly the same order as Python's `combinations(SYSTEM)`:

| addr | pair |
|---|---|
| 0 | sun – jupiter |
| 1 | sun – saturn |
| 2 | sun – uranus |
| 3 | sun – neptune |
| 4 | jupiter – saturn |
| 5 | jupiter – uranus |
| 6 | jupiter – neptune |
| 7 | saturn – uranus |
| 8 | saturn – neptune |
| 9 | uranus – neptune |

`nbody_core` drives `pair_idx` (0–9) and combinationally gets back `pr_i` and
`pr_j` — the two body indices for the current pair.

---

## 10. `nbody_core` — The FSM and Datapath

This is where the physics runs. A finite state machine drives the shared
`fp_mul`, `fp_sqrt`, and `fp_div` units through a fixed sequence to process
each of the 10 pairs per iteration.

### The shared-multiplier timing rule

`fp_mul` is combinational. `mul_a` and `mul_b` are registered (assigned with
`<=` in `always_ff`). So:

- **Setup state:** `mul_a <= X; mul_b <= Y;` — values take effect at the END
  of this clock edge
- **Capture state (next cycle):** `result <= mul_p;` — now `mul_p = X*Y`

Every multi-cycle multiply sequence follows this two-state pattern.

### Full state sequence per body pair

```
S_IDLE
  ↓  (start pulse)
S_LOAD_I / S_LOAD_J   — load body i and j from regfile into scratch regs
  ↓
S_SUB                 — dx=xi-xj, dy=yi-yj, dz=zi-zj  (subtractors)
  ↓
S_SQ_X                — set mul_a=dx, mul_b=dx
S_SQ_Y                — dxsq = mul_p  (=dx²); set mul_a=dy, mul_b=dy
S_SQ_Z                — dysq = mul_p  (=dy²); set mul_a=dz, mul_b=dz
S_SUM                 — d2 = dxsq + dysq + mul_p  (mul_p=dz²); assert sqrt_start
  ↓
S_SQRT                — wait 17 cycles for fp_sqrt; capture sqrt_d2
  ↓
S_DENOM               — set mul_a=d2, mul_b=sqrt_d2
S_DENOM_WAIT          — denom = mul_p  (=d2×√d2); assert div_start
  ↓
S_DIV                 — wait 48 cycles for fp_div; capture mag = dt/(d2×√d2)
  ↓
S_MASSMUL_I           — set mul_a=mj, mul_b=mag
S_MASSMUL_J           — b_im = mul_p  (=mj×mag); set mul_a=mi, mul_b=mag
S_MASSMUL_WAIT        — b_jm = mul_p  (=mi×mag); prime: mul_a=dx, mul_b=b_im
  ↓
S_VELUPD  (vel_step 0–5, one fp_mul per step)
  step 0: vxi -= mul_p (=dx×b_im); set up dy×b_im
  step 1: vyi -= mul_p (=dy×b_im); set up dz×b_im
  step 2: vzi -= mul_p (=dz×b_im); set up dx×b_jm
  step 3: vxj += mul_p (=dx×b_jm); set up dy×b_jm
  step 4: vyj += mul_p (=dy×b_jm); set up dz×b_jm
  step 5: vzj += mul_p (=dz×b_jm); assert rf_we (write back velocities)
  ↓
S_NEXTPAIR
  — pair_idx < 9: pair_idx++, back to S_LOAD_I
  — pair_idx = 9: all 10 pairs done, go to S_POSUPD
  ↓
S_POSUPD  (body_idx 0–4)
  — for each body: pos += dt × vel  (3 components, symbolic)
  — body_idx < 4: body_idx++
  — body_idx = 4: iter_cnt--
      if iter_cnt was 1: assert done, go to S_IDLE
      else: pair_idx=0, back to S_LOAD_I for next iteration
```

### Cycle count estimate per pair

| Stage | Cycles |
|---|---|
| Load / subtract | ~5 |
| Squarings (S_SQ_X/Y/Z + S_SUM) | 4 |
| fp_sqrt | 17 |
| S_DENOM + S_DENOM_WAIT | 2 |
| fp_div | 48 |
| S_MASSMUL (3 states) | 3 |
| S_VELUPD (6 steps) | 6 |
| **Total per pair** | **~85 cycles** |

**Per iteration:** 10 pairs × 85 + position update ≈ **~860 cycles**

**Total for 20,000 iterations:** ~860 × 20,000 = **17.2M cycles**

At 200 MHz → **~86 ms** estimated, versus 155 ms software → **~1.8× speedup**

---

## 11. `nbody_accelerator` — The MMIO Wrapper

The top-level module is the "face" of the chip the CPU driver talks to. It
wraps `nbody_core` and `body_regfile` behind a **memory-mapped register
interface** — the CPU reads and writes specific byte addresses, exactly like
accessing a peripheral register in an embedded system.

### Register map

| Address | Register | Description |
|---|---|---|
| `0x00` | CONTROL | Write bit 0 = 1 to start a run |
| `0x04` | STATUS | bit 0 = BUSY, bit 1 = DONE (sticky, clears on read) |
| `0x08` | DT | Q16.16 timestep (default `0x0000_028F` = 0.01) |
| `0x0C` | N_ITER | Number of iterations (default 20000) |
| `0x40–0x8C` | BODY_STATE[0..34] | 35 × 32-bit body state words |

### Python driver flow (pseudocode)

```python
# 1. Write initial body state (convert Python floats to Q16.16 first)
for i, word in enumerate(to_q16_16(body_state)):
    mmio_write(0x40 + i*4, word)

# 2. Configure
mmio_write(0x08, 0x0000_028F)   # dt = 0.01
mmio_write(0x0C, 20000)          # iterations

# 3. Start
mmio_write(0x00, 1)

# 4. Wait (poll STATUS.BUSY, or block on IRQ line)
while mmio_read(0x04) & 0x1:
    pass

# 5. Read results back (convert Q16.16 back to Python float)
results = [from_q16_16(mmio_read(0x40 + i*4)) for i in range(35)]
```

### The `sticky_done` and `irq` mechanism

`core_done` pulses for exactly 1 clock cycle when the run finishes. If the
CPU is not watching at that exact cycle it would miss it. So:

- `sticky_done` latches the completion: once set, it stays 1 until the CPU
  reads address `0x04` (clear-on-read)
- `irq` pulses for 1 cycle at the same time — can be wired to a CPU interrupt
  line so the driver does not need to spin-poll

This means the CPU can use either polling (`while BUSY: pass`) or
interrupt-driven waiting — both work correctly.

---

## 12. Design Trade-offs — One Multiplier vs. Many

The design uses a **single shared fp_mul/fp_sqrt/fp_div** time-multiplexed
across all 10 pairs. This gives the minimum area footprint.

The parallel option would be 10 Pairwise Gravity Units (one per pair), all
running simultaneously per iteration:

| Design | Iter latency | Area (approx) | Notes |
|---|---|---|---|
| 1 shared unit (this design) | ~860 cycles | 1× | ~86 ms at 200 MHz |
| 10 parallel units | ~86 cycles | 10× | ~8.6 ms — ~18× over software |

With 10 parallel units, all 10 pairs compute simultaneously, and each
iteration takes only the time for one pair (~86 cycles) instead of 860.
The trade-off is 10× the area and power for `fp_sqrt`/`fp_div` — the
expensive iterative units. With only N=5 bodies, all 10 parallel units fit
on a modest FPGA, which is exactly the case where hardware parallelism is
affordable even though software vectorization (numpy) was not.

---

## 13. Files Reference

| File | What it is |
|---|---|
| `hw/nbody_accelerator.sv` | Full SystemVerilog source for the accelerator |
| `hw/nbody_block_diagram.svg` | Block diagram of the accelerator architecture |
| `reports/report_nbody.txt` Section 5 | Hardware proposal writeup with cycle-count estimate |
| `src/nbody_optimized.py` | The optimized software version the HW accelerates |
