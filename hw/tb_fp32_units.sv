// ============================================================================
// tb_fp32_units.sv — unit testbench for fp_mul, fp_add, fp_sqrt, fp_div
// (float32 versions, hw/nbody_accelerator_fp32.sv).
//
// Expected values were computed in Python using struct.pack('<f', ...) as
// ground truth (see the generation command in the conversation/commit log).
//
// Run:
//   iverilog -g2012 -o sim_fp32 tb_fp32_units.sv nbody_accelerator_fp32.sv
//   vvp sim_fp32
// ============================================================================
`timescale 1ns/1ps

module tb_fp32_units;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    int pass_count = 0;
    int fail_count = 0;

    task automatic check(string name, logic [31:0] got, logic [31:0] expect_);
        if (got === expect_) begin
            $display("PASS  %-28s got=%h expect=%h", name, got, expect_);
            pass_count++;
        end else begin
            $display("FAIL  %-28s got=%h expect=%h", name, got, expect_);
            fail_count++;
        end
    endtask

    // ---------------- fp_mul (combinational) ----------------
    logic [31:0] mul_a, mul_b, mul_p;
    fp_mul u_mul (.a(mul_a), .b(mul_b), .p(mul_p));

    // ---------------- fp_add (combinational) ----------------
    logic [31:0] add_a, add_b, add_s;
    fp_add u_add (.a(add_a), .b(add_b), .s(add_s));

    // ---------------- fp_sqrt (iterative) ----------------
    logic        sqrt_start, sqrt_done;
    logic [31:0] sqrt_x, sqrt_result;
    fp_sqrt u_sqrt (.clk(clk), .rst_n(rst_n), .start(sqrt_start),
                     .x(sqrt_x), .result(sqrt_result), .done(sqrt_done));

    // ---------------- fp_div (iterative) ----------------
    logic        div_start, div_done;
    logic [31:0] div_a, div_b, div_result;
    fp_div u_div (.clk(clk), .rst_n(rst_n), .start(div_start),
                   .a(div_a), .b(div_b), .result(div_result), .done(div_done));

    task automatic run_sqrt(string name, logic [31:0] x, logic [31:0] expect_);
        @(posedge clk);
        sqrt_x = x;
        sqrt_start = 1'b1;
        @(posedge clk);
        sqrt_start = 1'b0;
        wait (sqrt_done === 1'b1);
        @(posedge clk); // let result settle
        check(name, sqrt_result, expect_);
    endtask

    task automatic run_div(string name, logic [31:0] a, logic [31:0] b, logic [31:0] expect_);
        @(posedge clk);
        div_a = a; div_b = b;
        div_start = 1'b1;
        @(posedge clk);
        div_start = 1'b0;
        wait (div_done === 1'b1);
        @(posedge clk);
        check(name, div_result, expect_);
    endtask

    initial begin
        rst_n = 0;
        sqrt_start = 0; div_start = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("\n--- fp_mul (combinational) ---");
        mul_a = 32'h40000000; mul_b = 32'h40400000; #1; check("2.0 * 3.0 = 6.0",     mul_p, 32'h40c00000);
        mul_a = 32'h3fc00000; mul_b = 32'h3fc00000; #1; check("1.5 * 1.5 = 2.25",    mul_p, 32'h40100000);
        mul_a = 32'h3c23d70a; mul_b = 32'h40800000; #1; check("0.01 * 4.0 = 0.04",   mul_p, 32'h3d23d70a);
        mul_a = 32'h421de979; mul_b = 32'h3c23d70a; #1; check("39.478 * 0.01",       mul_p, 32'h3eca209b);

        $display("\n--- fp_add (combinational) ---");
        add_a = 32'h40400000; add_b = 32'h40800000; #1; check("3.0 + 4.0 = 7.0",     add_s, 32'h40e00000);
        add_a = 32'h40a00000; add_b = 32'h40000000; #1; check("5.0 + 2.0 = 7.0",     add_s, 32'h40e00000);
        add_a = 32'h3fc00000; add_b = 32'h40300000; #1; check("1.5 + 2.75 = 4.25",   add_s, 32'h40880000);
        add_a = 32'h41200000; add_b = 32'hc0400000; #1; check("10.0 + (-3.0) = 7.0", add_s, 32'h40e00000);

        $display("\n--- fp_sqrt (iterative, 25 cycles) ---");
        // deliberately mixes odd- and even-parity biased exponents (129,131,125 = odd; 128,126,130 = even)
        run_sqrt("sqrt(4.0)=2.0 [exp odd]",   32'h40800000, 32'h40000000);
        run_sqrt("sqrt(2.0)=1.41... [even]",  32'h40000000, 32'h3fb504f3);
        run_sqrt("sqrt(16.0)=4.0 [odd]",      32'h41800000, 32'h40800000);
        run_sqrt("sqrt(0.25)=0.5 [odd]",      32'h3e800000, 32'h3f000000);
        run_sqrt("sqrt(0.5)=0.707... [even]", 32'h3f000000, 32'h3f3504f3);
        run_sqrt("sqrt(9.0)=3.0 [even]",      32'h41100000, 32'h40400000);

        $display("\n--- fp_div (iterative, 26 cycles) ---");
        run_div("6.0 / 2.0 = 3.0",            32'h40c00000, 32'h40000000, 32'h40400000);
        run_div("1.0 / 3.0 = 0.333...",       32'h3f800000, 32'h40400000, 32'h3eaaaaab);
        run_div("0.01 / 27000.0",             32'h3c23d70a, 32'h46d2f000, 32'h34c6d751);

        $display("\n=== RESULTS: %0d passed, %0d failed ===\n", pass_count, fail_count);
        if (fail_count > 0) $fatal(1, "TESTBENCH FAILED");
        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT — a wait() never completed");
        $fatal(1, "timeout");
    end
endmodule
