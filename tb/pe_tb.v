//-----------------------------------------------------------------------------
// Testbench: pe_tb
// Description: Directed self-checking testbench for pe.v (Phase 1).
//              Covers: basic MAC, multi-cycle accumulation, weight stability,
//              acc_clear, saturation (upper & lower), signed multiply
//              combinations, global reset, and activation pass-through.
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps

module pe_tb;

    // ------------------------------------------------------------------ params
    parameter DATA_WIDTH = 8;
    parameter ACC_WIDTH  = 32;

    // ----------------------------------------------------------- DUT signals
    reg                           clk;
    reg                           rst_n;
    reg                           clk_en;
    reg                           weight_load;
    reg  signed [DATA_WIDTH-1:0]  weight_in;
    reg                           acc_clear;
    reg  signed [DATA_WIDTH-1:0]  act_in;
    reg  signed [ACC_WIDTH-1:0]   psum_in;
    wire signed [DATA_WIDTH-1:0]  act_out;
    wire signed [ACC_WIDTH-1:0]   psum_out;
    wire signed [ACC_WIDTH-1:0]   result_raw;
    wire signed [DATA_WIDTH-1:0]  result_sat;

    // --------------------------------------------------------- score keeping
    integer pass_count;
    integer fail_count;

    // ------------------------------------------------------------------- DUT
    pe #(
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .clk_en      (clk_en),
        .weight_load (weight_load),
        .weight_in   (weight_in),
        .acc_clear   (acc_clear),
        .act_in      (act_in),
        .psum_in     (psum_in),
        .act_out     (act_out),
        .psum_out    (psum_out),
        .result_raw  (result_raw),
        .result_sat  (result_sat)
    );

    // ----------------------------------------------------------------- clock
    initial clk = 0;
    always #5 clk = ~clk;          // 100 MHz, 10 ns period

    // ============================================================ check tasks

    // 32-bit signed compare
    task check;
        input [80*8-1:0] name;
        input signed [31:0] expected;
        input signed [31:0] actual;
        integer e, a;
        begin
            e = expected;  a = actual;              // integer → signed display
            if (expected === actual) begin
                $display("[PASS] %0s : expected %0d, got %0d", name, e, a);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s : expected %0d, got %0d", name, e, a);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // 8-bit signed compare
    task check8;
        input [80*8-1:0] name;
        input signed [7:0] expected;
        input signed [7:0] actual;
        integer e, a;
        begin
            e = expected;  a = actual;
            if (expected === actual) begin
                $display("[PASS] %0s : expected %0d, got %0d", name, e, a);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s : expected %0d, got %0d", name, e, a);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ========================================================= helper tasks

    task load_weight;
        input signed [DATA_WIDTH-1:0] w;
        begin
            weight_load = 1;
            weight_in   = w;
            @(posedge clk); #1;
            weight_load = 0;
            weight_in   = 0;
        end
    endtask

    task clear_acc;
        begin
            acc_clear = 1;
            @(posedge clk); #1;
            acc_clear = 0;
        end
    endtask

    task apply_act;                        // apply for exactly 1 clock cycle
        input signed [DATA_WIDTH-1:0] a;
        begin
            act_in = a;
            @(posedge clk); #1;
        end
    endtask

    // ========================================================= main sequence
    initial begin
        $display("================================================");
        $display("  PE Directed Testbench  (Phase 1)");
        $display("================================================");

        pass_count = 0;
        fail_count = 0;

        // Default quiescent inputs
        clk_en      = 1;
        weight_load = 0;
        weight_in   = 0;
        acc_clear   = 0;
        act_in      = 0;
        psum_in     = 0;

        // ---- Global reset (2 cycles) ----
        rst_n = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;

        // =============================================================
        // T1  Basic MAC — single cycle
        // =============================================================
        $display("\n--- T1: Basic MAC — single cycle ---");
        clear_acc;
        load_weight(5);                     // weight = 5
        apply_act(3);                       // acc = 0 + 5×3 = 15
        check ("T1 result_raw = 15", 15, result_raw);
        check8("T1 result_sat = 15", 15, result_sat);

        // =============================================================
        // T2  Multi-cycle accumulation
        // =============================================================
        $display("\n--- T2: Multi-cycle accumulation ---");
        clear_acc;                          // weight still 5
        apply_act(7);                       // acc = 35
        check("T2 after act=7: raw = 35",  35, result_raw);
        apply_act(3);                       // acc = 50
        check("T2 after act=3: raw = 50",  50, result_raw);
        apply_act(2);                       // acc = 60
        check("T2 after act=2: raw = 60",  60, result_raw);

        // =============================================================
        // T3  Weight latch stability
        // =============================================================
        $display("\n--- T3: Weight latch stability ---");
        clear_acc;
        load_weight(10);                    // weight = 10
        apply_act(5);                       // acc = 50
        check("T3 acc = 10*5 = 50",        50, result_raw);
        apply_act(3);                       // acc = 80  (weight_load=0)
        check("T3 acc += 10*3 = 80",       80, result_raw);
        // Drive weight_in=99 WITHOUT asserting weight_load
        weight_in = 99;
        apply_act(2);                       // acc = 100 (weight still 10)
        check("T3 weight stable (in=99 ignored): raw = 100", 100, result_raw);
        weight_in = 0;

        // =============================================================
        // T4  Accumulator clear does NOT affect latched weight
        // =============================================================
        $display("\n--- T4: Acc clear preserves weight ---");
        clear_acc;                          // weight still 10
        check("T4 acc cleared to 0",       0,  result_raw);
        apply_act(6);                       // acc = 10×6 = 60
        check("T4 weight preserved: 10*6 = 60", 60, result_raw);

        // =============================================================
        // T5  Saturation — upper bound
        // =============================================================
        $display("\n--- T5: Saturation upper bound ---");
        clear_acc;
        load_weight(127);                   // max positive INT8
        apply_act(1);                       // acc = 127  (at boundary)
        check ("T5 raw at boundary = 127",    127, result_raw);
        check8("T5 sat at boundary = 127",    127, result_sat);
        apply_act(1);                       // acc = 254  (above)
        check ("T5 raw above = 254",         254, result_raw);
        check8("T5 sat clamped = 127",        127, result_sat);
        apply_act(1);                       // acc = 381  (far above)
        check ("T5 raw far above = 381",      381, result_raw);
        check8("T5 sat still clamped = 127",  127, result_sat);

        // =============================================================
        // T6  Saturation — lower bound
        // =============================================================
        $display("\n--- T6: Saturation lower bound ---");
        clear_acc;
        load_weight(-128);                  // min negative INT8
        apply_act(1);                       // acc = -128  (at boundary)
        check ("T6 raw at boundary = -128",      -128, result_raw);
        check8("T6 sat at boundary = -128",      -128, result_sat);
        apply_act(1);                       // acc = -256  (below)
        check ("T6 raw below = -256",            -256, result_raw);
        check8("T6 sat clamped = -128",          -128, result_sat);
        apply_act(1);                       // acc = -384  (far below)
        check ("T6 raw far below = -384",        -384, result_raw);
        check8("T6 sat still clamped = -128",    -128, result_sat);

        // =============================================================
        // T7  Negative × Negative  (two directed cases)
        // =============================================================
        $display("\n--- T7: Negative * Negative ---");
        // 7a: (-5) × (-3) = +15
        clear_acc;
        load_weight(-5);
        apply_act(-3);
        check("T7a (-5)*(-3) = 15",              15, result_raw);

        // 7b: (-128) × (-1) = +128  (also triggers positive saturation)
        clear_acc;
        load_weight(-128);
        apply_act(-1);
        check ("T7b (-128)*(-1) raw = 128",      128, result_raw);
        check8("T7b (-128)*(-1) sat = 127",      127, result_sat);

        // =============================================================
        // T8  Negative × Positive  (two directed cases)
        // =============================================================
        $display("\n--- T8: Negative * Positive ---");
        // 8a: (-7) × 4 = -28
        clear_acc;
        load_weight(-7);
        apply_act(4);
        check("T8a (-7)*4 = -28",                -28, result_raw);

        // 8b: 50 × (-2) = -100
        clear_acc;
        load_weight(50);
        apply_act(-2);
        check("T8b 50*(-2) = -100",              -100, result_raw);

        // =============================================================
        // T9  Global active-low reset clears weight AND accumulator
        // =============================================================
        $display("\n--- T9: Global reset ---");
        // Build up non-zero state
        clear_acc;
        load_weight(42);
        apply_act(10);                      // acc = 420
        check("T9 pre-reset: raw = 420",         420, result_raw);

        // Assert reset
        rst_n = 0;
        @(posedge clk); #1;
        check ("T9 reset: raw = 0",              0,   result_raw);
        check8("T9 reset: sat = 0",              0,   result_sat);

        // Release reset — state stays cleared
        rst_n = 1;
        @(posedge clk); #1;
        check("T9 post-reset: raw still 0",      0,   result_raw);

        // Confirm weight was also cleared: 0 × 10 = 0
        apply_act(10);
        check("T9 weight cleared: 0*10 = 0",     0,   result_raw);
        act_in = 0;

        // =============================================================
        // T10 Activation pass-through (act_out = act_in delayed 1 cycle)
        // =============================================================
        $display("\n--- T10: Activation pass-through ---");
        act_in = 42;
        @(posedge clk); #1;
        check8("T10 act_out = 42",               42,  act_out);
        act_in = -100;
        @(posedge clk); #1;
        check8("T10 act_out = -100",             -100, act_out);
        act_in = 0;

        // =============================================================
        // Summary
        // =============================================================
        $display("\n================================================");
        $display("  Results: %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0)
            $display("  >>> ALL TESTS PASSED <<<");
        else
            $display("  >>> SOME TESTS FAILED <<<");
        $display("================================================\n");
        $finish;
    end

endmodule
