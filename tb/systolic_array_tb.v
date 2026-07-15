//-----------------------------------------------------------------------------
// Testbench: systolic_array_tb
// Description: Directed self-checking testbench for systolic_array.v (Phase 2).
//              Covers three tests:
//              1. Identity weight matrix (C == A)
//              2. All-ones weight matrix
//              3. Ramp weight matrix (W[k][j] = k + j)
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps

module systolic_array_tb;

    parameter N          = 8;
    parameter DATA_WIDTH = 8;
    parameter ACC_WIDTH  = 32;

    reg                         clk;
    reg                         rst_n;
    reg  [N-1:0]                row_clk_en;
    reg  [N-1:0]                col_clk_en;
    reg                         weight_load_en;
    reg  [$clog2(N)-1:0]        weight_load_row;
    reg  [N*DATA_WIDTH-1:0]     weight_load_data;
    reg  [N*DATA_WIDTH-1:0]     act_in;
    reg                         act_valid;
    wire [N*ACC_WIDTH-1:0]      result_out;
    wire                        result_valid;

    // Score keeping
    integer pass_count;
    integer fail_count;

    // 2D Array structures for testbench bookkeeping
    reg signed [DATA_WIDTH-1:0] A[0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] W[0:N-1][0:N-1];
    reg signed [ACC_WIDTH-1:0]  C_captured[0:N-1][0:N-1];
    reg signed [ACC_WIDTH-1:0]  C_expected[0:N-1][0:N-1];

    // DUT Instantiation
    systolic_array #(
        .N          (N),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .row_clk_en       (row_clk_en),
        .col_clk_en       (col_clk_en),
        .weight_load_en   (weight_load_en),
        .weight_load_row  (weight_load_row),
        .weight_load_data (weight_load_data),
        .act_in           (act_in),
        .act_valid        (act_valid),
        .result_out       (result_out),
        .result_valid     (result_valid)
    );

    // Clock generation (100 MHz, 10ns period)
    initial clk = 0;
    always #5 clk = ~clk;

    // Self-checking task
    task check_result;
        input [80*8-1:0] test_name;
        integer i, j;
        begin
            for (i = 0; i < N; i = i + 1) begin
                for (j = 0; j < N; j = j + 1) begin
                    if (C_captured[i][j] === C_expected[i][j]) begin
                        pass_count = pass_count + 1;
                    end else begin
                        $display("[FAIL] %0s : C[%0d][%0d] expected %0d, got %0d", 
                                 test_name, i, j, C_expected[i][j], C_captured[i][j]);
                        fail_count = fail_count + 1;
                    end
                end
            end
        end
    endtask

    // Helper task to clear testbench capture buffers
    task clear_capture_buffers;
        integer i, j;
        begin
            for (i = 0; i < N; i = i + 1) begin
                for (j = 0; j < N; j = j + 1) begin
                    C_captured[i][j] = 0;
                end
            end
        end
    endtask

    // Helper task to preload weights into the systolic array row-by-row
    task preload_weights;
        integer r, c;
        reg [N*DATA_WIDTH-1:0] packed_row;
        begin
            $display("Loading weight matrix into array...");
            for (r = 0; r < N; r = r + 1) begin
                packed_row = 0;
                for (c = 0; c < N; c = c + 1) begin
                    packed_row[c*DATA_WIDTH +: DATA_WIDTH] = W[r][c];
                end
                weight_load_en   = 1;
                weight_load_row  = r;
                weight_load_data = packed_row;
                @(posedge clk); #1;
            end
            weight_load_en   = 0;
            weight_load_row  = 0;
            weight_load_data = 0;
            @(posedge clk); #1;
        end
    endtask

    // Helper task to feed activation matrix with systolic skew and capture results dynamically
    task run_matrix_multiply;
        integer t, k, c, i;
        reg [N*DATA_WIDTH-1:0] packed_act;
        begin
            $display("Running matrix multiplication...");
            // Initialize outputs to 0
            act_in    = 0;
            act_valid = 0;
            @(posedge clk); #1;

            // We loop for 25 cycles (15 cycles to feed all skewed activations, plus 10 cycles for draining)
            for (t = 0; t < 25; t = t + 1) begin
                // 1. Apply inputs for cycle t
                packed_act = 0;
                // act_valid is high during the feeding phase (cycles 0 to 14)
                act_valid = (t < 15) ? 1 : 0;

                for (k = 0; k < N; k = k + 1) begin
                    i = t - k; // row index in activation matrix A
                    if (i >= 0 && i < N) begin
                        packed_act[k*DATA_WIDTH +: DATA_WIDTH] = A[i][k];
                    end else begin
                        packed_act[k*DATA_WIDTH +: DATA_WIDTH] = 0;
                    end
                end
                act_in = packed_act;

                // 2. Capture outputs on this clock cycle (non-blocking evaluation after edge)
                // Result C[i][c] exits column c at cycle t_exit = i + c + 8.
                // Hence, i = t - 8 - c.
                for (c = 0; c < N; c = c + 1) begin
                    i = t - 8 - c;
                    if (i >= 0 && i < N) begin
                        C_captured[i][c] = result_out[c*ACC_WIDTH +: ACC_WIDTH];
                    end
                end

                @(posedge clk); #1;
            end
            act_in    = 0;
            act_valid = 0;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        $display("================================================");
        $display("  Systolic Array Testbench  (Phase 2b)");
        $display("================================================");

        pass_count = 0;
        fail_count = 0;

        // Enable all PEs (no clock gating for these tests)
        row_clk_en = 8'hFF;
        col_clk_en = 8'hFF;

        weight_load_en   = 0;
        weight_load_row  = 0;
        weight_load_data = 0;
        act_in           = 0;
        act_valid        = 0;

        // Reset the system
        rst_n = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;

        // Initialize activation matrix A
        // A[i][k] = (i+1)*10 + (k+1)
        begin : init_A
            integer i, k;
            for (i = 0; i < N; i = i + 1) begin
                for (k = 0; k < N; k = k + 1) begin
                    A[i][k] = (i + 1) * 10 + (k + 1);
                end
            end
        end

        // =============================================================
        // TEST 1: Identity Weight Matrix (C == A)
        // =============================================================
        $display("\n--- TEST 1: Identity Weight Matrix ---");
        clear_capture_buffers;
        // W = Identity Matrix
        begin : init_W_identity
            integer r, c;
            for (r = 0; r < N; r = r + 1) begin
                for (c = 0; c < N; c = c + 1) begin
                    W[r][c] = (r == c) ? 1 : 0;
                    C_expected[r][c] = A[r][c];
                end
            end
        end

        preload_weights;
        run_matrix_multiply;
        check_result("TEST 1 (Identity)");

        // =============================================================
        // TEST 2: All Ones Weight Matrix (C[i][c] = Sum(A[i]))
        // =============================================================
        $display("\n--- TEST 2: All Ones Weight Matrix ---");
        clear_capture_buffers;
        // W = All 1s
        begin : init_W_ones
            integer r, c;
            for (r = 0; r < N; r = r + 1) begin
                for (c = 0; c < N; c = c + 1) begin
                    W[r][c] = 1;
                    // Row sums: Row 0=116, 1=196, 2=276, 3=356, 4=436, 5=516, 6=596, 7=676
                    C_expected[r][c] = 80*(r+1) + 36;
                end
            end
        end

        // Do a software reset before next test to clear internal PE registers
        rst_n = 0; @(posedge clk); #1; rst_n = 1; @(posedge clk); #1;

        preload_weights;
        run_matrix_multiply;
        check_result("TEST 2 (All-ones)");

        // =============================================================
        // TEST 3: Ramp Weight Matrix (W[k][j] = k + j)
        // =============================================================
        $display("\n--- TEST 3: Ramp Weight Matrix ---");
        clear_capture_buffers;
        begin : init_W_ramp
            integer r, c;
            for (r = 0; r < N; r = r + 1) begin
                for (c = 0; c < N; c = c + 1) begin
                    W[r][c] = r + c;
                end
            end
            
            // Expected results generated from NumPy helper
            C_expected[0][0] = 448;  C_expected[0][1] = 564;  C_expected[0][2] = 680;  C_expected[0][3] = 796;  C_expected[0][4] = 912;  C_expected[0][5] = 1028; C_expected[0][6] = 1144; C_expected[0][7] = 1260;
            C_expected[1][0] = 728;  C_expected[1][1] = 924;  C_expected[1][2] = 1120; C_expected[1][3] = 1316; C_expected[1][4] = 1512; C_expected[1][5] = 1708; C_expected[1][6] = 1904; C_expected[1][7] = 2100;
            C_expected[2][0] = 1008; C_expected[2][1] = 1284; C_expected[2][2] = 1560; C_expected[2][3] = 1836; C_expected[2][4] = 2112; C_expected[2][5] = 2388; C_expected[2][6] = 2664; C_expected[2][7] = 2940;
            C_expected[3][0] = 1288; C_expected[3][1] = 1644; C_expected[3][2] = 2000; C_expected[3][3] = 2356; C_expected[3][4] = 2712; C_expected[3][5] = 3068; C_expected[3][6] = 3424; C_expected[3][7] = 3780;
            C_expected[4][0] = 1568; C_expected[4][1] = 2004; C_expected[4][2] = 2440; C_expected[4][3] = 2876; C_expected[4][4] = 3312; C_expected[4][5] = 3748; C_expected[4][6] = 4184; C_expected[4][7] = 4620;
            C_expected[5][0] = 1848; C_expected[5][1] = 2364; C_expected[5][2] = 2880; C_expected[5][3] = 3396; C_expected[5][4] = 3912; C_expected[5][5] = 4428; C_expected[5][6] = 4944; C_expected[5][7] = 5460;
            C_expected[6][0] = 2128; C_expected[6][1] = 2724; C_expected[6][2] = 3320; C_expected[6][3] = 3916; C_expected[6][4] = 4512; C_expected[6][5] = 5108; C_expected[6][6] = 5704; C_expected[6][7] = 6300;
            C_expected[7][0] = 2408; C_expected[7][1] = 3084; C_expected[7][2] = 3760; C_expected[7][3] = 4436; C_expected[7][4] = 5112; C_expected[7][5] = 5788; C_expected[7][6] = 6464; C_expected[7][7] = 7140;
        end

        // Do a software reset before next test to clear internal PE registers
        rst_n = 0; @(posedge clk); #1; rst_n = 1; @(posedge clk); #1;

        preload_weights;
        run_matrix_multiply;
        check_result("TEST 3 (Ramp)");

        // =============================================================
        // Summary
        // =============================================================
        $display("\n================================================");
        $display("  Results: %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) begin
            $display("  >>> ALL TESTS PASSED <<<");
        end else begin
            $display("  >>> SOME TESTS FAILED <<<");
        end
        $display("================================================\n");
        $finish;
    end

endmodule
