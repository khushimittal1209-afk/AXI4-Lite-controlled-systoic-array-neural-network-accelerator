//-----------------------------------------------------------------------------
// Testbench: accelerator_top_tb
// Description: Full integration testbench for accelerator_top.v (Phase 5).
//              Preloads weights and activations via AXI, triggers compute,
//              polls for DONE, and reads/verifies result matrices.
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps

module accelerator_top_tb;

    parameter ADDR_WIDTH = 10;
    parameter DATA_WIDTH = 32;
    parameter N          = 8;

    reg clk;
    reg rst_n;

    // AXI signals
    wire [ADDR_WIDTH-1:0]       axi_awaddr;
    wire                        axi_awvalid;
    wire                        axi_awready;
    wire [DATA_WIDTH-1:0]       axi_wdata;
    wire [(DATA_WIDTH/8)-1:0]   axi_wstrb;
    wire                        axi_wvalid;
    wire                        axi_wready;
    wire [1:0]                  axi_bresp;
    wire                        axi_bvalid;
    wire                        axi_bready;
    wire [ADDR_WIDTH-1:0]       axi_araddr;
    wire                        axi_arvalid;
    wire                        axi_arready;
    wire [DATA_WIDTH-1:0]       axi_rdata;
    wire [1:0]                  axi_rresp;
    wire                        axi_rvalid;
    wire                        axi_rready;

    // DUT Instantiation
    accelerator_top #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .N          (N)
    ) dut (
        .aclk          (clk),
        .aresetn       (rst_n),
        .s_axi_awaddr  (axi_awaddr),
        .s_axi_awvalid (axi_awvalid),
        .s_axi_awready (axi_awready),
        .s_axi_wdata   (axi_wdata),
        .s_axi_wstrb   (axi_wstrb),
        .s_axi_wvalid  (axi_wvalid),
        .s_axi_wready  (axi_wready),
        .s_axi_bresp   (axi_bresp),
        .s_axi_bvalid  (axi_bvalid),
        .s_axi_bready  (axi_bready),
        .s_axi_araddr  (axi_araddr),
        .s_axi_arvalid (axi_arvalid),
        .s_axi_arready (axi_arready),
        .s_axi_rdata   (axi_rdata),
        .s_axi_rresp   (axi_rresp),
        .s_axi_rvalid  (axi_rvalid),
        .s_axi_rready  (axi_rready)
    );

    // BFM Instantiation
    axi_lite_master_bfm #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) bfm (
        .aclk          (clk),
        .aresetn       (rst_n),
        .m_axi_awaddr  (axi_awaddr),
        .m_axi_awvalid (axi_awvalid),
        .m_axi_awready (axi_awready),
        .m_axi_wdata   (axi_wdata),
        .m_axi_wstrb   (axi_wstrb),
        .m_axi_wvalid  (axi_wvalid),
        .m_axi_wready  (axi_wready),
        .m_axi_bresp   (axi_bresp),
        .m_axi_bvalid  (axi_bvalid),
        .m_axi_bready  (axi_bready),
        .m_axi_araddr  (axi_araddr),
        .m_axi_arvalid (axi_arvalid),
        .m_axi_arready (axi_arready),
        .m_axi_rdata   (axi_rdata),
        .m_axi_rresp   (axi_rresp),
        .m_axi_rvalid  (axi_rvalid),
        .m_axi_rready  (axi_rready)
    );

    // Clock generation (100 MHz, 10ns period)
    initial clk = 0;
    always #5 clk = ~clk;

    // Score keeping
    integer pass_count;
    integer fail_count;

    task check;
        input [80*8-1:0] name;
        input [31:0] expected;
        input [31:0] actual;
        begin
            if (expected === actual) begin
                $display("[PASS] %0s : expected 0x%h, got 0x%h", name, expected, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s : expected 0x%h, got 0x%h", name, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Module level temp response
    reg [1:0] temp_resp;

    // Matrices
    reg signed [7:0] A[0:7][0:7];
    reg signed [7:0] W[0:7][0:7];
    reg signed [31:0] C_expected[0:7][0:7];

    task load_weight_matrix_to_dut;
        integer i, r, c;
        reg [DATA_WIDTH-1:0] word_data;
        reg [1:0] resp;
        begin
            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 8; c = c + 4) begin
                    word_data = {W[r][c+3], W[r][c+2], W[r][c+1], W[r][c]};
                    // WEIGHT_DATA address: 0x000 + 4 * (r * 2 + c / 4)
                    bfm.axi_write(10'h000 + 4 * (r * 2 + c / 4), word_data, resp);
                end
            end
        end
    endtask

    task load_act_matrix_to_dut;
        integer i, r, c;
        reg [DATA_WIDTH-1:0] word_data;
        reg [1:0] resp;
        begin
            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 8; c = c + 4) begin
                    word_data = {A[r][c+3], A[r][c+2], A[r][c+1], A[r][c]};
                    // ACT_DATA address: 0x040 + 4 * (r * 2 + c / 4)
                    bfm.axi_write(10'h040 + 4 * (r * 2 + c / 4), word_data, resp);
                end
            end
        end
    endtask

    task run_gemm_and_verify;
        input [80*8-1:0] test_name;
        reg [DATA_WIDTH-1:0] temp_data;
        reg [1:0]            t_resp;
        reg [80*8-1:0]       str_name;
        integer k;
        begin
            // 1. Enable PEs in CLK_GATE_CTRL (0x088)
            bfm.axi_write(10'h088, 32'h0000_FFFF, t_resp);

            // 2. Write START=1 (0x080)
            bfm.axi_write(10'h080, 32'h0000_0001, t_resp);

            // 3. Poll STATUS until DONE=1 (0x084)
            temp_data = 0;
            while (temp_data[1] == 1'b0) begin
                bfm.axi_read(10'h084, temp_data, t_resp);
                #10;
            end

            // 4. Read back and verify RESULT_RAW
            for (k = 0; k < 64; k = k + 1) begin
                bfm.axi_read(10'h100 + 4 * k, temp_data, t_resp);
                $sformat(str_name, "%s RAW[%2d]", test_name, k);
                check(str_name, C_expected[k/8][k%8], temp_data);
            end
        end
    endtask

    // Watchdog
    initial begin
        #100000;
        $display("[TIMEOUT] Watchdog expired");
        $finish;
    end

    initial begin
        $display("================================================");
        $display("  Full Integration Testbench  (Phase 5)");
        $display("================================================");

        pass_count = 0;
        fail_count = 0;

        // Reset
        rst_n = 0;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;

        // Initialize activation matrix A
        // A[i][k] = (i+1)*10 + (k+1)
        begin : init_A
            integer i, k;
            for (i = 0; i < 8; i = i + 1) begin
                for (k = 0; k < 8; k = k + 1) begin
                    A[i][k] = (i + 1) * 10 + (k + 1);
                end
            end
        end

        // =============================================================
        // TEST 1: Identity Weight Matrix
        // =============================================================
        $display("\n--- TEST 1: Identity Weight Matrix ---");
        begin : init_W_identity
            integer r, c;
            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 8; c = c + 1) begin
                    W[r][c] = (r == c) ? 1 : 0;
                    C_expected[r][c] = A[r][c];
                end
            end
        end
        load_weight_matrix_to_dut;
        load_act_matrix_to_dut;
        run_gemm_and_verify("Identity");

        // =============================================================
        // TEST 2: All Ones Weight Matrix
        // =============================================================
        $display("\n--- TEST 2: All Ones Weight Matrix ---");
        begin : init_W_ones
            integer r, c;
            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 8; c = c + 1) begin
                    W[r][c] = 1;
                    C_expected[r][c] = 80*(r+1) + 36;
                end
            end
        end
        // Soft reset before test
        bfm.axi_write(10'h080, 32'h0000_0002, temp_resp);
        #20;
        load_weight_matrix_to_dut;
        load_act_matrix_to_dut;
        run_gemm_and_verify("All-ones");

        // =============================================================
        // TEST 3: Ramp Weight Matrix
        // =============================================================
        $display("\n--- TEST 3: Ramp Weight Matrix ---");
        begin : init_W_ramp
            integer r, c;
            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 8; c = c + 1) begin
                    W[r][c] = r + c;
                end
            end
            C_expected[0][0] = 448;  C_expected[0][1] = 564;  C_expected[0][2] = 680;  C_expected[0][3] = 796;  C_expected[0][4] = 912;  C_expected[0][5] = 1028; C_expected[0][6] = 1144; C_expected[0][7] = 1260;
            C_expected[1][0] = 728;  C_expected[1][1] = 924;  C_expected[1][2] = 1120; C_expected[1][3] = 1316; C_expected[1][4] = 1512; C_expected[1][5] = 1708; C_expected[1][6] = 1904; C_expected[1][7] = 2100;
            C_expected[2][0] = 1008; C_expected[2][1] = 1284; C_expected[2][2] = 1560; C_expected[2][3] = 1836; C_expected[2][4] = 2112; C_expected[2][5] = 2388; C_expected[2][6] = 2664; C_expected[2][7] = 2940;
            C_expected[3][0] = 1288; C_expected[3][1] = 1644; C_expected[3][2] = 2000; C_expected[3][3] = 2356; C_expected[3][4] = 2712; C_expected[3][5] = 3068; C_expected[3][6] = 3424; C_expected[3][7] = 3780;
            C_expected[4][0] = 1568; C_expected[4][1] = 2004; C_expected[4][2] = 2440; C_expected[4][3] = 2876; C_expected[4][4] = 3312; C_expected[4][5] = 3748; C_expected[4][6] = 4184; C_expected[4][7] = 4620;
            C_expected[5][0] = 1848; C_expected[5][1] = 2364; C_expected[5][2] = 2880; C_expected[5][3] = 3396; C_expected[5][4] = 3912; C_expected[5][5] = 4428; C_expected[5][6] = 4944; C_expected[5][7] = 5460;
            C_expected[6][0] = 2128; C_expected[6][1] = 2724; C_expected[6][2] = 3320; C_expected[6][3] = 3916; C_expected[6][4] = 4512; C_expected[6][5] = 5108; C_expected[6][6] = 5704; C_expected[6][7] = 6300;
            C_expected[7][0] = 2408; C_expected[7][1] = 3084; C_expected[7][2] = 3760; C_expected[7][3] = 4436; C_expected[7][4] = 5112; C_expected[7][5] = 5788; C_expected[7][6] = 6464; C_expected[7][7] = 7140;
        end
        // Soft reset before test
        bfm.axi_write(10'h080, 32'h0000_0002, temp_resp);
        #20;
        load_weight_matrix_to_dut;
        load_act_matrix_to_dut;
        run_gemm_and_verify("Ramp");

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
