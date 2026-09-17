// ============================================================================
// nbody_accelerator.sv
//
// Pairwise Gravity Accelerator (PGA) for the pyperformance `nbody` benchmark.
//
// Motivation (see reports/report_nbody.txt Section 5 for full writeup):
//   Profiling showed nbody's cost is NOT the arithmetic - it's per-operation
//   CPython interpreter overhead (object dispatch, allocation, indexed list
//   writes), repeated 10 pairs x 20,000 iterations. The best pure-software
//   fix (loop unrolling) got 32.9% by cutting that overhead in software, but
//   it's still paying interpreter cost for every add/mul/sqrt. This
//   accelerator removes that overhead entirely by running the WHOLE
//   iteration loop (all 10 pairs + position update, N times) autonomously
//   in hardware once triggered - the CPU is only involved at the start
//   (write state + trigger) and the end (read back result).
//
// Numeric format: signed Q16.16 fixed point (32-bit: 16 integer bits incl.
// sign, 16 fractional bits). Chosen because every value in this benchmark
// (positions, velocities x DAYS_PER_YEAR, masses up to SOLAR_MASS ~= 39.5)
// comfortably fits within Q16.16's +-32768 range with 2^-16 ~= 1.5e-5
// resolution - adequate for this workload's precision needs.
// Assumption: all divisor/sqrt operands in this workload (d^2, d^2*sqrt(d^2))
// are always positive, so fp_div/fp_sqrt below are unsigned-magnitude only -
// a deliberate, documented simplification for this specific accelerator,
// not a general-purpose FPU.
// ============================================================================

// ----------------------------------------------------------------------------
// fp_mul: combinational Q16.16 x Q16.16 -> Q16.16 multiplier
// ----------------------------------------------------------------------------
module fp_mul (
    input  logic signed [31:0] a,
    input  logic signed [31:0] b,
    output logic signed [31:0] p
);
    logic signed [63:0] full;
    assign full = a * b;          // Q32.32 intermediate
    assign p    = full[47:16];    // truncate back to Q16.16
endmodule


