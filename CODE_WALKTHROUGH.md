# The Important Code in Each Module — Big Picture

This is the key code from `hw/nbody_accelerator.sv`, module by module, with
just the lines that matter and what they're actually doing. Skips the exact
bit-index arithmetic (which digit goes where) — see the file itself or
`HARDWARE_EXPLANATION.md` for that. This is about *structure*: what kind of
code is this, and what is it doing at a glance.

## First, one pattern that shows up everywhere: `assign` vs `always_ff`

Two totally different kinds of code live in this file, and telling them
apart at a glance is the key to reading any of it:

- **`assign x = ...;`** — this is a **wire**, not a step. It's not "do this
  once" — it's "this output is *always*, continuously, equal to this
  expression." No clock involved. `fp_mul` and `fp_add` are built entirely
  out of these — that's *why* they're instant (0 cycles): there's no
  waiting, the answer is just always sitting there on the output wire.

- **`always_ff @(posedge clk) ... state <= NEXT;`** — this is a **clocked
  register**, the actual "do one step, then wait for the next tick"
  behavior. This is how `fp_sqrt`, `fp_div`, and `nbody_core` work: on
  every clock tick, look at what state you're in, do one small thing,
  decide what state to go to next.

Keep that distinction in mind — every module below is one or the other (or,
for `nbody_core`, both at once: an `always_comb` block figuring out *what
to output right now* based on the state, plus an `always_ff` block deciding
*what state to go to next*).

---

## `fp_mul` — all `assign`, no clock

```systemverilog
assign ma = {1'b1, a[51:0]};        // restore implicit leading 1
assign mb = {1'b1, b[51:0]};
assign mp = ma * mb;                 // the actual multiply
assign sp = sa ^ sb;                 // sign of result
assign ep_wide = mp[105] ? (...) : (...);   // exponent, with overflow check
assign p = {sp, ep, mr};             // glue sign+exponent+mantissa back together
```
Big picture: extract the 3 pieces of both numbers, do ONE real multiply
(`ma * mb`), then a handful of small adjustments to keep everything in
proper floating-point format, then glue the pieces back into one 64-bit
number. No loop, no waiting — it's all wires.

---

## `fp_add` — also all `assign`/`wire`, no clock, but more steps

