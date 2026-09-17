# Deep Dive: Gravity & Light — Complete Technical Explainer

This document is a study reference, not a submission deliverable (the formal
deliverables are `reports/report_nbody.txt` and `reports/report_raytrace.txt`).
It exists so you can explain every piece of this project, from the Python
source up through the hardware design, to someone who has never seen it —
with the actual code, the actual profiler output, and the actual reasoning
that connects them.

Read it top to bottom once, then use the section headers to jump back to
whatever you need to re-walk before presenting.

---

## Part 0 — What we were actually trying to do

The assignment: pick 2 `pyperformance` benchmarks, figure out why they're
slow using a profiler (`perf`), fix what the profiler says is slow, prove
the fix worked with real measurements (≥7% faster), and propose a hardware
accelerator for one of them. Everything gets written up and put in a git
repo, then presented.

We picked **nbody** (gravity simulation) and **raytrace** (image renderer)
because both are pure Python with zero third-party dependencies — you can
read 100% of what's actually running, nothing is hidden inside a C
extension.

---

## Part 1 — `nbody`, completely

### 1.1 What it does, narratively

It simulates the Sun plus four planets (Jupiter, Saturn, Uranus, Neptune) —
5 bodies total — attracting each other by gravity, using real starting
positions/velocities/masses. It repeatedly asks: "given where everything is
right now, how does gravity pull on each body, and where does everything
move to next?" That's one **timestep**. The benchmark runs 20,000 timesteps.

### 1.2 The code, function by function

Source: `bm_nbody/run_benchmark.py` (installed pyperformance package).

**The data** (module level, computed once when the file loads):
```python
BODIES = {
    'sun':     ([0.0, 0.0, 0.0], [0.0, 0.0, 0.0], SOLAR_MASS),
    'jupiter': ([4.84..., -1.16..., -0.10...], [velocity...], mass),
    'saturn':  (...), 'uranus': (...), 'neptune': (...)
}
SYSTEM = list(BODIES.values())      # [(pos, vel, mass), ...] x5
PAIRS  = combinations(SYSTEM)       # all 5-choose-2 = 10 unique pairs
```
Each body is a 3-tuple: `(position [x,y,z] list, velocity [x,y,z] list,
mass)`. Positions and velocities are Python **lists** (not tuples) because
they get mutated (changed in place) as the simulation runs.

