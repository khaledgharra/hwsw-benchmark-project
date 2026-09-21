// ============================================================================
// nbody_accelerator.sv  —  IEEE-754 float64 version
//
// Changed from Q16.16 fixed-point to IEEE-754 double precision (float64):
//   - fp_mul : combinational 64-bit multiply (still zero latency)
//   - fp_sqrt: iterative float64 sqrt, 54 cycles
//   - fp_div : iterative float64 divide, 55 cycles
//   - body_regfile: 35 × 64-bit words (280 bytes on-chip)
//   - nbody_core: all scratch registers widened to [63:0]
//   - nbody_accelerator: mmio_wdata/rdata widened to [63:0],
//     mmio_addr widened to [8:0] to cover the larger BODY_STATE range
//
// Everything structural (FSM states/transitions, pair_rom, MMIO register
// map layout, START/DONE/IRQ logic) is identical to the Q16.16 version.
//
// Numeric simplification (same as Q16.16 version): fp_sqrt and fp_div
// assume non-negative / positive-only operands (always true for d^2 and
// d^2*sqrt(d^2) in this workload) and do not handle NaN, Inf, or denormals.
// All inputs are normal, finite, positive float64 values.
//
// Register map (8-byte aligned, 64-bit bus):
//   0x000  CONTROL   bit0=START
//   0x008  STATUS    bit0=BUSY, bit1=DONE (sticky, clear-on-read)
//   0x010  DT        float64 timestep (default 0.01 = 0x3F847AE147AE147B)
//   0x018  N_ITER    iteration count (32-bit value in 64-bit register)
//   0x040-0x150  BODY_STATE[0..34]  35 × float64 words
// ============================================================================