```systemverilog
wire mag_swap = (eb > ea) || ((eb == ea) && (Mb > Ma));   // who's bigger?
wire [10:0] shamt = e_big - e_sml;                          // how far apart?
wire [53:0] B_ext = (shamt >= 54) ? 0 : (M_sml >> shamt);   // shift smaller one over
wire [54:0] raw = do_add ? (A_ext + B_ext) : (A_ext - B_ext);  // the actual add/sub

for (int k = 52; k >= 0; k--)
    if (raw[k]) lz = 6'(52 - k);        // count leading zeros
normed = raw[52:0] << lz;               // shift back into proper form
```
Big picture, in order: **(1)** figure out which input is bigger, **(2)**
shift the smaller one's bits right so both numbers' decimal points line up
(you can't add `1.5×10²` and `3×10⁰` without doing this first), **(3)** add
or subtract the aligned versions, **(4)** the raw result might be in a
weird shape (too big, or lots of leading zeros from near-cancellation), so
the `for` loop counts how far off it is and one final shift fixes it. Still
zero clock cycles — it's a longer chain of wires, not a loop that repeats
over time.

---

## `fp_sqrt` / `fp_div` — the same shape: a 3-state loop

Both of these use `always_ff` and an actual clocked state machine, because
you truly cannot compute a square root or division in one step. Same
skeleton in both:

```systemverilog
typedef enum {IDLE, RUN, DONE} state_t;

case (state)
  IDLE: if (start) begin
          ...set up starting values...
          i <= <largest bit position>;
          state <= RUN;
        end

  RUN: begin
          ...compare, subtract-or-not, shift...   // ONE bit of the answer per cycle
          if (i == 0) state <= DONE;
          else        i <= i - 1;
       end

  DONE: begin done <= 1; state <= IDLE; end
endcase
```
Big picture: `IDLE` waits for the go-signal and loads starting values.
`RUN` executes over and over, once per clock tick, each time producing one
more bit of the final answer (this is *why* it takes 54/55 cycles — one
loop pass per bit). `DONE` raises the finished flag for one cycle. This
exact same "count down a bit-index, one comparison+shift per tick" shape
is the standard hardware algorithm for both sqrt and division — they're
really the same technique applied to slightly different math.

---

## `body_regfile` — no state machine at all, just a memory array

```systemverilog
logic [63:0] mem [0:34];

always_ff @(posedge clk) begin
    if      (host_we) mem[host_addr] <= host_wdata;
    else    if (core_we) mem[core_addr] <= core_wdata;
end

assign host_rdata = mem[host_addr];   // reads are instant, no clock needed
assign core_rdata = mem[core_addr];
```
Big picture: `mem` is just an array — 35 slots. Writing only happens on a
clock tick (and only if something asked to write). Reading is instant
(`assign`, not `always_ff`) — whatever address you're pointing at, its
value is always available on the output wire.

---

## `pair_rom` — a lookup table, nothing else

```systemverilog
always_comb begin
    case (addr)
        4'd0: begin body_i = 0; body_j = 1; end   // sun-jupiter
        ...
    endcase
end
```
Big picture: `always_comb` (not `always_ff`) means this has no memory of
time at all — the moment `addr` changes, `body_i`/`body_j` change with it,
instantly. It's a fixed table, not a process.

---

## `nbody_core` — the conductor: `always_comb` + `always_ff` working together

This is the one module that genuinely uses **both** patterns at once, and
seeing how they divide the work is the key to understanding it:

**The `always_comb` block** — decides what to feed the shared math units
*right now*, purely based on which state we're in:
```systemverilog
always_comb begin
    case (state)
        S_LOAD_I: rf_addr = pr_i * 7 + sub;      // which register to read
        S_SUB: case (sub)
            0: begin fadd_a = xi; fadd_b = -xj; end   // dx = xi - xj
            ...
        S_VELUPD: case (sub)
            0: begin fadd_a = vxi; fadd_b = -mul_p; end
            ...
    endcase
end
```
This block never "does" anything by itself — it's just wiring: "if we're
in this state, connect these values to the adder's inputs."

**The `always_ff` block** — the actual state machine, one step per clock:
```systemverilog
case (state)
    S_LOAD_I: begin
        xi <= rf_rdata;                    // capture what came back
        if (sub == 6) state <= S_LOAD_J;   // done reading body i, move on
        else sub <= sub + 1;                // otherwise read the next field
    end

    S_SUB: begin
        case (sub)
            0: begin dx <= fadd_s; sub <= 1; end
            1: begin dy <= fadd_s; sub <= 2; end
            2: begin dz <= fadd_s; sub <= 0; state <= S_SQ_X; end
        endcase
    end
    ...
    S_NEXTPAIR: begin
        if (pair_idx == 9) state <= S_POSUPD;      // all 10 pairs done
        else begin pair_idx <= pair_idx + 1; state <= S_LOAD_I; end
    end
```
Big picture: every single state does ONE small thing (capture a value,
maybe increment a counter) and then decides the next state. Nothing here
computes anything itself — the actual math happens in `fp_add`/`fp_mul`
(wired up by the `always_comb` block above); this block's entire job is
sequencing: read this, then that, then subtract, then square, then wait
for sqrt, then wait for div, then update velocities, then move to the next
pair — 21 states, one small step each, repeated for 10 pairs × 20,000
iterations.

---

## `nbody_accelerator` (top) — an address decoder

```systemverilog
if (mmio_we) begin
    case (mmio_addr)
        9'h000: if (mmio_wdata[0]) core_start <= 1'b1;   // "start" register
        9'h010: core_dt     <= mmio_wdata;                // "dt" register
        9'h018: core_n_iter <= mmio_wdata[31:0];           // "n_iter" register
        default: if (mmio_addr >= 9'h040 && mmio_addr <= 9'h150) begin
                     rf_host_we    <= 1'b1;                 // route to body_regfile
                     rf_host_wdata <= mmio_wdata;
                 end
    endcase
end

if (core_done) begin
    sticky_done <= 1'b1;   // remember "done" until the host reads it
    irq         <= 1'b1;   // pulse the interrupt line for one cycle
end
```
Big picture: this is just a big `if`/`case` that looks at *which address*
the CPU is writing to and routes the value to the right place — either one
of the 3 control registers, or forwarded straight through to
`body_regfile`. The `sticky_done` trick matters: `core_done` only pulses
for one cycle, but the CPU might not be watching at that exact instant, so
this module latches it into a flag that stays set until the CPU explicitly
reads and clears it — otherwise a slow CPU could miss the "I'm finished"
signal entirely.