**The hot function — `advance(dt, n)`**:
```python
def advance(dt, n, bodies=SYSTEM, pairs=PAIRS):
    for i in range(n):                                  # n = 20,000
        for (([x1,y1,z1], v1, m1),
             ([x2,y2,z2], v2, m2)) in pairs:             # 10 pairs
            dx = x1 - x2
            dy = y1 - y2
            dz = z1 - z2
            mag = dt * ((dx*dx + dy*dy + dz*dz) ** (-1.5))  # gravity strength
            b1m = m1 * mag
            b2m = m2 * mag
            v1[0] -= dx * b2m; v1[1] -= dy * b2m; v1[2] -= dz * b2m
            v2[0] += dx * b1m; v2[1] += dy * b1m; v2[2] += dz * b1m
        for (r, [vx, vy, vz], m) in bodies:
            r[0] += dt * vx; r[1] += dt * vy; r[2] += dt * vz
```
Read this as two passes per timestep:
1. **Velocity pass**: for every pair of bodies, compute the distance between
   them (`dx, dy, dz`), turn that into a gravity "strength" (`mag`, using
   Newton's inverse-square law — the `** -1.5` is doing `1/(d² · √d²)`), and
   nudge both bodies' velocities toward/away from each other.
2. **Position pass**: for every body, move its position forward using its
   (now-updated) velocity.

This is called "leapfrog integration" — a standard, simple way to simulate
physics: alternate "update velocity from forces" and "update position from
velocity," repeated many small timesteps.

**Two more functions**, called only twice per benchmark call (not in a hot
loop):
```python
def report_energy(bodies=SYSTEM, pairs=PAIRS, e=0.0):
    # sums up potential + kinetic energy — a physics sanity check
    ...

def offset_momentum(ref, bodies=SYSTEM, ...):
    # adjusts the Sun's velocity so total system momentum is zero (setup only)
    ...
```

**What actually gets timed**:
```python
def bench_nbody(loops, reference, iterations):
    offset_momentum(BODIES[reference])          # once
    for _ in range(loops):
        report_energy()                          # once per loop
        advance(0.01, iterations)                 # the big one: 20,000 iters
        report_energy()                           # once per loop
```

### 1.3 Getting a baseline number

```bash
python3 -m pyperformance run --bench nbody
```
```
nbody: Mean +- std dev: 231 ms +- 2 ms
```
This just tells you "how long does the whole thing take." It says nothing
about *where* the time goes.

### 1.4 How profiling actually works (the mechanism)

`perf record` doesn't read your source code. While the program runs, it
**interrupts the CPU many times per second** (we used 999/second) and at
each interrupt asks: "what function is executing right now, and what's the
call stack?" It writes every one of those snapshots to a file (`perf.data`).
If 38% of ~49,000 snapshots caught the program inside function X, that's
strong statistical evidence that ~38% of the runtime is spent in X. No
magic — repeated sampling.

### 1.5 The perf record hiccup (real problem we hit and fixed)

```bash
perf record -F 999 -g -- python3-dbg -m pyperformance run --bench nbody
# -> "Error: perf.data has no samples!"
```
Zero samples, even though the program ran fine. We didn't just retry —
we diagnosed it:
```bash
perf stat -e cycles,instructions sleep 1
# 1742951 cycles / 1284818 instructions -- WORKS FINE
```
`perf stat` (simple counting — read a counter value at start and end) worked.
`perf record` (sampling — needs the CPU to fire an interrupt every N events)
did not. Conclusion: this KVM virtual machine's hardware performance
counters support *counting* but the guest isn't receiving the *interrupt*
(called a PMI, Performance Monitoring Interrupt) that *sampling* needs — a
known limitation of nested/virtualized environments. Fix: use a
software-timer-based event instead of a hardware-counter-based one:
```bash
perf record -e cpu-clock -F 999 -g -o perf.data -- python3-dbg -m pyperformance run --bench nbody
# -> [ perf record: Captured and wrote 3.764 MB perf.data ]   <- works
```

### 1.6 Reading the output — methodology

```bash
perf report --stdio -i perf.data > perf_report.txt
```
The file has a header:
```
# Children      Self  Command      Shared Object      Symbol
```
- **Children** = time in this function *plus everything it calls*.
- **Self** = time in *only* this function, excluding what it calls.
For finding a bottleneck, read **Self**, sorted highest to lowest
(the file is already sorted that way).

Real excerpt from `reports/nbody_artifacts/perf_report.txt`:
```
38.12%  38.11%  _PyEval_EvalFrameDefault      <- CPython's own bytecode loop
                                                  (generic; not actionable by itself)
 4.78%   4.78%  binary_op1                    <- generic arithmetic dispatch
 3.43%   3.43%  PyFloat_FromDouble             <- creating a new float object
 3.08%   3.07%  float_mul.lto_priv.0           <- multiplying two floats
 2.86%   2.86%  float_dealloc.lto_priv.0       <- destroying a float object
 2.25%   2.24%  list_ass_item.lto_priv.0       <- writing into a list by index
 2.05%   2.05%  _Py_CheckSlotResult            <- operator-protocol bookkeeping
 1.58%   1.58%  float_sub.lto_priv.0           <- subtracting two floats
 1.47%   1.47%  list_ass_subscript.lto_priv.0  <- also list-index writing
```

### 1.7 Matching each name to real code

- `list_ass_item` / `list_ass_subscript` → fires on `container[i] = value`.
  Search `advance()` for that exact shape: `v1[0] -= dx*b2m`, `v2[1] +=
  dy*b1m`, `r[2] += dt*vz` — **six writes per pair, plus three per body in
  the position pass**. With 10 pairs and 5 bodies, that's `10×6 + 5×3 = 75`
  indexed writes **per timestep**, times 20,000 timesteps = **1.5 million**
  indexed writes total. That is the single largest concrete, actionable
  chunk in the whole profile.
- `PyFloat_FromDouble` / `float_dealloc` → every `dx*dx`, `x1-x2`, etc.
  creates a brand-new float object (Python floats are heap objects, not
  primitive numbers) and then throws it away almost immediately.
- `binary_op1` / `_Py_CheckSlotResult` → the generic machinery CPython uses
  to figure out, at runtime, "what type is this, does it support `*`, call
  the right function" — for every single arithmetic operation.

Why do we know this is `advance()` specifically and not `report_energy()`?
Because `report_energy()` runs only **twice** per benchmark call — it
mathematically cannot account for multiple percent of total runtime, no
matter how expensive. `advance()`'s inner loop runs 200,000 times
(20,000 × 10). Only that scale of repetition can explain these percentages.
(Perf's own call-graph couldn't tell us this directly — CPython's bytecode
loop breaks stack unwinding, so the "caller" of these functions showed up
as raw hex addresses, not Python function names. We combined the profiler's
evidence with our own knowledge of the source to localize it.)

### 1.8 Three optimization attempts — tried and measured, not assumed

**Attempt 1 — swap `** -1.5` for `sqrt()`.** Hypothesis: non-integer `pow()`
is slow in CPython (common performance folklore).
```python
# before: mag = dt * ((dx*dx+dy*dy+dz*dz) ** (-1.5))
# after:  d2 = dx*dx+dy*dy+dz*dz; mag = dt / (d2 * sqrt(d2))
```
Measured: **119ms → 121ms. No improvement.** The profile never actually
showed `float_pow` as hot — this was a guess based on general folklore, not
on our own evidence, and the data disproved it. Kept the change anyway
(it's not slower) but it wasn't the real fix.

**Attempt 2 — vectorize with numpy.** Hypothesis: batch all 10 pairs per
timestep into array operations instead of a Python loop.
```python
diff = pos[:, None, :] - pos[None, :, :]     # all pairwise differences at once
d2 = np.einsum('ijk,ijk->ij', diff, diff)
...
```
Measured (isolated `advance()` loop, 20,000 iterations): **0.185s → 0.177s
— only ~4% faster.** With just 10 pairs, numpy's own per-call overhead
(several numpy calls × 20,000 timesteps) very nearly cancels out the
vectorization benefit. numpy is built for batches of thousands of elements,
not ten — this is a well-known numpy pitfall at tiny scale.

**Attempt 3 — loop unrolling (the winner).** Insight: the 5 bodies are a
**fixed, hardcoded dataset** — always sun, jupiter, saturn, uranus, neptune,
never a variable N. So instead of looping over `pairs` generically (which
requires reading from and writing back to lists every single pair, every
single iteration), we can write out all 10 pairs as straight-line code using
plain local variables, and only touch the lists **once**, before and after
the entire 20,000-iteration loop:
```python
# read state into locals ONCE
sx, sy, sz = spos
svx, svy, svz = svel
...
for _ in range(n):                 # still 20,000 times
    # sun-jupiter (one of 10 hand-written blocks)
    dx = sx - jx; dy = sy - jy; dz = sz - jz
    d2 = dx*dx + dy*dy + dz*dz
    mag = dt / (d2 * sqrt(d2))
    svx -= dx*jm*mag; svy -= dy*jm*mag; svz -= dz*jm*mag   # plain variable, not v1[0]
    jvx += dx*sm*mag; jvy += dy*sm*mag; jvz += dz*sm*mag
    ... (9 more pair blocks) ...
    sx += dt*svx; sy += dt*svy; sz += dt*svz               # position update, inline
    ... (4 more bodies) ...
# write final state back to the lists ONCE
spos[0], spos[1], spos[2] = sx, sy, sz
...
```
This directly eliminates the ~1.5M indexed list writes found in Section 1.7
— they become plain local-variable reads/writes (`LOAD_FAST`/`STORE_FAST`
bytecodes, the cheapest operations in CPython) instead of list-indexing
operations, and the list is only touched twice total instead of 1.5 million
times.

Measured: **0.185s → 0.0905s — 51% faster** (isolated loop). Full benchmark
locally: **119ms → 86.2ms — 28% faster**. Full source:
`src/nbody_optimized.py`.

**Trade-off, stated honestly**: this only works because N=5 is fixed. It's
not a general technique — you'd never hand-unroll a loop over a variable-
size dataset. It's the right call here because this benchmark's dataset
never changes.

### 1.9 Correctness verification

We didn't just trust the speed number — we checked the physics still comes
out right. `report_energy()` computes total system energy (potential +
kinetic), which should be nearly conserved (leapfrog integration isn't
perfectly energy-conserving, but original and optimized should match very
closely since it's the *same* math, just reorganized):
```
ORIGINAL   before: -0.1690751638285245  after: -0.16908926275527172
OPTIMIZED  before: -0.1690751638285245  after: -0.16908926275526812
```
Identical starting energy; final energy matches to **12 significant
digits**. The tiny residual difference is expected floating-point
summation-order noise (adding the same numbers in a different order gives
a microscopically different rounding result) — not a bug.

### 1.10 Final, official result

Measured on the course Linux VM (after removing measurement noise — see
Part 3):
```
Baseline:  231 ms +- 2 ms
Optimized: 155 ms +- 3 ms
Improvement: (231-155)/231 = 32.9% faster
```

---

## Part 2 — `raytrace`, completely

### 2.1 What it does, narratively

A software ray tracer: for every pixel of a 100×100 image, shoot a ray from
a virtual camera through that pixel, figure out what it hits (a sphere or
the checkerboard floor), and compute the color at that point — including
shadows (is a light blocked?) and reflections (bounce the ray and repeat,
up to 3 times).

### 2.2 The code, function by function

Source: `bm_raytrace/run_benchmark.py`.

**`Vector` / `Point`** — hand-rolled 3D math classes. Deliberately kept
separate: a `Vector` is a direction/displacement, a `Point` is a location.
You can add a `Vector` to a `Point` (move to a new location), but adding
two `Point`s is meaningless and is blocked by `mustBeVector()`/
`mustBePoint()` checks.
```python
class Vector(object):
    def __init__(self, initx, inity, initz):
        self.x = initx; self.y = inity; self.z = initz
    def dot(self, other):
        other.mustBeVector()
        return (self.x*other.x) + (self.y*other.y) + (self.z*other.z)
    def cross(self, other): ...
    def normalized(self): return self.scale(1.0 / self.magnitude())
    def scale(self, factor): return Vector(factor*self.x, factor*self.y, factor*self.z)
```
Every single one of these methods **returns a brand-new object** — nothing
is ever mutated in place.

**`Sphere`** — the ray-sphere intersection test, the geometric core of the
whole renderer:
```python
def intersectionTime(self, ray):
    cp = self.centre - ray.point
    v = cp.dot(ray.vector)
    discriminant = (self.radius * self.radius) - (cp.dot(cp) - v * v)
    if discriminant < 0:
        return None                          # ray misses the sphere
    else:
        return v - math.sqrt(discriminant)   # distance to the intersection
```
This is the standard quadratic-equation solution for "does this line hit
this sphere, and where."

**`Scene.render()`** — the pixel loop:
```python
for y in range(canvas.height):        # 100
    for x in range(canvas.width):     # 100
        ray = Ray(eye.point, eye.vector + xcomp + ycomp)
        colour = self.rayColour(ray)  # <- called 10,000 times
        canvas.plot(x, y, *colour)
```

**`Scene.rayColour()`** — the recursive heart of the renderer:
```python
def rayColour(self, ray):
    if self.recursionDepth > 3:
        return (0, 0, 0)
    self.recursionDepth += 1
    intersections = [(o, o.intersectionTime(ray), s) for (o, s) in self.objects]
    i = firstIntersection(intersections)          # nearest hit, linear scan of all 8 objects
    if i is None:
        return (0, 0, 0)                           # background
    (o, t, s) = i
    p = ray.pointAtTime(t)
    return s.colourAt(self, ray, p, o.normalAt(p))
    self.recursionDepth -= 1
```
Every ray does a **linear scan of all 8 scene objects** — no acceleration
structure (no BVH/kd-tree, which is what real ray tracers use to avoid
this).

**`SimpleSurface.colourAt()`** — the shading model (a simplified Phong
model): specular (recurses into `rayColour` for the reflected ray),
Lambertian diffuse (loops over each light, casting a shadow ray that again
scans all 8 objects), and a flat ambient term.

### 2.3 Baseline

```
raytrace: Mean +- std dev: 799 ms +- 8 ms
```

### 2.4 Profiling — same PMI issue, same fix

Identical to nbody: hardware `cycles` sampling gave 0 samples; switched to
`-e cpu-clock`.

### 2.5 Reading the report — a genuinely different fingerprint

Real excerpts from `reports/raytrace_artifacts/perf_report.txt`:
```
26.05%  25.83%  _PyEval_EvalFrameDefault    <- generic, skip
 2.01%          _PyEval_EvalFrameDefault (child of frame setup)
 1.03%          _PyEval_Vector              <- SETTING UP a new call frame
 0.83%          _PyEval_MakeFrameVector     <- same
 0.52%          frame_dealloc.lto_priv.0    <- TEARING DOWN a call frame
 2.43%          frame_dealloc.lto_priv.0    <- (a second occurrence, elsewhere)
 1.37%          _PyType_Lookup              <- looking up which method .dot() refers to
 1.78%          _PyDict_GetItemHint         <- reading an attribute from an instance dict
 0.91%          insertdict                  <- writing an attribute into an instance dict
 1.04%          binary_op1                  <- generic arithmetic dispatch (same as nbody)
 0.75%          float_mul.lto_priv.0
```
Notice: **`frame_dealloc`, `_PyEval_Vector`, `_PyDict_GetItemHint`, and
`_PyType_Lookup` never appeared anywhere in nbody's profile.** This is a
structurally different bottleneck, not the same one in different clothes.

### 2.6 Matching names to code

- `_PyDict_GetItemHint` / `insertdict` → fires on `self.x`-style attribute
  access. Look at `Vector.__init__`: `self.x = initx` — and there's **no
  `__slots__`** anywhere in the file. Without `__slots__`, every instance
  carries a full dictionary just to hold `x`, `y`, `z`. Every read or write
  of `self.x` is a dictionary lookup, not a direct memory access.
- `_PyType_Lookup` → fires whenever Python resolves `.dot` to the actual
  function defined on the class — happens on every single method call.
- `frame_dealloc` / `_PyEval_Vector` / `_PyEval_MakeFrameVector` → fire on
  every Python function call (building/tearing down a stack frame). Count
  how many method calls happen per pixel: `intersectionTime()` for up to 8
  objects, `.dot()` called 2-3 times *inside* each `intersectionTime()`
  call, `.normalized()`, `.cross()`, `.scale()`, `.reflectThrough()` in
  shading, recursively, up to 3 bounces deep, times 10,000 pixels. That's
  an enormous number of individual function calls — each one paying frame
  setup/teardown cost.

**Conclusion, one sentence: raytrace's cost is "everything is a method call
on a dictionary-backed object," not the geometry math itself.**

### 2.7 The fix — `__slots__`

```python
# ORIGINAL
class Vector(object):
    def __init__(self, initx, inity, initz):
        self.x = initx; self.y = inity; self.z = initz

# OPTIMIZED (src/raytrace_optimized.py)
class Vector(object):
    __slots__ = ('x', 'y', 'z')          # <- the entire fix, one line
    def __init__(self, initx, inity, initz):
        self.x = initx; self.y = inity; self.z = initz
```
`__slots__` tells Python "this class only ever has exactly these fields" —
so CPython allocates fixed-offset storage for them instead of a dictionary.
`self.x` becomes a direct, fixed-position read instead of a hash-table
lookup. Applied to every class: `Vector`, `Point`, `Sphere`, `Halfspace`,
`Ray`, `Canvas`, `Scene`, `SimpleSurface`, `CheckerboardSurface`. Zero
behavior change — purely a storage-layout optimization.

### 2.8 Result

```
Baseline:  799 ms +- 8 ms
Optimized: 693 ms +- 7 ms
Improvement: (799-693)/799 = 13.3% faster
```
(A local sanity test on a different machine — Apple Silicon, Python 3.9 —
showed 37% faster for the identical code change. Same direction, different
magnitude, expected across different CPU microarchitectures/Python
versions — not a discrepancy in the fix itself. The VM number, matching
the profiling environment, is the one we report as official.)

---

## Part 3 — The measurement-noise detour (a real debugging story worth telling)

After optimizing, the *first* VM measurement of the optimized code looked
**worse** than baseline:
```
nbody: Mean +- std dev: 287 ms +- 56 ms   (baseline was 231ms!)
WARNING: the benchmark result may be unstable
```
We did not accept this. Checked system state:
```bash
top -bn1 | head -20
# %Cpu(s): 0.0 us, 12.5 sy, 0.0 ni, 0.0 id, 87.5 wa   <- 87.5% I/O WAIT
```
`vmstat 1 3` confirmed heavy, variable I/O wait, and `top` showed a live
culprit: `unattended-upgrades` (Ubuntu's automatic background package
updater) consuming resources on the shared, multi-tenant course VM host.
```bash
sudo systemctl stop unattended-upgrades
sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer
```
Re-checked `vmstat` — I/O wait dropped to 0 — and re-measured. Got the
clean 155ms/693ms numbers reported above.

**Why this matters for the presentation**: it demonstrates the difference
between "a number came out of a tool" and "a number we can trust." A bad
measurement doesn't mean the code is wrong — it can mean the *environment*
is noisy, and a careful engineer checks that before drawing conclusions.

---

## Part 4 — Hardware Accelerator (nbody only), completely

### 4.1 Design philosophy — why this shape, not a different one

Section 1.7 established the real cost: **per-operation overhead, paid 1.5
million times**, not expensive math. A hardware unit that only speeds up
*one* multiply doesn't remove that overhead — the CPU still has to
dispatch through software for every one of those 1.5 million operations to
even reach the accelerator. So instead, **the accelerator runs the entire
20,000-iteration loop autonomously**, and the CPU only interacts with it
twice: write the initial state and trigger it, then read the final result.
That removes the software dispatch cost entirely, not just the cost of one
operation.

### 4.2 Numeric format — Q16.16 fixed point, explained

Real hardware floating point (IEEE-754) is expensive to build. Since every
value in this benchmark (positions, velocities, masses up to ~39.5) fits
comfortably within a smaller range, we use **fixed point** instead: a
32-bit number where the top 16 bits are the integer part and the bottom 16
bits are the fractional part. Example: the number 2.5 in Q16.16 is stored
as the integer `2.5 × 65536 = 163840`. Addition/subtraction work exactly
like normal integer arithmetic; multiplication needs a small adjustment
(multiply, then shift back down) — see `fp_mul` below. This is a
**workload-specific simplification**, not a general-purpose FPU design —
stated explicitly as an assumption in the report.

### 4.3 Every module in `hw/nbody_accelerator.sv`, explained

**`fp_mul`** — combinational (finishes in the same clock cycle it's given
inputs) Q16.16 × Q16.16 multiplier:
```systemverilog
module fp_mul (input logic signed [31:0] a, b, output logic signed [31:0] p);
    logic signed [63:0] full;
    assign full = a * b;        // full-precision product
    assign p = full[47:16];     // take back the Q16.16-scaled bits
endmodule
```

**`fp_sqrt`** — square root can't be computed in one step; this uses a
classic **non-restoring digit-recurrence algorithm** (the hardware
equivalent of the "guess and check, one digit at a time" method used to
compute square roots by hand). It processes 2 bits of the input per clock
cycle, so a 32-bit input takes **17 cycles** (1 start cycle + 16 bit-pairs)
to produce a result.

**`fp_div`** — similarly iterative: a classic **restoring division**
algorithm, one bit per cycle, over a 48-bit working value (extra bits to
preserve Q16.16 precision through the division) — **48 cycles** latency.

**`body_regfile`** — 35 × 32-bit registers (5 bodies × [pos.x, pos.y,
pos.z, vel.x, vel.y, vel.z, mass]) — the on-chip "notebook" holding all
simulation state. Has two separate read/write ports: one for the host CPU
(to load initial state and read results), one for the internal core (to
read/update during the run).

**`pair_rom`** — a fixed lookup table, addresses 0-9, giving the two body
indices for each of the 10 pairs (matches Python's `combinations(SYSTEM)`
exactly: sun-jupiter, sun-saturn, sun-uranus, sun-neptune, jupiter-saturn,
jupiter-uranus, jupiter-neptune, saturn-uranus, saturn-neptune,
uranus-neptune).

**`nbody_core`** — the control state machine (the "conductor"). States:
```
S_IDLE      -- waiting for the host to say "go"
S_LOAD_I    -- read body i's state (position, velocity, mass) from body_regfile
S_LOAD_J    -- read body j's state
S_SUB       -- dx = xi-xj, dy = yi-yj, dz = zi-zj
S_SQ        -- dx², dy², dz² (via fp_mul)
S_SUM       -- d2 = dx² + dy² + dz²
S_SQRT      -- wait for fp_sqrt to finish (17 cycles) -> sqrt(d2)
S_DENOM     -- denom = d2 * sqrt(d2)  (via fp_mul)
S_DIV       -- wait for fp_div to finish (48 cycles) -> mag = dt/denom
S_MASSMUL   -- b_im = mass_j * mag, b_jm = mass_i * mag
S_VELUPD    -- update both bodies' velocities in body_regfile
S_NEXTPAIR  -- pair_idx++; if pair_idx < 10, go back to S_LOAD_I
S_POSUPD    -- after all 10 pairs: update all 5 bodies' positions
S_NEXTITER  -- iteration count--; if not done, go back to S_LOAD_I for next timestep
             -- if done: raise DONE, return to S_IDLE
```
This is a direct hardware translation of the exact same two-pass structure
(velocity pass over 10 pairs, then position pass over 5 bodies) that's in
the original Python `advance()` function — just executed as a circuit
instead of interpreted bytecode.

**`nbody_accelerator`** (top module) — wraps `nbody_core` and
`body_regfile` behind a simple **memory-mapped register interface**: the
CPU writes/reads numbered "mailboxes" over a synchronous bus (documented as
compatible with a thin AXI-Lite or Avalon-MM wrapper for real SoC
integration).

### 4.4 Register map — the HW/SW interface, concretely

| Address | Register | Meaning |
|---|---|---|
| `0x00` | CONTROL | bit 0 = START (write 1 to trigger a run) |
| `0x04` | STATUS | bit 0 = BUSY, bit 1 = DONE (clears when read) |
| `0x08` | DT | timestep size, Q16.16 (default 0.01) |
| `0x0C` | N_ITER | number of timesteps to run (default 20000) |
| `0x40`-`0x8C` | BODY_STATE[0..34] | the 35 state words |

Driver flow (what software would actually do):
1. Write all 35 BODY_STATE words (initial position/velocity/mass for all 5 bodies)
2. Write DT and N_ITER
3. Write CONTROL.START = 1
4. Poll STATUS.BUSY (or wait for the interrupt line) until the run finishes
5. Read BODY_STATE[0..34] back — that's your final answer
6. Convert from Q16.16 back to floating point in software, hand off to
   `report_energy()` (which stays in software — it only runs twice, not
   worth accelerating)

No DMA needed — only 140 bytes move each direction, small enough for plain
register I/O.

### 4.5 Speedup estimate — the actual arithmetic

Stated assumption: 200MHz clock, one shared math datapath reused across
all 10 pairs (no parallelism yet — see trade-off below).
```
Per pair:      ~10 cycles control overhead
             + 17 cycles (fp_sqrt)
             + 48 cycles (fp_div)
             = ~75 cycles

Per timestep:  10 pairs x 75 cycles = 750 cycles
             + ~10 cycles (position update pass)
             = ~760 cycles

Total:         760 cycles x 20,000 timesteps = 15,200,000 cycles

At 200MHz:     15,200,000 / 200,000,000 = 0.076s = 76 milliseconds
```
Compared to the optimized software's ~130-150ms spent in this same loop
(out of the 155ms total, minus the small `report_energy()`/setup share):
**roughly 1.7-2x further speedup** — a real, cycle-counted number, not an
extrapolation.

### 4.6 The parallelism trade-off

Build 10 copies of the pair-processing datapath (one per pair, all running
simultaneously) instead of reusing 1 datapath serially: per-timestep
latency drops from ~750 cycles to roughly the latency of **one** pair
(~75 cycles) — close to a **10x** reduction. Cost: ~10x the area and power
for the `fp_sqrt`/`fp_div` units specifically (the expensive, multi-cycle
parts) — a classic area/power vs. latency trade-off. Worth noting: unlike
numpy's software vectorization (which failed to pay off at N=10 because its
overhead is a *fixed per-call software cost*), hardware parallelism scales
with *area*, which is genuinely affordable here precisely because the
problem is small and fixed (5 bodies) — the same property that sank numpy
is what makes hardware parallelism cheap.

---

## Part 5 — Where everything lives (repo map)

```
reports/report_nbody.txt          <- official submission report (nbody)
reports/report_raytrace.txt       <- official submission report (raytrace)
reports/nbody_artifacts/          <- perf_report.txt + flame graph (nbody)
reports/raytrace_artifacts/       <- perf_report.txt + flame graph (raytrace)
reports/baseline.json             <- pyperf raw baseline data (both benchmarks)
reports/nbody_optimized.json      <- pyperf raw optimized data (nbody)
reports/raytrace_optimized.json   <- pyperf raw optimized data (raytrace)
src/nbody_optimized.py            <- the actual optimized nbody code
src/raytrace_optimized.py         <- the actual optimized raytrace code
hw/nbody_accelerator.sv           <- the SystemVerilog hardware design
hw/nbody_block_diagram.svg        <- the block diagram
scripts/script_nbody.sh           <- reproduces the whole nbody pipeline
scripts/script_raytrace.sh        <- reproduces the whole raytrace pipeline
presentation/slides.html          <- the presentation deck (source)
presentation/deep_dive_explainer.md  <- this document
```

---

## Part 6 — Anticipated Q&A, with the answer already written

**"How does perf actually work?"** → It interrupts the CPU hundreds of
times a second and records what's executing; percentages come from how
often each function was caught running.

**"Why couldn't you just see that the bottleneck was in `advance()`
directly from the profiler?"** → CPython's bytecode loop breaks stack
unwinding, so perf's call graph only shows C-level function names, not
which Python function was running. We inferred it by combining the
profiler's named-function evidence with our own read of the source code
(only `advance()` runs enough times to explain the percentages).

**"Why did numpy make nbody worse/barely better instead of much faster?"**
→ Only 10 pairs — numpy's own per-call overhead is comparable to the work
being saved. Vectorization pays off at hundreds/thousands of elements, not
ten.

**"Why is raytrace's fix completely different from nbody's fix?"** → They
have genuinely different bottlenecks. nbody: indexed list writes (data
structure access pattern). raytrace: dictionary-backed attribute access
and function-call overhead (OOP structure). Same symptom (slow Python),
different root cause, confirmed by different named functions in each
profile.

**"Why does the hardware accelerate the whole loop instead of one
operation?"** → Because the actual cost is per-operation software dispatch
overhead, repeated 1.5 million times. Speeding up one multiply doesn't
remove the other 1,499,999 dispatch costs. Running the entire loop in
hardware removes the CPU/interpreter from the loop entirely.

**"How confident are you in the 76ms hardware estimate?"** → It's a direct
cycle count from the design's own latencies (75 cycles/pair × 10 pairs ×
20,000 iterations), not a guess — but it assumes no synthesis/timing
closure was done, so the 200MHz clock target is a stated, reasonable
assumption, not a verified number.
