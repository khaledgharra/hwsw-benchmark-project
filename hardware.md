### **Problem 1: The Verilog code is unfinished**

Your chip has a memory (`body_regfile`) where the host stores the 5 bodies' positions, velocities and masses. The calculating part (`nbody_core`) is supposed to read those values, do the gravity math, and write the results back.

But look at these lines in `nbody_core`:

systemverilog

S\_LOAD\_I: begin

&nbsp;&nbsp;&nbsp;&nbsp;{xi, yi, zi, vxi, vyi, vzi, mi} \<= '0; // placeholder load

`'0` means "all zeros." So instead of reading the Sun's real position, it just uses zero. Same for the second body. It's like a calculator that ignores the numbers you typed and always computes with 0\.

Consequences: `dx = 0 - 0 = 0`, so the distance is 0, so it divides by 0\. Meanwhile the results are never written back (`rf_wdata` is hardwired to 0\) and positions are never updated (`S_POSUPD` just counts).

There are also a few smaller bugs of the same kind:

* **Multiplier used 3 times in one clock.** In `S_SQ` you give the single multiplier three different inputs in the same cycle. Hardware can only do one — the last one wins, so dx², dy², dz² all come out wrong.  
* **Wrong address range.** 35 words × 4 bytes \= 140 bytes \= `0x8C`. But that's the *size*, not the *end address*. Starting at `0x40`, the last word is at `0x40 + 0x88 = 0xC8`. Your decoder stops at `0x8C`, so Uranus and Neptune can't be written or read.

**What to change:** make the load states actually read from the register file, sequence the multiplier over 3 cycles, write results back, implement the position update, and change `0x8C` to `0xC8`.

### **Problem 2: Q16.16 can't represent the numbers**

This one would break the design **even if the Verilog were perfect**.

Q16.16 means 16 bits before the decimal point and 16 after. That gives you two limits:

* **Smallest step: 0.000015.** Anything smaller rounds to 0\.  
* **Biggest number: 32,767.** Anything bigger overflows (wraps around to garbage).

Think of it as a ruler that's only 32 meters long and only marked in steps of 0.015 mm.

Now look at what nbody needs. The force factor is `mag = 0.01 / d³`. For Sun–Neptune, d ≈ 30, so `mag = 0.01 / 27,000 ≈ 0.0000004`. That's **smaller than the smallest step** → it becomes exactly 0\. The force between Sun and Neptune disappears. This happens for 8 of the 10 pairs.

Going the other way: when Uranus and Neptune drift apart, d³ reaches about **125,786**. That's **bigger than 32,767** → overflow.

So the physics falls apart: with most forces zero, planets fly off in straight lines and end up hundreds of AU from where they should be.

**What to change:** use floating point. FP32 is enough (I tested it: small error, energy nearly conserved). FP64 gives exactly the same answer as Python. Floating point handles both tiny and huge numbers, which is exactly what this physics needs.

### **How I checked the hardware**

I used two different methods, one for each problem.

#### **Method 1: A Verilog testbench (for Problem 1\)**

A testbench is a second Verilog file that **pretends to be the CPU**. It doesn't become hardware — it's just there to drive your chip in simulation and watch what happens. Mine does exactly what your driver flow describes:

1. Writes the 35 real body values (positions, velocities, masses) into your registers  
2. Writes `N_ITER = 3` (just 3 iterations so it runs fast)  
3. Writes `START`  
4. Waits for your `irq` signal, counting clock cycles  
5. Peeks inside your chip at internal signals, and reads the body values back

I compiled both files together with **Icarus Verilog**, a free simulator:

bash

iverilog \-g2012 \-o sim tb\_nbody\_accelerator.sv nbody\_accelerator.sv

vvp sim

It printed:

irq after 2376 cycles (DONE)

&nbsp;&nbsp;cycles/iteration \= 792  (report estimates \~760)

&nbsp;&nbsp;inside core: dx=00000000 d2=00000000 denom=00000000 mag=ffffffff

&nbsp;&nbsp;xi(loaded sun.x)=00000000  mi(loaded mass)=00000000

&nbsp;&nbsp;body 3 pos.x: wrote 12.894370  read back 0.000000

&nbsp;&nbsp;body 4 pos.x: wrote 15.379697  read back 0.000000

Reading that: the FSM **does** run and finish, and its timing (792 cycles) matches your estimate — that part is good. But every internal value is zero, `mag=ffffffff` is the divider's divide-by-zero result, and bodies 3 and 4 read back as 0 because of the address bug.

I also ran **Verilator**, a stricter tool that checks code without simulating. It flagged `rf_rdata` as "not used" — meaning the core never reads the register file — plus the double-driven `rf_host_addr` error.

#### **Method 2: A Python model (for Problem 2\)**

The Verilog can't test the number format yet, because it computes with zeros. So I wrote a Python program that does **the same integer arithmetic your hardware is designed to do**:

* Multiply: `(a * b) >> 16` — same as your `full[47:16]`  
* Square root: `isqrt(x) << 8` — same as your `fp_sqrt`  
* Divide: `(a << 16) // b` — same as your `fp_div`

Then I ran all 20,000 steps with this integer math, and separately with normal Python floats, and compared. That's where the "8 of 10 forces are zero" and "planets end up 200–430 AU off" numbers come from.

This is called a **bit-accurate model**: software that reproduces the hardware's exact arithmetic. It's the standard way to check a number format *before* spending time on Verilog, because it takes minutes instead of days.

Both files are in the `review_tools` folder I gave you, with instructions. Run them yourself, and once you've fixed the Verilog, re-run the testbench: the internal values should become non-zero, and the final positions should match Python.

&nbsp;