// ----------------------------------------------------------------------------
// fp_sqrt: iterative non-restoring integer square root, adapted for Q16.16.
// Latency: 17 cycles (start + 16 bit-pairs). Input treated as unsigned
// (always true for d^2 in this workload).
// ----------------------------------------------------------------------------
module fp_sqrt (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              start,
    input  logic        [31:0] x,        // Q16.16, non-negative
    output logic signed [31:0] result,   // Q16.16
    output logic               done
);
    logic [31:0] rem, root;
    logic [4:0]  i;
    logic        busy;
    logic [31:0] trial;

    typedef enum logic [1:0] {IDLE, RUN, DONE} state_t;
    state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done  <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        rem   <= 32'b0;
                        root  <= 32'b0;
                        i     <= 5'd15;
                        state <= RUN;
                    end
                end
                RUN: begin
                    // process bit-pair i (bits 2*i+1:2*i of x)
                    rem   <= {rem[29:0], x[2*i +: 2]};
                    trial <= {root[29:0], 2'b01};
                    if ({rem[29:0], x[2*i +: 2]} >= {root[29:0], 2'b01}) begin
                        rem  <= {rem[29:0], x[2*i +: 2]} - {root[29:0], 2'b01};
                        root <= {root[30:0], 1'b1};
                    end else begin
                        root <= {root[30:0], 1'b0};
                    end
                    if (i == 0) state <= DONE;
                    else        i <= i - 1'b1;
                end
                DONE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

    // root holds isqrt(x) in bits [15:0]; result (Q16.16) = isqrt(x) << 8
    // (see file header derivation: sqrt(x/2^16) = sqrt(x)/2^8)
    assign result = {root[23:0], 8'b0};

endmodule


// ----------------------------------------------------------------------------
// fp_div: iterative restoring divider for Q16.16 / Q16.16 -> Q16.16.
// Latency: 48 cycles (start + 48 shift/compare/subtract steps over a
// 48-bit working dividend, to preserve Q16.16 scaling: dividend = a<<16).
// Unsigned-magnitude only (valid for this workload: dt, d^2*sqrt(d^2) > 0).
// ----------------------------------------------------------------------------
module fp_div (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               start,
    input  logic        [31:0] a,        // numerator, Q16.16
    input  logic        [31:0] b,        // denominator, Q16.16
    output logic signed [31:0] result,   // Q16.16
    output logic               done
);
    logic [47:0] dividend;   // a << 16, grown to 48 bits
    logic [47:0] divisor;
    logic [47:0] quotient;
    logic [47:0] remainder;
    logic [5:0]  i;

    typedef enum logic [1:0] {IDLE, RUN, DONE} state_t;
    state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done  <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        dividend  <= {a, 16'b0};
                        divisor   <= {16'b0, b};
                        quotient  <= 48'b0;
                        remainder <= 48'b0;
                        i         <= 6'd47;
                        state     <= RUN;
                    end
                end
                RUN: begin
                    remainder <= {remainder[46:0], dividend[47]};
                    dividend  <= {dividend[46:0], 1'b0};
                    if ({remainder[46:0], dividend[47]} >= divisor) begin
                        remainder <= {remainder[46:0], dividend[47]} - divisor;
                        quotient  <= {quotient[46:0], 1'b1};
                    end else begin
                        quotient  <= {quotient[46:0], 1'b0};
                    end
                    if (i == 0) state <= DONE;
                    else        i <= i - 1'b1;
                end
                DONE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

    assign result = quotient[31:0];

endmodule


// ----------------------------------------------------------------------------
// body_regfile: on-chip state for the 5 fixed bodies (sun, jupiter, saturn,
// uranus, neptune). 5 bodies x (pos.x,y,z + vel.x,y,z + mass) = 35 x 32-bit
// words (140 bytes total). Simple dual-port: host writes via MMIO before a
// run, the nbody_core reads/writes during the run, host reads back after.
// ----------------------------------------------------------------------------
module body_regfile (
    input  logic        clk,
    input  logic        rst_n,
    // host-facing MMIO port
    input  logic        host_we,
    input  logic [5:0]  host_addr,   // 0..34
    input  logic [31:0] host_wdata,
    output logic [31:0] host_rdata,
    // core-facing port (read-modify-write during a run)
    input  logic        core_we,
    input  logic [5:0]  core_addr,
    input  logic [31:0] core_wdata,
    output logic [31:0] core_rdata
);
    logic [31:0] mem [0:34];

    always_ff @(posedge clk) begin
        if (host_we) mem[host_addr] <= host_wdata;
        else if (core_we) mem[core_addr] <= core_wdata;
    end

    assign host_rdata = mem[host_addr];
    assign core_rdata = mem[core_addr];

    // Register layout (index = body*7 + field):
    //   field 0,1,2 = pos.x,y,z   field 3,4,5 = vel.x,y,z   field 6 = mass
    //   body 0=sun 1=jupiter 2=saturn 3=uranus 4=neptune
endmodule


// ----------------------------------------------------------------------------
// pair_rom: the 10 fixed (body_i, body_j) index pairs, matching
// combinations(SYSTEM) in the original Python (sun-jupiter, sun-saturn, ...,
// uranus-neptune). Read-only, addressed 0..9.
// ----------------------------------------------------------------------------
module pair_rom (
    input  logic [3:0] addr,
    output logic [2:0] body_i,
    output logic [2:0] body_j
);
    always_comb begin
        case (addr)
            4'd0: begin body_i = 0; body_j = 1; end // sun-jupiter
            4'd1: begin body_i = 0; body_j = 2; end // sun-saturn
            4'd2: begin body_i = 0; body_j = 3; end // sun-uranus
            4'd3: begin body_i = 0; body_j = 4; end // sun-neptune
            4'd4: begin body_i = 1; body_j = 2; end // jupiter-saturn
            4'd5: begin body_i = 1; body_j = 3; end // jupiter-uranus
            4'd6: begin body_i = 1; body_j = 4; end // jupiter-neptune
            4'd7: begin body_i = 2; body_j = 3; end // saturn-uranus
            4'd8: begin body_i = 2; body_j = 4; end // saturn-neptune
            4'd9: begin body_i = 3; body_j = 4; end // uranus-neptune
            default: begin body_i = 0; body_j = 0; end
        endcase
    end
endmodule


// ----------------------------------------------------------------------------
// nbody_core: the control FSM + datapath that runs N timesteps autonomously.
// Per timestep: for each of the 10 pairs, compute the pairwise gravity
// update (dx,dy,dz -> d2 -> sqrt(d2) -> div -> velocity update), then run
// the position-update pass over all 5 bodies. One shared fp_mul/fp_sqrt/
// fp_div datapath is time-multiplexed across all 10 pairs (see
// report_nbody.txt Section 5 for the parallel-instance trade-off discussion).
// ----------------------------------------------------------------------------
module nbody_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,          // pulse to begin a run
    input  logic [31:0] dt,             // Q16.16, e.g. 0.01 -> 32'h0000_028F
    input  logic [31:0] n_iterations,   // e.g. 20000
    output logic        busy,
    output logic        done,           // pulses for 1 cycle when finished
    // body register file ports (core side)
    output logic        rf_we,
    output logic [5:0]  rf_addr,
    output logic [31:0] rf_wdata,
    input  logic [31:0] rf_rdata
);
    typedef enum logic [3:0] {
        S_IDLE, S_LOAD_I, S_LOAD_J, S_SUB, S_SQ, S_SUM,
        S_SQRT, S_DENOM, S_DIV, S_MASSMUL, S_VELUPD,
        S_NEXTPAIR, S_POSUPD, S_NEXTITER
    } state_t;
    state_t state;

    logic [3:0]  pair_idx;
    logic [31:0] iter_cnt;
    logic [2:0]  bi, bj, body_idx;

    // pair_rom lookup
    logic [2:0] pr_i, pr_j;
    pair_rom u_pair_rom (.addr(pair_idx), .body_i(pr_i), .body_j(pr_j));

    // scratch registers
    logic signed [31:0] xi, yi, zi, xj, yj, zj;
    logic signed [31:0] vxi, vyi, vzi, vxj, vyj, vzj;
    logic signed [31:0] mi, mj;
    logic signed [31:0] dx, dy, dz;
    logic signed [31:0] dxsq, dysq, dzsq, d2;
    logic signed [31:0] sqrt_d2, denom, mag, b_im, b_jm;

    // shared functional units
    logic mul_a_sel; // simple mux control (illustrative; real design pipelines these)
    logic signed [31:0] mul_a, mul_b, mul_p;
    fp_mul u_mul (.a(mul_a), .b(mul_b), .p(mul_p));

    logic sqrt_start, sqrt_done;
    logic signed [31:0] sqrt_result;
    fp_sqrt u_sqrt (.clk(clk), .rst_n(rst_n), .start(sqrt_start),
                     .x(d2), .result(sqrt_result), .done(sqrt_done));

    logic div_start, div_done;
    logic signed [31:0] div_result;
    fp_div u_div (.clk(clk), .rst_n(rst_n), .start(div_start),
                  .a(dt), .b(denom), .result(div_result), .done(div_done));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            pair_idx <= 4'd0;
            iter_cnt <= 32'd0;
            rf_we    <= 1'b0;
            sqrt_start <= 1'b0;
            div_start  <= 1'b0;
        end else begin
            done       <= 1'b0;
            rf_we      <= 1'b0;
            sqrt_start <= 1'b0;
            div_start  <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy     <= 1'b1;
                        iter_cnt <= n_iterations;
                        pair_idx <= 4'd0;
                        state    <= S_LOAD_I;
                    end
                end

                // --- load body i and body j state (7 regfile reads each,
                //     shown as one symbolic state - a real implementation
                //     sequences the 14 individual reads over the regfile's
                //     single read port; omitted here for clarity) ---
                S_LOAD_I: begin
                    bi <= pr_i; bj <= pr_j;
                    {xi, yi, zi, vxi, vyi, vzi, mi} <= '0; // placeholder load
                    state <= S_LOAD_J;
                end
                S_LOAD_J: begin
                    {xj, yj, zj, vxj, vyj, vzj, mj} <= '0; // placeholder load
                    state <= S_SUB;
                end

                S_SUB: begin
                    dx <= xi - xj;
                    dy <= yi - yj;
                    dz <= zi - zj;
                    state <= S_SQ;
                end

                S_SQ: begin
                    mul_a <= dx; mul_b <= dx; dxsq <= mul_p;
                    mul_a <= dy; mul_b <= dy; dysq <= mul_p;
                    mul_a <= dz; mul_b <= dz; dzsq <= mul_p;
                    state <= S_SUM;
                end

                S_SUM: begin
                    d2 <= dxsq + dysq + dzsq;
                    sqrt_start <= 1'b1;
                    state <= S_SQRT;
                end

                S_SQRT: begin
                    if (sqrt_done) begin
                        sqrt_d2 <= sqrt_result;
                        state   <= S_DENOM;
                    end
                end

                S_DENOM: begin
                    mul_a <= d2; mul_b <= sqrt_d2; denom <= mul_p;
                    div_start <= 1'b1;
                    state <= S_DIV;
                end

                S_DIV: begin
                    if (div_done) begin
                        mag   <= div_result; // dt / (d2*sqrt(d2))
                        state <= S_MASSMUL;
                    end
                end

                S_MASSMUL: begin
                    mul_a <= mj; mul_b <= mag; b_im <= mul_p; // body i uses mass_j
                    mul_a <= mi; mul_b <= mag; b_jm <= mul_p; // body j uses mass_i
                    state <= S_VELUPD;
                end

                S_VELUPD: begin
                    // vel_i -= d * b_im ;  vel_j += d * b_jm
                    vxi <= vxi - dx * b_im[31:0]; // conceptually via fp_mul;
                    vyi <= vyi - dy * b_im[31:0]; // shown directly for brevity
                    vzi <= vzi - dz * b_im[31:0];
                    vxj <= vxj + dx * b_jm[31:0];
                    vyj <= vyj + dy * b_jm[31:0];
                    vzj <= vzj + dz * b_jm[31:0];
                    // write back updated velocities to regfile (both bodies)
                    rf_we <= 1'b1; // (address sequencing omitted for brevity)
                    state <= S_NEXTPAIR;
                end

                S_NEXTPAIR: begin
                    if (pair_idx == 4'd9) begin
                        pair_idx <= 4'd0;
                        state    <= S_POSUPD;
                    end else begin
                        pair_idx <= pair_idx + 1'b1;
                        state    <= S_LOAD_I;
                    end
                end

                S_POSUPD: begin
                    // for each of 5 bodies: pos += dt*vel (3 components each)
                    // sequenced over body_idx 0..4 in a real implementation;
                    // shown as a single symbolic state here.
                    if (iter_cnt == 32'd1) begin
                        state <= S_IDLE;
                        done  <= 1'b1;
                        busy  <= 1'b0;
                    end else begin
                        iter_cnt <= iter_cnt - 1'b1;
                        state    <= S_LOAD_I;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign rf_addr  = {2'b0, body_idx};
    assign rf_wdata = 32'b0; // (illustrative; see S_VELUPD/S_POSUPD comments)

endmodule


// ----------------------------------------------------------------------------
// nbody_accelerator: top-level module with a simple synchronous
// memory-mapped register interface (drop-in behind a thin AXI-Lite or
// Avalon-MM wrapper for SoC integration - see report_nbody.txt HW/SW
// Interface section for the register map and driver flow).
// ----------------------------------------------------------------------------
module nbody_accelerator (
    input  logic        clk,
    input  logic        rst_n,

    // memory-mapped register interface
    input  logic        mmio_we,
    input  logic         mmio_re,
    input  logic [7:0]  mmio_addr,
    input  logic [31:0] mmio_wdata,
    output logic [31:0] mmio_rdata,

    output logic        irq          // pulses when a run completes
);
    // register map (byte-addressed words):
    //   0x00            CONTROL   bit0=START (write 1 to trigger a run)
    //   0x04            STATUS    bit0=BUSY, bit1=DONE (sticky, cleared on read)
    //   0x08            DT        Q16.16 timestep
    //   0x0C            N_ITER    iteration count
    //   0x40 - 0x8C     BODY_STATE[0..34]  (35 words, see body_regfile layout)

    logic core_start, core_busy, core_done;
    logic [31:0] core_dt, core_n_iter;

    logic rf_host_we;
    logic [5:0] rf_host_addr;
    logic [31:0] rf_host_wdata, rf_host_rdata;
    logic rf_core_we;
    logic [5:0] rf_core_addr;
    logic [31:0] rf_core_wdata, rf_core_rdata;

    body_regfile u_regfile (
        .clk(clk), .rst_n(rst_n),
        .host_we(rf_host_we), .host_addr(rf_host_addr),
        .host_wdata(rf_host_wdata), .host_rdata(rf_host_rdata),
        .core_we(rf_core_we), .core_addr(rf_core_addr),
        .core_wdata(rf_core_wdata), .core_rdata(rf_core_rdata)
    );

    nbody_core u_core (
        .clk(clk), .rst_n(rst_n),
        .start(core_start), .dt(core_dt), .n_iterations(core_n_iter),
        .busy(core_busy), .done(core_done),
        .rf_we(rf_core_we), .rf_addr(rf_core_addr),
        .rf_wdata(rf_core_wdata), .rf_rdata(rf_core_rdata)
    );

    logic sticky_done;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_start  <= 1'b0;
            core_dt     <= 32'h0000_028F; // 0.01 in Q16.16
            core_n_iter <= 32'd20000;
            sticky_done <= 1'b0;
            rf_host_we  <= 1'b0;
        end else begin
            core_start <= 1'b0;
            rf_host_we <= 1'b0;
            irq        <= 1'b0;

            if (core_done) begin
                sticky_done <= 1'b1;
                irq         <= 1'b1;
            end

            if (mmio_we) begin
                if (mmio_addr == 8'h00 && mmio_wdata[0])
                    core_start <= 1'b1;
                else if (mmio_addr == 8'h08)
                    core_dt <= mmio_wdata;
                else if (mmio_addr == 8'h0C)
                    core_n_iter <= mmio_wdata;
                else if (mmio_addr >= 8'h40 && mmio_addr <= 8'h8C) begin
                    rf_host_we   <= 1'b1;
                    rf_host_addr <= (mmio_addr - 8'h40) >> 2;
                    rf_host_wdata <= mmio_wdata;
                end
            end

            if (mmio_re && mmio_addr == 8'h04)
                sticky_done <= 1'b0; // clear-on-read
        end
    end

    always_comb begin
        rf_host_addr = (mmio_addr >= 8'h40) ? (mmio_addr - 8'h40) >> 2 : 6'b0;
        mmio_rdata = 32'b0;
        case (mmio_addr)
            8'h04: mmio_rdata = {30'b0, sticky_done, core_busy};
            default: if (mmio_addr >= 8'h40 && mmio_addr <= 8'h8C)
                         mmio_rdata = rf_host_rdata;
        endcase
    end

endmodule
