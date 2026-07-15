//-----------------------------------------------------------------------------
// Testbench: pe_psum_tb
// Description: Extended/new tests for Phase 2 PE spatial partial-sum and
//              activation propagation.
//              Covers:
//              - psum passthrough (weight = 0, psum_out == psum_in)
//              - single PE partial sum (psum_out == psum_in + weight * act_in)
//              - chained psum (2 PEs cascaded top-to-bottom)
//              - act_out delay (confirming 1-cycle delay)
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps

module pe_psum_tb;

    parameter DATA_WIDTH = 8;
    parameter ACC_WIDTH  = 32;

    reg clk;
    reg rst_n;
    reg clk_en;

    // -------------------------------------------------- Signals for PE0
    reg                          pe0_weight_load;
    reg  signed [DATA_WIDTH-1:0] pe0_weight_in;
    reg                          pe0_acc_clear;
    reg  signed [DATA_WIDTH-1:0] pe0_act_in;
    reg  signed [ACC_WIDTH-1:0]  pe0_psum_in;
    wire signed [DATA_WIDTH-1:0] pe0_act_out;
    wire signed [ACC_WIDTH-1:0]  pe0_psum_out;
    wire signed [ACC_WIDTH-1:0]  pe0_result_raw;
    wire signed [DATA_WIDTH-1:0] pe0_result_sat;

    // -------------------------------------------------- Signals for PE1
    reg                          pe1_weight_load;
    reg  signed [DATA_WIDTH-1:0] pe1_weight_in;
    reg                          pe1_acc_clear;
    wire signed [DATA_WIDTH-1:0] pe1_act_out;
    wire signed [ACC_WIDTH-1:0]  pe1_psum_out;
    wire signed [ACC_WIDTH-1:0]  pe1_result_raw;
    wire signed [DATA_WIDTH-1:0] pe1_result_sat;

    // -------------------------------------------------- Score keeping
    integer pass_count;
    integer fail_count;

    // -------------------------------------------------- Instantiate PE0
    pe #(
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) pe0 (
        .clk         (clk),
        .rst_n       (rst_n),
        .clk_en      (clk_en),
        .weight_load (pe0_weight_load),
        .weight_in   (pe0_weight_in),
        .acc_clear   (pe0_acc_clear),
        .act_in      (pe0_act_in),
        .psum_in     (pe0_psum_in),
        .act_out     (pe0_act_out),
        .psum_out    (pe0_psum_out),
        .result_raw  (pe0_result_raw),
        .result_sat  (pe0_result_sat)
    );

    // -------------------------------------------------- Instantiate PE1 (Cascaded below PE0)
    // Connect pe0.psum_out -> pe1.psum_in
    // Connect pe0.act_out -> pe1.act_in (to test horizontal + vertical propagation together)
    pe #(
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) pe1 (
        .clk         (clk),
        .rst_n       (rst_n),
        .clk_en      (clk_en),
        .weight_load (pe1_weight_load),
        .weight_in   (pe1_weight_in),
        .acc_clear   (pe1_acc_clear),
        .act_in      (pe0_act_out),         // Chained activation
        .psum_in     (pe0_psum_out),        // Chained partial sum
        .act_out     (pe1_act_out),
        .psum_out    (pe1_psum_out),
        .result_raw  (pe1_result_raw),
        .result_sat  (pe1_result_sat)
    );

    // Clock generator
    initial clk = 0;
    always #5 clk = ~clk;

    // Self-checking tasks
    task check;
        input [80*8-1:0] name;
        input signed [ACC_WIDTH-1:0] expected;
        input signed [ACC_WIDTH-1:0] actual;
        begin
            if (expected === actual) begin
                $display("[PASS] %0s : expected %0d, got %0d", name, expected, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s : expected %0d, got %0d", name, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check8;
        input [80*8-1:0] name;
        input signed [DATA_WIDTH-1:0] expected;
        input signed [DATA_WIDTH-1:0] actual;
        begin
            if (expected === actual) begin
                $display("[PASS] %0s : expected %0d, got %0d", name, expected, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s : expected %0d, got %0d", name, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $display("================================================");
        $display("  PE Spatial & psum Testbench  (Phase 2a)");
        $display("================================================");

        pass_count = 0;
        fail_count = 0;

        // Default state
        clk_en          = 1;
        pe0_weight_load = 0;
        pe0_weight_in   = 0;
        pe0_acc_clear   = 0;
        pe0_act_in      = 0;
        pe0_psum_in     = 0;

        pe1_weight_load = 0;
        pe1_weight_in   = 0;
        pe1_acc_clear   = 0;

        // Reset
        rst_n = 0;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;

        // =============================================================
        // Test 1: psum passthrough (weight = 0)
        // =============================================================
        $display("\n--- Test 1: psum passthrough (weight=0) ---");
        // Load weight=0 in PE0
        pe0_weight_load = 1;
        pe0_weight_in   = 0;
        @(posedge clk); #1;
        pe0_weight_load = 0;

        pe0_psum_in = 32'h1234_5678;
        pe0_act_in  = 8'sd42; // product is 0 * 42 = 0
        @(posedge clk); #1; // psum_out is registered
        check("PE0 psum_out with weight=0 matches psum_in", 32'h1234_5678, pe0_psum_out);

        // =============================================================
        // Test 2: single PE partial sum (weight=5, act=10, psum_in=100)
        // =============================================================
        $display("\n--- Test 2: single PE partial sum (non-zero) ---");
        // Load weight=5 in PE0
        pe0_weight_load = 1;
        pe0_weight_in   = 5;
        @(posedge clk); #1;
        pe0_weight_load = 0;

        pe0_psum_in = 100;
        pe0_act_in  = 10;
        @(posedge clk); #1; // compute: psum_out <= 100 + 5 * 10 = 150
        check("PE0 psum_out == psum_in + weight * act_in", 150, pe0_psum_out);

        // =============================================================
        // Test 3: act_out delay (confirm 1 clock cycle delay)
        // =============================================================
        $display("\n--- Test 3: act_out delay ---");
        pe0_act_in = 8'sd77;
        @(posedge clk); #1;
        check8("pe0_act_out matches act_in delayed 1 cycle", 8'sd77, pe0_act_out);

        pe0_act_in = -8'sd88;
        @(posedge clk); #1;
        check8("pe0_act_out matches act_in delayed 1 cycle (case 2)", -8'sd88, pe0_act_out);

        // =============================================================
        // Test 4: Chained psum
        // =============================================================
        $display("\n--- Test 4: Chained PEs (PE0 -> PE1) ---");
        // We have two PEs.
        // PE0 weight = 3
        // PE1 weight = -4
        // Inputs at Cycle 0:
        //   pe0_psum_in = 10
        //   pe0_act_in  = 6
        //   pe1_act_in  = pe0_act_out (will be 0 at cycle 0)
        //   pe1_psum_in = pe0_psum_out (will be 0 at cycle 0)
        
        // 1. Load weights
        pe0_weight_load = 1; pe0_weight_in = 3;
        pe1_weight_load = 1; pe1_weight_in = -4;
        @(posedge clk); #1;
        pe0_weight_load = 0; pe1_weight_load = 0;

        // Apply inputs and clear states
        pe0_psum_in = 10;
        pe0_act_in  = 6;
        @(posedge clk); #1;
        // Cycle 1:
        // pe0_psum_out should now be registered: psum_in(10) + weight(3)*act_in(6) = 28.
        // pe0_act_out should now be: 6.
        // This is presented to PE1 inputs this cycle.
        check("PE0 psum_out at cycle 1 is 28", 28, pe0_psum_out);
        check8("PE0 act_out at cycle 1 is 6", 6, pe0_act_out);

        // Keep feeding PE0 so PE1 sees stable inputs
        pe0_psum_in = 0;
        pe0_act_in  = 0;
        @(posedge clk); #1;
        // Cycle 2:
        // PE1 psum_out should now be: pe1_psum_in(28) + pe1_weight(-4) * pe1_act_in(6) = 28 - 24 = 4.
        check("PE1 psum_out at cycle 2 is 4", 4, pe1_psum_out);

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