// ----------------------------------------------------------------------------
// fp_mul: combinational IEEE-754 float64 multiply.
// Handles normalized positive and negative numbers. No NaN/Inf/denormal.
// Latency: 0 cycles (purely combinational).
// ----------------------------------------------------------------------------
module fp_mul (
    input  logic [63:0] a,
    input  logic [63:0] b,
    output logic [63:0] p
);
    logic        sa, sb, sp;
    logic [10:0] ea, eb;
    logic [52:0] ma, mb;
    logic [105:0] mp;
    logic [11:0]  ep_wide;
    logic [10:0]  ep;
    logic [51:0]  mr;

    assign sa = a[63];
    assign sb = b[63];
    assign ea = a[62:52];
    assign eb = b[62:52];
    assign ma = {1'b1, a[51:0]};   // restore implicit leading 1
    assign mb = {1'b1, b[51:0]};

    assign mp = ma * mb;            // 53×53 → 106-bit product (Q1.52 × Q1.52 = Q2.104)
    assign sp = sa ^ sb;

    // mp[105]=1 means mantissa product ≥ 2.0 → right-shift, add 1 to exponent
    assign ep_wide = mp[105] ? ({1'b0, ea} + {1'b0, eb} - 12'd1022)
                              : ({1'b0, ea} + {1'b0, eb} - 12'd1023);
    assign ep = ep_wide[10:0];
    assign mr = mp[105] ? mp[104:53] : mp[103:52];

    assign p = {sp, ep, mr};
endmodule


// ----------------------------------------------------------------------------
// fp_sqrt: iterative IEEE-754 float64 square root.
// Uses non-restoring binary digit-recurrence sqrt on a 106-bit radicand,
// producing a 53-bit integer result (bit 52 = implicit leading 1).
//
// Radicand construction (M = {1'b1, x[51:0]}, the 53-bit significand):
//   e odd  (e_unbiased even): radicand = {1'b0, M, 52'b0}  → M × 2^52
//                              res_exp = (e + 1023) / 2
//   e even (e_unbiased odd):  radicand = {M, 53'b0}         → M × 2^53
//                              res_exp = (e + 1022) / 2
// In both cases radicand is 106 bits in [2^104, 2^106) and the
// isqrt result is 53 bits with root[52]=1.
//
// Latency: 54 cycles (1 setup + 53 bit-pair iterations).
// ----------------------------------------------------------------------------
module fp_sqrt (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [63:0] x,         // IEEE-754 float64, non-negative
    output logic [63:0] result,    // IEEE-754 float64
    output logic        done
);
    logic [10:0]  res_exp;
    logic [105:0] radicand;
    logic [105:0] rem, root;
    logic [6:0]   i;               // counts 52 down to 0 (53 iterations)

    typedef enum logic [1:0] {IDLE, RUN, DONE_S} state_t;
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
                        if (x[62]) begin  // exponent is odd → e_unbiased is even
                            radicand <= {1'b0, 1'b1, x[51:0], 52'b0};   // M × 2^52
                            res_exp  <= (x[62:52] + 11'd1023) >> 1;
                        end else begin    // exponent is even → e_unbiased is odd
                            radicand <= {1'b1, x[51:0], 53'b0};          // M × 2^53
                            res_exp  <= (x[62:52] + 11'd1022) >> 1;
                        end
                        rem   <= 106'b0;
                        root  <= 106'b0;
                        i     <= 7'd52;
                        state <= RUN;
                    end
                end

                RUN: begin
                    if ({rem[103:0], radicand[2*i +: 2]} >= {root[103:0], 2'b01}) begin
                        rem  <= {rem[103:0], radicand[2*i +: 2]} - {root[103:0], 2'b01};
                        root <= {root[104:0], 1'b1};
                    end else begin
                        rem  <= {rem[103:0], radicand[2*i +: 2]};
                        root <= {root[104:0], 1'b0};
                    end
                    if (i == 7'd0) state <= DONE_S;
                    else           i <= i - 7'd1;
                end

                DONE_S: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

    // root[52:0] holds the 53-bit isqrt result after 53 iterations.
    // root[52] is the implicit leading 1; root[51:0] are the 52 mantissa bits.
    assign result = {1'b0, res_exp, root[51:0]};

endmodule


// ----------------------------------------------------------------------------
// fp_div: iterative IEEE-754 float64 divide (a / b).
// Uses restoring long division on 54-bit mantissa quotient.
//
// Mantissa setup:
//   dividend = Ma × 2^53  (106-bit: {Ma, 53'b0}, Ma = {1'b1, a[51:0]})
//   divisor  = Mb          (53-bit, zero-extended to 107 bits for comparison)
//   54 iterations → 54-bit quotient Q
//
// Normalization:
//   Q[53]=1 (Ma ≥ Mb): result_exp = ea - eb + 1023, mantissa = Q[52:1]
//   Q[53]=0 (Ma < Mb): result_exp = ea - eb + 1022, mantissa = Q[51:0]
//
// Latency: 55 cycles (1 setup + 54 iterations).
// ----------------------------------------------------------------------------
module fp_div (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [63:0] a,         // numerator, IEEE-754 float64
    input  logic [63:0] b,         // denominator, IEEE-754 float64
    output logic [63:0] result,    // IEEE-754 float64
    output logic        done
);
    logic        sr;
    logic [10:0] ea, eb;
    logic [52:0] Ma, Mb;

    logic [105:0] dividend;
    logic [106:0] remainder;
    logic [53:0]  quotient;
    logic [5:0]   i;          // counts 53 down to 0 (54 iterations)

    // stored for result assembly
    logic [10:0] exp_base;

    // combinational partial-remainder and divisor wires (used in RUN state)
    wire [106:0] partial_rem = {remainder[105:0], dividend[105]};
    wire [106:0] div_cmp     = {54'b0, Mb};

    typedef enum logic [1:0] {IDLE, RUN, DONE_D} state_t;
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
                        sr        <= a[63] ^ b[63];
                        ea        <= a[62:52];
                        eb        <= b[62:52];
                        Ma        <= {1'b1, a[51:0]};
                        Mb        <= {1'b1, b[51:0]};
                        dividend  <= {{1'b1, a[51:0]}, 53'b0};  // Ma × 2^53
                        exp_base  <= a[62:52] - b[62:52] + 11'd1023;
                        remainder <= 107'b0;
                        quotient  <= 54'b0;
                        i         <= 6'd53;
                        state     <= RUN;
                    end
                end

                RUN: begin
                    dividend <= {dividend[104:0], 1'b0};
                    if (partial_rem >= div_cmp) begin
                        remainder <= partial_rem - div_cmp;
                        quotient  <= {quotient[52:0], 1'b1};
                    end else begin
                        remainder <= partial_rem;
                        quotient  <= {quotient[52:0], 1'b0};
                    end
                    if (i == 6'd0) state <= DONE_D;
                    else           i <= i - 6'd1;
                end

                DONE_D: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

    // Assemble result: normalize based on whether Ma >= Mb
    wire [10:0] res_exp  = quotient[53] ? exp_base        : exp_base - 11'd1;
    wire [51:0] res_mant = quotient[53] ? quotient[52:1]  : quotient[51:0];
    assign result = {sr, res_exp, res_mant};

endmodule


// ----------------------------------------------------------------------------
// fp_add: combinational IEEE-754 float64 add/subtract.
// Handles normalized non-zero inputs. No NaN/Inf/denormal handling.
// Latency: 0 cycles (combinational).
// ----------------------------------------------------------------------------
module fp_add (
    input  logic [63:0] a, b,
    output logic [63:0] s
);
    wire        sa = a[63], sb = b[63];
    wire [10:0] ea = a[62:52], eb = b[62:52];
    wire [52:0] Ma = {1'b1, a[51:0]}, Mb = {1'b1, b[51:0]};

    // Sort so M_big has the operand with larger magnitude
    wire mag_swap  = (eb > ea) || ((eb == ea) && (Mb > Ma));
    wire [10:0] e_big = mag_swap ? eb : ea;
    wire [10:0] e_sml = mag_swap ? ea : eb;
    wire [52:0] M_big = mag_swap ? Mb : Ma;
    wire [52:0] M_sml = mag_swap ? Ma : Mb;
    wire        s_big = mag_swap ? sb : sa;
    wire        s_sml = mag_swap ? sa : sb;

    // Align smaller operand: shift right by (e_big - e_sml)
    wire [10:0] shamt  = e_big - e_sml;
    wire [53:0] A_ext  = {1'b0, M_big};
    wire [53:0] B_ext  = (shamt >= 11'd54) ? 54'b0 : ({1'b0, M_sml} >> shamt);

    // Effective add or subtract
    wire do_add = (s_big == s_sml);
    wire [54:0] raw = do_add ? ({1'b0, A_ext} + {1'b0, B_ext})
                              : ({1'b0, A_ext} - {1'b0, B_ext});

    // Count leading zeros in raw[52:0] (from bit 52 downward) for normalization
    // lz=0 means bit 52 is already the leading 1 (no shift needed)
    logic [5:0]  lz;
    logic [52:0] normed;
    logic [51:0] res_mant;
    logic [10:0] res_exp;

    always_comb begin
        lz = 6'd52;
        for (int k = 52; k >= 0; k--)
            if (raw[k]) lz = 6'(52 - k);

        normed   = raw[52:0] << lz;
        res_mant = 52'b0;
        res_exp  = 11'b0;

        if (raw[53:0] == 54'b0) begin
            res_exp  = 11'b0;
            res_mant = 52'b0;
        end else if (raw[53]) begin
            // Carry bit set: result = 1x.xxx → shift right 1, inc exp
            res_exp  = e_big + 11'd1;
            res_mant = raw[52:1];
        end else begin
            // Normalize using leading-zero shift
            res_exp  = (e_big >= {5'b0, lz}) ? (e_big - {5'b0, lz}) : 11'b0;
            res_mant = normed[51:0];
        end
    end

    assign s = {s_big, res_exp, res_mant};
endmodule


// ----------------------------------------------------------------------------
// body_regfile: on-chip state, now 35 × 64-bit words (280 bytes).
// Layout unchanged: index = body*7 + field, fields 0-2=pos, 3-5=vel, 6=mass.
// ----------------------------------------------------------------------------
module body_regfile (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        host_we,
    input  logic [5:0]  host_addr,
    input  logic [63:0] host_wdata,
    output logic [63:0] host_rdata,
    input  logic        core_we,
    input  logic [5:0]  core_addr,
    input  logic [63:0] core_wdata,
    output logic [63:0] core_rdata
);
    logic [63:0] mem [0:34];

    always_ff @(posedge clk) begin
        if      (host_we) mem[host_addr] <= host_wdata;
        else if (core_we) mem[core_addr] <= core_wdata;
    end

    assign host_rdata = mem[host_addr];
    assign core_rdata = mem[core_addr];
endmodule


// ----------------------------------------------------------------------------
// pair_rom: unchanged — 10 fixed body-pair indices, purely combinational.
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
// nbody_core: FSM and datapath — IEEE-754 float64.
//
// Register file layout (body b occupies words b*7 .. b*7+6):
//   +0=x, +1=y, +2=z, +3=vx, +4=vy, +5=vz, +6=mass
//
// Key timing rule: fp_mul and fp_add are combinational. mul_a/mul_b are
// registered (driven by always_ff with <=), so mul_p reflects the values
// set in the PREVIOUS clock cycle. fadd_a/fadd_b are driven by always_comb
// so fadd_s is valid within the same clock cycle.
//
// fadd_s_reg is a pipeline register (fadd_s delayed 1 cycle); used in
// S_POSUPD where fadd inputs are set in cycle N and result captured in N+1.
//
// FSM overview (per iteration):
//   For each of 10 pairs (pair_idx 0-9):
//     S_LOAD_I / S_LOAD_J : 7 reads each, sub counter 0-6
//     S_SUB                : dx/dy/dz via fp_add
//     S_SQ_X/Y/Z, S_SUM   : d² = dx²+dy²+dz²
//     S_SQRT               : sqrt(d²), 54 cycles
//     S_DENOM/WAIT         : d² × sqrt(d²)
//     S_DIV                : dt / denom, 55 cycles  → mag
//     S_MASSMUL_I/J/WAIT   : b_im = mj*mag, b_jm = mi*mag
//     S_VELUPD             : update 6 velocity scratch regs (sub 0-5)
//     S_WB_I / S_WB_J      : write vxi/vyi/vzi and vxj/vyj/vzj back (sub 0-2 each)
//   S_NEXTPAIR             : advance pair or move to position update
//   For each of 5 bodies (body_idx 0-4):
//     S_POSUPD             : read vx/vy/vz, compute dt*v, add to x/y/z, write back
//                            uses pos_step counter (0-11)
// ----------------------------------------------------------------------------
module nbody_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [63:0] dt,
    input  logic [31:0] n_iterations,
    output logic        busy,
    output logic        done,
    output logic        rf_we,
    output logic [5:0]  rf_addr,
    output logic [63:0] rf_wdata,
    input  logic [63:0] rf_rdata
);
    typedef enum logic [4:0] {
        S_IDLE,
        S_LOAD_I, S_LOAD_J,
        S_SUB,
        S_SQ_X, S_SQ_Y, S_SQ_Z,
        S_SUM_1, S_SUM_2,
        S_SQRT_LAUNCH, S_SQRT_WAIT,
        S_DENOM, S_DENOM_WAIT,
        S_DIV_LAUNCH, S_DIV_WAIT,
        S_MASSMUL_I, S_MASSMUL_J, S_MASSMUL_WAIT,
        S_VELUPD,
        S_WB_I, S_WB_J,
        S_NEXTPAIR,
        S_POSUPD
    } state_t;
    state_t state;

    logic [3:0]  pair_idx;
    logic [31:0] iter_cnt;
    logic [2:0]  bi, bj, body_idx;
    logic [2:0]  sub;      // multi-use: load 0-6, sub 0-2, velupd 0-5, wb 0-2
    logic [3:0]  pos_step; // position update sub-step 0-9

    logic [2:0] pr_i, pr_j;
    pair_rom u_pair_rom (.addr(pair_idx), .body_i(pr_i), .body_j(pr_j));

    // scratch registers (all float64)
    logic [63:0] xi, yi, zi, xj, yj, zj;
    logic [63:0] vxi, vyi, vzi, vxj, vyj, vzj;
    logic [63:0] mi, mj;
    logic [63:0] dx, dy, dz;
    logic [63:0] dxsq, dysq, dzsq, sum1, d2;
    logic [63:0] sqrt_d2, denom, mag, b_im, b_jm;
    logic [63:0] dtVx, dtVy, dtVz;
    logic [63:0] px, py, pz;
    logic [63:0] x_new, y_new, z_new;

    // fp_add: fadd_a/b driven by always_comb; fadd_s is combinational.
    // fadd_s_reg is a 1-cycle pipeline register for fadd_s (used in S_POSUPD).
    logic [63:0] fadd_a, fadd_b, fadd_s, fadd_s_reg;
    fp_add u_add (.a(fadd_a), .b(fadd_b), .s(fadd_s));
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) fadd_s_reg <= '0;
        else        fadd_s_reg <= fadd_s;

    // fp_mul: inputs registered (set this cycle, result valid next cycle)
    logic [63:0] mul_a, mul_b, mul_p;
    fp_mul u_mul (.a(mul_a), .b(mul_b), .p(mul_p));

    logic        sqrt_start, sqrt_done;
    logic [63:0] sqrt_result;
    fp_sqrt u_sqrt (.clk(clk), .rst_n(rst_n), .start(sqrt_start),
                    .x(d2), .result(sqrt_result), .done(sqrt_done));

    logic        div_start, div_done;
    logic [63:0] div_result;
    fp_div u_div (.clk(clk), .rst_n(rst_n), .start(div_start),
                  .a(dt), .b(denom), .result(div_result), .done(div_done));

    // -----------------------------------------------------------------------
    // Combinational: rf_addr, rf_wdata, fadd_a, fadd_b
    // body_regfile has combinational reads (assign core_rdata = mem[core_addr]),
    // so rf_rdata is valid the same cycle rf_addr is presented.
    // S_LOAD_I/J use pr_i/pr_j directly (pair_rom comb output) to avoid
    // the 1-cycle lag that would occur if bi/bj (registered) were used.
    // -----------------------------------------------------------------------
    always_comb begin
        rf_addr  = 6'b0;
        rf_wdata = 64'b0;
        fadd_a   = 64'b0;
        fadd_b   = 64'b0;

        case (state)
            S_LOAD_I: rf_addr = 6'(pr_i) * 6'd7 + {3'b0, sub};
            S_LOAD_J: rf_addr = 6'(pr_j) * 6'd7 + {3'b0, sub};

            S_SUB: case (sub)
                3'd0: begin fadd_a=xi; fadd_b={~xj[63],xj[62:0]}; end  // xi-xj
                3'd1: begin fadd_a=yi; fadd_b={~yj[63],yj[62:0]}; end  // yi-yj
                3'd2: begin fadd_a=zi; fadd_b={~zj[63],zj[62:0]}; end  // zi-zj
                default: ;
            endcase

            S_SUM_1: begin fadd_a=dxsq; fadd_b=dysq; end
            S_SUM_2: begin fadd_a=sum1; fadd_b=dzsq; end

            S_VELUPD: case (sub)
                3'd0: begin fadd_a=vxi; fadd_b={~mul_p[63],mul_p[62:0]}; end
                3'd1: begin fadd_a=vyi; fadd_b={~mul_p[63],mul_p[62:0]}; end
                3'd2: begin fadd_a=vzi; fadd_b={~mul_p[63],mul_p[62:0]}; end
                3'd3: begin fadd_a=vxj; fadd_b=mul_p; end
                3'd4: begin fadd_a=vyj; fadd_b=mul_p; end
                3'd5: begin fadd_a=vzj; fadd_b=mul_p; end
                default: ;
            endcase

            S_WB_I: begin
                rf_addr  = 6'(bi) * 6'd7 + 6'd3 + {3'b0, sub};
                rf_wdata = (sub==3'd0) ? vxi : (sub==3'd1) ? vyi : vzi;
            end
            S_WB_J: begin
                rf_addr  = 6'(bj) * 6'd7 + 6'd3 + {3'b0, sub};
                rf_wdata = (sub==3'd0) ? vxj : (sub==3'd1) ? vyj : vzj;
            end

            // Position update uses fadd_s_reg (1-cycle delay pipeline):
            //   pos_step=4: set fadd inputs → fadd_s_reg has result at pos_step=5
            //   pos_step=5: set fadd inputs → fadd_s_reg has result at pos_step=6
            //   pos_step=6: set fadd inputs → fadd_s_reg has result at pos_step=7
            S_POSUPD: case (pos_step)
                4'd0: rf_addr = 6'(body_idx)*6'd7 + 6'd3;  // vx
                4'd1: rf_addr = 6'(body_idx)*6'd7 + 6'd4;  // vy
                4'd2: rf_addr = 6'(body_idx)*6'd7 + 6'd5;  // vz
                4'd3: rf_addr = 6'(body_idx)*6'd7 + 6'd0;  // x
                4'd4: begin rf_addr=6'(body_idx)*6'd7+6'd1; fadd_a=px;  fadd_b=dtVx; end // y; px+dtVx
                4'd5: begin rf_addr=6'(body_idx)*6'd7+6'd2; fadd_a=py;  fadd_b=dtVy; end // z; py+dtVy
                4'd6: begin                                  fadd_a=pz;  fadd_b=dtVz; end //    pz+dtVz
                4'd7: begin rf_addr=6'(body_idx)*6'd7+6'd0; rf_wdata=x_new; end  // write x
                4'd8: begin rf_addr=6'(body_idx)*6'd7+6'd1; rf_wdata=y_new; end  // write y
                4'd9: begin rf_addr=6'(body_idx)*6'd7+6'd2; rf_wdata=z_new; end  // write z
                default: ;
            endcase

            default: ;
        endcase
    end

    // -----------------------------------------------------------------------
    // Sequential FSM
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE; busy <= '0; done <= '0;
            pair_idx   <= '0; iter_cnt <= '0;
            body_idx   <= '0; bi <= '0; bj <= '0;
            sub        <= '0; pos_step <= '0;
            rf_we      <= '0; sqrt_start <= '0; div_start <= '0;
        end else begin
            done <= '0; rf_we <= '0; sqrt_start <= '0; div_start <= '0;

            case (state)
                S_IDLE: begin
                    busy <= '0;
                    if (start) begin
                        busy <= 1'b1; iter_cnt <= n_iterations;
                        pair_idx <= '0; sub <= '0; state <= S_LOAD_I;
                    end
                end

                // Read 7 fields of body i (pr_i drives rf_addr in always_comb)
                S_LOAD_I: begin
                    if (sub == 3'd0) begin bi <= pr_i; bj <= pr_j; end
                    case (sub)
                        3'd0: xi  <= rf_rdata;
                        3'd1: yi  <= rf_rdata;
                        3'd2: zi  <= rf_rdata;
                        3'd3: vxi <= rf_rdata;
                        3'd4: vyi <= rf_rdata;
                        3'd5: vzi <= rf_rdata;
                        3'd6: begin mi <= rf_rdata; sub <= '0; state <= S_LOAD_J; end
                    endcase
                    if (sub != 3'd6) sub <= sub + 3'd1;
                end

                // Read 7 fields of body j
                S_LOAD_J: begin
                    case (sub)
                        3'd0: xj  <= rf_rdata;
                        3'd1: yj  <= rf_rdata;
                        3'd2: zj  <= rf_rdata;
                        3'd3: vxj <= rf_rdata;
                        3'd4: vyj <= rf_rdata;
                        3'd5: vzj <= rf_rdata;
                        3'd6: begin mj <= rf_rdata; sub <= '0; state <= S_SUB; end
                    endcase
                    if (sub != 3'd6) sub <= sub + 3'd1;
                end

                // dx/dy/dz via fp_add (3 cycles: sub 0,1,2 → dx,dy,dz)
                // fadd_a/b driven by always_comb per sub value
                S_SUB: begin
                    case (sub)
                        3'd0: begin dx <= fadd_s; sub <= 3'd1; end
                        3'd1: begin dy <= fadd_s; sub <= 3'd2; end
                        3'd2: begin dz <= fadd_s; sub <= '0; state <= S_SQ_X; end
                    endcase
                end

                // d² = dx²+dy²+dz² using pipelined fp_mul (1-cycle latency)
                S_SQ_X: begin mul_a<=dx;   mul_b<=dx;  state<=S_SQ_Y; end
                S_SQ_Y: begin dxsq<=mul_p; mul_a<=dy;  mul_b<=dy; state<=S_SQ_Z; end
                S_SQ_Z: begin dysq<=mul_p; mul_a<=dz;  mul_b<=dz; state<=S_SUM_1; end

                // SUM_1: save dzsq=mul_p; compute dxsq+dysq via fadd (comb)
                S_SUM_1: begin dzsq<=mul_p; sum1<=fadd_s; state<=S_SUM_2; end
                // SUM_2: d2 = sum1+dzsq via fadd (comb)
                S_SUM_2: begin d2<=fadd_s; state<=S_SQRT_LAUNCH; end
                // Launch sqrt one cycle AFTER d2 register is updated
                S_SQRT_LAUNCH: begin sqrt_start<=1'b1; state<=S_SQRT_WAIT; end
                S_SQRT_WAIT:   if (sqrt_done) begin sqrt_d2<=sqrt_result; state<=S_DENOM; end

                S_DENOM:      begin mul_a<=d2;   mul_b<=sqrt_d2; state<=S_DENOM_WAIT; end
                S_DENOM_WAIT: begin denom<=mul_p; state<=S_DIV_LAUNCH; end
                // Launch div one cycle AFTER denom register is updated
                S_DIV_LAUNCH: begin div_start<=1'b1; state<=S_DIV_WAIT; end
                S_DIV_WAIT:   if (div_done) begin mag<=div_result; state<=S_MASSMUL_I; end

                S_MASSMUL_I: begin mul_a<=mj; mul_b<=mag; state<=S_MASSMUL_J; end
                S_MASSMUL_J: begin b_im<=mul_p; mul_a<=mi; mul_b<=mag; state<=S_MASSMUL_WAIT; end
                S_MASSMUL_WAIT: begin
                    b_jm  <= mul_p;
                    mul_a <= dx; mul_b <= b_im;  // prime mul for velupd sub=0 (dx*b_im)
                    sub   <= '0; state <= S_VELUPD;
                end

                // Velocity update (6 sub-steps).
                // always_comb provides fadd_a/b; fadd_s = new velocity, captured here.
                // New mul_a/b primed each step for the next sub-step's product.
                S_VELUPD: begin
                    case (sub)
                        3'd0: begin vxi<=fadd_s; mul_a<=dy;  mul_b<=b_im; sub<=3'd1; end
                        3'd1: begin vyi<=fadd_s; mul_a<=dz;  mul_b<=b_im; sub<=3'd2; end
                        3'd2: begin vzi<=fadd_s; mul_a<=dx;  mul_b<=b_jm; sub<=3'd3; end
                        3'd3: begin vxj<=fadd_s; mul_a<=dy;  mul_b<=b_jm; sub<=3'd4; end
                        3'd4: begin vyj<=fadd_s; mul_a<=dz;  mul_b<=b_jm; sub<=3'd5; end
                        3'd5: begin vzj<=fadd_s; sub<='0; state<=S_WB_I; end
                    endcase
                end

                // Write back updated velocities to register file (3 writes each)
                S_WB_I: begin
                    rf_we <= 1'b1;
                    if (sub==3'd2) begin sub<='0; state<=S_WB_J; end
                    else           sub<=sub+3'd1;
                end
                S_WB_J: begin
                    rf_we <= 1'b1;
                    if (sub==3'd2) begin sub<='0; state<=S_NEXTPAIR; end
                    else           sub<=sub+3'd1;
                end

                S_NEXTPAIR: begin
                    if (pair_idx==4'd9) begin
                        pair_idx<='0; body_idx<='0; pos_step<='0; state<=S_POSUPD;
                    end else begin
                        pair_idx<=pair_idx+4'd1; sub<='0; state<=S_LOAD_I;
                    end
                end

                // Position update per body (10 sub-steps, body_idx 0-4).
                //
                // Timing of fadd pipeline (always_comb sets inputs, fadd_s_reg
                // captures result 1 cycle later):
                //   step 4: comb fadd=px+dtVx  → fadd_s_reg ready at step 5
                //   step 5: comb fadd=py+dtVy  → fadd_s_reg ready at step 6
                //   step 6: comb fadd=pz+dtVz  → fadd_s_reg ready at step 7
                //   step 7: capture z (fadd_s_reg=px+dtVx) → x_new ... wait below
                //
                // Precise capture sequence:
                //   step 5 seq: x_new = fadd_s_reg (= px+dtVx from step 4) ✓
                //   step 6 seq: y_new = fadd_s_reg (= py+dtVy from step 5) ✓
                //   step 7 seq: z_new = fadd_s_reg (= pz+dtVz from step 6) ✓
                //   steps 7-9: write x_new/y_new/z_new to rf
                S_POSUPD: begin
                    case (pos_step)
                        4'd0: begin mul_a<=dt; mul_b<=rf_rdata; pos_step<=4'd1; end
                        4'd1: begin dtVx<=mul_p; mul_a<=dt; mul_b<=rf_rdata; pos_step<=4'd2; end
                        4'd2: begin dtVy<=mul_p; mul_a<=dt; mul_b<=rf_rdata; pos_step<=4'd3; end
                        4'd3: begin dtVz<=mul_p; px<=rf_rdata; pos_step<=4'd4; end
                        4'd4: begin py<=rf_rdata; pos_step<=4'd5; end       // comb: fadd=px+dtVx
                        4'd5: begin pz<=rf_rdata; x_new<=fadd_s_reg; pos_step<=4'd6; end // comb: fadd=py+dtVy
                        4'd6: begin              y_new<=fadd_s_reg; pos_step<=4'd7; end  // comb: fadd=pz+dtVz
                        4'd7: begin z_new<=fadd_s_reg; rf_we<=1'b1; pos_step<=4'd8; end // write x_new
                        4'd8: begin rf_we<=1'b1; pos_step<=4'd9; end                    // write y_new
                        4'd9: begin                                                       // write z_new
                            rf_we <= 1'b1;
                            pos_step <= '0;
                            if (body_idx==3'd4) begin
                                body_idx <= '0;
                                if (iter_cnt==32'd1) begin
                                    done<=1'b1; busy<=1'b0; state<=S_IDLE;
                                end else begin
                                    iter_cnt<=iter_cnt-32'd1; pair_idx<='0; sub<='0;
                                    state<=S_LOAD_I;
                                end
                            end else body_idx<=body_idx+3'd1;
                        end
                    endcase
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule


// ----------------------------------------------------------------------------
// nbody_accelerator: top-level MMIO wrapper.
// mmio_wdata/rdata widened to 64 bits; mmio_addr widened to 9 bits.
// Register map: 0x000=CONTROL, 0x008=STATUS, 0x010=DT, 0x018=N_ITER,
//               0x040-0x150=BODY_STATE[0..34] (35 × 8 bytes).
// ----------------------------------------------------------------------------
module nbody_accelerator (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        mmio_we,
    input  logic        mmio_re,
    input  logic [8:0]  mmio_addr,    // 9-bit to cover 0x000-0x1FF
    input  logic [63:0] mmio_wdata,
    output logic [63:0] mmio_rdata,

    output logic        irq
);
    logic core_start, core_busy, core_done;
    logic [63:0] core_dt;
    logic [31:0] core_n_iter;

    logic        rf_host_we;
    logic [5:0]  rf_host_addr;
    logic [63:0] rf_host_wdata, rf_host_rdata;
    logic        rf_core_we;
    logic [5:0]  rf_core_addr;
    logic [63:0] rf_core_wdata, rf_core_rdata;

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
            core_start    <= 1'b0;
            core_dt       <= 64'h3F847AE147AE147B; // 0.01 in IEEE-754 float64
            core_n_iter   <= 32'd20000;
            sticky_done   <= 1'b0;
            rf_host_we    <= 1'b0;
            rf_host_wdata <= 64'b0;
            irq           <= 1'b0;
        end else begin
            core_start <= 1'b0;
            rf_host_we <= 1'b0;
            irq        <= 1'b0;

            if (core_done) begin
                sticky_done <= 1'b1;
                irq         <= 1'b1;
            end

            if (mmio_we) begin
                case (mmio_addr)
                    9'h000: if (mmio_wdata[0]) core_start <= 1'b1;
                    9'h010: core_dt     <= mmio_wdata;
                    9'h018: core_n_iter <= mmio_wdata[31:0];
                    default: begin
                        // BODY_STATE: 0x040 to 0x150, 8-byte stride
                        if (mmio_addr >= 9'h040 && mmio_addr <= 9'h150) begin
                            rf_host_we    <= 1'b1;
                            rf_host_wdata <= mmio_wdata;
                        end
                    end
                endcase
            end

            if (mmio_re && mmio_addr == 9'h008)
                sticky_done <= 1'b0;
        end
    end

    always_comb begin
        rf_host_addr = (mmio_addr >= 9'h040) ? (mmio_addr - 9'h040) >> 3 : 6'b0;
        mmio_rdata   = 64'b0;
        if (mmio_addr == 9'h008)
            mmio_rdata = {62'b0, sticky_done, core_busy};
        else if (mmio_addr >= 9'h040 && mmio_addr <= 9'h150)
            mmio_rdata = rf_host_rdata;
    end

endmodule
