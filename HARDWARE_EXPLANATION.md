# Hardware Modules, Explained Simply

For every module: **what it calculates, why we need it, and which exact
line of the original Python code it exists to replace.**

Original Python source (`advance()`, the function this whole chip exists
to replace):
```python
dx = x1 - x2
dy = y1 - y2
dz = z1 - z2
mag = dt * ((dx*dx + dy*dy + dz*dz) ** (-1.5))
b1m = m1 * mag
b2m = m2 * mag
v1[0] -= dx * b2m
v1[1] -= dy * b2m
v1[2] -= dz * b2m
v2[0] += dx * b1m
v2[1] += dy * b1m
v2[2] += dz * b1m
...
r[0] += dt * vx    # position update, after all 10 pairs
```
Every module below exists to compute one piece of this.

---

## `fp_add` — adds (or subtracts) two numbers

**Calculates:** `a + b`. Subtraction is done by flipping the sign of one
input first, then adding — same module does both.

**Why we need it:** almost every line above is an add or a subtract:
`x1 - x2` (the `dx`/`dy`/`dz` lines), `dx*dx + dy*dy + dz*dz` (summing the
three squared terms), `v1[0] -= dx*b2m` (subtracting), and the final
`r[0] += dt*vx` position update. This one module is reused for all of
those — it's the single most-used piece of hardware in the whole chip.

**In plain terms:** it's the calculator's `+`/`−` button.

---

## `fp_mul` — multiplies two numbers

**Calculates:** `a × b`.

**Why we need it:** used for every multiplication in the code:
- `dx*dx`, `dy*dy`, `dz*dz` — squaring the distance components
- `m1 * mag`, `m2 * mag` — scaling the gravity strength by each body's mass
- `dx * b2m`, `dy * b1m`, etc. — turning the gravity strength into an
  actual velocity change
- `dt * vx` — turning velocity into a position change

**In plain terms:** it's the calculator's `×` button.

---

## `fp_sqrt` — square root

**Calculates:** `√x`.

**Why we need it:** the Python line `(dx*dx + dy*dy + dz*dz) ** (-1.5)` is
mathematically the same as `1 / (d² × √d²)` — Newton's gravity law needs
distance *cubed* in the denominator, and the cleanest way to build "distance
cubed" out of "distance squared" (which is all we've computed so far) is
`d² × √d²`. So this module computes that `√d²` piece.

**Why it takes 54 clock cycles instead of being instant like add/multiply:**
there's no simple circuit trick for square root — the hardware has to guess
one bit of the answer at a time and check itself, similar to how you'd do
long division by hand. 54 steps = 54 clock cycles.

---

## `fp_div` — divides two numbers

**Calculates:** `a ÷ b`. Specifically here: `dt ÷ (d² × √d²)`.

**Why we need it:** this single division *is* the `mag` variable in the
Python code — `mag = dt * ((dx*dx+dy*dy+dz*dz) ** (-1.5))` is exactly
`dt / (d² × √d²)`. `mag` is "how strongly do these two bodies pull on each
other, scaled by this timestep" — the core physics number everything else
is built from.

**Why 55 cycles:** same reason as sqrt — division is done digit-by-digit in
hardware, not instantly.

---

## `body_regfile` — where the 5 bodies' numbers live

**Calculates:** nothing — it's just memory. 35 storage slots (5 bodies ×
7 numbers each: x, y, z position; x, y, z velocity; mass).

**Why we need it:** this *is* Python's `BODIES` dictionary and `SYSTEM`
list, moved on-chip. In Python:
```python
BODIES = {'sun': ([x,y,z], [vx,vy,vz], mass), 'jupiter': (...), ...}
```
Same data, same 5 bodies, just stored as 35 numbered hardware registers
instead of a Python dictionary — because reading a dictionary in Python is
slow (that's literally raytrace's whole problem, remember), but reading a
numbered hardware register is instant.

---

## `pair_rom` — the list of which bodies to compare

**Calculates:** nothing — it's a fixed lookup table. Given a number 0-9, it
returns which two bodies that pair refers to (0=sun-jupiter, 1=sun-saturn,
... 9=uranus-neptune).

**Why we need it:** this *is* Python's `PAIRS = combinations(SYSTEM)` —
the same 10 fixed pairs, computed once and never changing, just baked into
hardware instead of a Python list.

---

## `nbody_core` — the conductor that runs the whole loop

**Calculates:** nothing itself — it's the sequencer that decides, cycle by
cycle, *which* module (`fp_add`, `fp_mul`, `fp_sqrt`, `fp_div`) gets used
next, and feeds it the right numbers.

**Why we need it:** this *is* the two nested Python loops:
```python
for i in range(n):                 # <- nbody_core's iteration counter
    for pair in pairs:              # <- nbody_core's pair_idx counter
        ...all the math above...
    for body in bodies:              # <- nbody_core's position-update pass
        r[0] += dt * vx
```
Since there's only *one* `fp_add`, *one* `fp_mul`, *one* `fp_sqrt`, and
*one* `fp_div` built for the whole chip (building 10 copies would use 10x
the silicon), `nbody_core`'s entire job is deciding, step by step, who gets
to use them next — read body i's data, then body j's, subtract, square,
sum, square-root, divide, multiply by mass, update velocity, write it back,
move to the next pair, and after 10 pairs, update all 5 positions, then
start the next of the 20,000 iterations.

---

## `nbody_accelerator` (top module) — the mailbox the CPU talks to

**Calculates:** nothing — it's the interface.

**Why we need it:** this replaces the Python call itself —
`advance(0.01, iterations)`. Instead of calling a function, the CPU:
1. Writes the 5 bodies' starting numbers into `body_regfile` (via numbered
   "mailbox" addresses)
2. Writes `dt` and how many iterations to run
3. Writes a "start" bit
4. Waits
5. Reads the final numbers back out

That's the entire hardware/software handshake — two rounds of talking
instead of running 20,000 Python loop iterations.
