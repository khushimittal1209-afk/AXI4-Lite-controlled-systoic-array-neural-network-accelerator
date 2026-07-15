//-----------------------------------------------------------------------------
// Testbench: axi_lite_slave_tb
// Description: Directed self-checking testbench for axi_lite_slave.v (Phase 4).
//              Uses axi_lite_master_bfm to drive AXI4-Lite read/write transactions.
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps

module axi_lite_slave_tb;

    parameter ADDR_WIDTH = 10;
    parameter DATA_WIDTH = 32;

    reg                        clk;
    reg                        rst_n;

    // AXI signals
    wire [ADDR_WIDTH-1:0]      axi_awaddr;
    wire                       axi_awvalid;
    wire                       axi_awready;

    wire [DATA_WIDTH-1:0]      axi_wdata;
    wire [(DATA_WIDTH/8)-1:0]  axi_wstrb;
    wire                       axi_wvalid;
    wire                       axi_wready;

    wire [1:0]                 axi_bresp;
    wire                       axi_bvalid;
    wire                       axi_bready;

    wire [ADDR_WIDTH-1:0]      axi_araddr;
    wire                       axi_arvalid;
    wire                       axi_arready;

    wire [DATA_WIDTH-1:0]      axi_rdata;
    wire [1:0]                 axi_rresp;
    wire                       axi_rvalid;
    wire                       axi_rready;

    // DUT Internal signals
    wire                       ctrl_start;
    wire                       ctrl_soft_reset;
    reg                        status_busy;
    reg                        status_done;
    wire [7:0]                 clk_gate_row_en;
    wire [7:0]                 clk_gate_col_en;

    wire                       weight_wr_en;
    wire [3:0]                 weight_wr_addr;
    wire [DATA_WIDTH-1:0]      weight_wr_data;

    wire                       act_wr_en;
    wire [3:0]                 act_wr_addr;
    wire [DATA_WIDTH-1:0]      act_wr_data;

    wire [5:0]                 result_raw_addr;
    reg  [DATA_WIDTH-1:0]      result_raw_rdata;

    wire [3:0]                 result_sat_addr;
    reg  [DATA_WIDTH-1:0]      result_sat_rdata;

    // Score keeping
    integer pass_count;
    integer fail_count;

    // Backdoor preloads for Phase 4
    integer i;

    // DUT Instantiation
    axi_lite_slave #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) dut (
        .aclk             (clk),
        .aresetn          (rst_n),
        .s_axi_awaddr     (axi_awaddr),
        .s_axi_awvalid    (axi_awvalid),
        .s_axi_awready    (axi_awready),
        .s_axi_wdata      (axi_wdata),
        .s_axi_wstrb      (axi_wstrb),
        .s_axi_wvalid     (axi_wvalid),
        .s_axi_wready     (axi_wready),
        .s_axi_bresp      (axi_bresp),
        .s_axi_bvalid     (axi_bvalid),
        .s_axi_bready     (axi_bready),
        .s_axi_araddr     (axi_araddr),
        .s_axi_arvalid    (axi_arvalid),
        .s_axi_arready    (axi_arready),
        .s_axi_rdata      (axi_rdata),
        .s_axi_rresp      (axi_rresp),
        .s_axi_rvalid     (axi_rvalid),
        .s_axi_rready     (axi_rready),
        .ctrl_start       (ctrl_start),
        .ctrl_soft_reset  (ctrl_soft_reset),
        .status_busy      (status_busy),
        .status_done      (status_done),
        .clk_gate_row_en  (clk_gate_row_en),
        .clk_gate_col_en  (clk_gate_col_en),
        .weight_wr_en     (weight_wr_en),
        .weight_wr_addr   (weight_wr_addr),
        .weight_wr_data   (weight_wr_data),
        .act_wr_en        (act_wr_en),
        .act_wr_addr      (act_wr_addr),
        .act_wr_data      (act_wr_data),
        .result_raw_addr  (result_raw_addr),
        .result_raw_rdata (result_raw_rdata),
        .result_sat_addr  (result_sat_addr),
        .result_sat_rdata (result_sat_rdata)
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

    // Self-checking tasks
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

    // Monitors pulse duration
    reg start_pulsed;
    always @(posedge clk) begin
        if (ctrl_start) begin
            start_pulsed <= 1;
        end else begin
            start_pulsed <= 0;
        end
    end

    // Main Test Flow
    reg [DATA_WIDTH-1:0] temp_data;
    reg [1:0]            temp_resp;

    initial begin
        $display("================================================");
        $display("  AXI4-Lite Slave & BFM Testbench  (Phase 4)");
        $display("================================================");

        pass_count = 0;
        fail_count = 0;

        // Default inputs
        status_busy      = 0;
        status_done      = 0;
        result_raw_rdata = 0;
        result_sat_rdata = 0;

        // Reset the system
        rst_n = 0;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;

        // =============================================================
        // Test 1: Write and Read back WEIGHT_DATA, ACT_DATA, CLK_GATE_CTRL
        // =============================================================
        $display("\n--- Test 1: Write and Read back ---");
        // Write weight data to index 1 (offset 0x004)
        bfm.axi_write(10'h004, 32'h11223344, temp_resp);
        check("Write WEIGHT_DATA[1] response", 2'b00, temp_resp);
        
        bfm.axi_read(10'h004, temp_data, temp_resp);
        check("Read back WEIGHT_DATA[1] value", 32'h11223344, temp_data);
        check("Read back WEIGHT_DATA[1] response", 2'b00, temp_resp);

        // Write activation data to index 3 (offset 0x04C)
        bfm.axi_write(10'h04C, 32'h55667788, temp_resp);
        check("Write ACT_DATA[3] response", 2'b00, temp_resp);
        
        bfm.axi_read(10'h04C, temp_data, temp_resp);
        check("Read back ACT_DATA[3] value", 32'h55667788, temp_data);

        // Write to CLK_GATE_CTRL
        bfm.axi_write(10'h088, 32'h0000_1234, temp_resp);
        check("Write CLK_GATE_CTRL response", 2'b00, temp_resp);

        bfm.axi_read(10'h088, temp_data, temp_resp);
        check("Read back CLK_GATE_CTRL value", 32'h0000_1234, temp_data);

        // =============================================================
        // Test 2: CTRL Self-Clearing Timing and Read Behavior
        // =============================================================
        $display("\n--- Test 2: CTRL Self-Clearing Timing ---");
        // We write START = 1 (bit 0) to CTRL (0x080)
        bfm.axi_write(10'h080, 32'h0000_0001, temp_resp);
        check("Write CTRL START response", 2'b00, temp_resp);

        // In our registered FSM, ctrl_start is pulsed for exactly 1 cycle.
        // We read back CTRL immediately. It must return 0.
        bfm.axi_read(10'h080, temp_data, temp_resp);
        check("CTRL read-back is 0 (self-cleared)", 32'h0000_0000, temp_data);

        // Check if the pulse was captured by our monitor (confirming pulse occurred)
        #0.1;
        check("ctrl_start was pulsed high for 1 cycle", 1'b1, start_pulsed);

        // =============================================================
        // Test 3: STATUS Read-Only Enforcement
        // =============================================================
        $display("\n--- Test 3: STATUS Read-Only ---");
        // Force STATUS inputs externally
        status_busy = 1'b1;
        status_done = 1'b1;
        
        // Attempt a write to STATUS (0x084) — should be ignored and return OKAY
        bfm.axi_write(10'h084, 32'hFFFF_FFFF, temp_resp);
        check("Write to STATUS response (silently ignored)", 2'b00, temp_resp);

        // Read STATUS back — must reflect the externally forced values, not the write
        bfm.axi_read(10'h084, temp_data, temp_resp);
        check("STATUS read back matches forced values (not overridden by write)", 32'h0000_0003, temp_data);

        // =============================================================
        // Test 4: RESULT_RAW & RESULT_SAT Read-Only Enforcement & Backdoor Read
        // =============================================================
        $display("\n--- Test 4: RESULT_RAW / RESULT_SAT Read-Only & Read Verification ---");
        // Preload our test memory backdoor
        dut.raw_mem[12] = 32'h1234_5678;
        dut.sat_mem[4]  = 32'h8765_4321;

        // Try writing to RESULT_RAW[12] (offset 0x130)
        bfm.axi_write(10'h130, 32'h9999_9999, temp_resp);
        check("Write to RESULT_RAW response (ignored)", 2'b00, temp_resp);

        // Read back RESULT_RAW[12] — must still return preloaded value
        bfm.axi_read(10'h130, temp_data, temp_resp);
        check("RESULT_RAW read back correct", 32'h1234_5678, temp_data);

        // Try writing to RESULT_SAT[4] (offset 0x210)
        bfm.axi_write(10'h210, 32'hFFFF_FFFF, temp_resp);
        check("Write to RESULT_SAT response (ignored)", 2'b00, temp_resp);

        // Read back RESULT_SAT[4] — must still return preloaded value
        bfm.axi_read(10'h210, temp_data, temp_resp);
        check("RESULT_SAT read back correct", 32'h8765_4321, temp_data);

        // =============================================================
        // Test 5: Reserved address range
        // =============================================================
        $display("\n--- Test 5: Reserved range ---");
        // Write to reserved offset 0x090
        bfm.axi_write(10'h090, 32'hCAFE_FADE, temp_resp);
        check("Write to reserved range response (ignored)", 2'b00, temp_resp);

        // Read from reserved offset 0x090 — must return 0
        bfm.axi_read(10'h090, temp_data, temp_resp);
        check("Read from reserved range returns 0", 32'h0000_0000, temp_data);

        // =============================================================
        // Test 6: Back-to-back Transactions (No Idle Cycles)
        // =============================================================
        $display("\n--- Test 6: Back-to-back Transactions ---");
        // Issue 3 writes back-to-back, then 3 reads back-to-back.
        // The BFM tasks naturally wait for handshakes, so we call them in sequence.
        bfm.axi_write(10'h00C, 32'h1111_1111, temp_resp);
        bfm.axi_write(10'h010, 32'h2222_2222, temp_resp);
        bfm.axi_write(10'h014, 32'h3333_3333, temp_resp);

        bfm.axi_read(10'h00C, temp_data, temp_resp);
        check("Back-to-back read 1", 32'h1111_1111, temp_data);
        bfm.axi_read(10'h010, temp_data, temp_resp);
        check("Back-to-back read 2", 32'h2222_2222, temp_data);
        bfm.axi_read(10'h014, temp_data, temp_resp);
        check("Back-to-back read 3", 32'h3333_3333, temp_data);

        // =============================================================
        // Test 7: Address/Data on Separate Cycles (Skewed handshakes)
        // =============================================================
        $display("\n--- Test 7: Address/Data on Separate Cycles ---");
        // Test 7a: Address first, data 1 cycle later
        bfm.axi_write_skewed(10'h018, 32'hAAAA_AAAA, 1'b1, temp_resp);
        check("Skewed Write Address-first response", 2'b00, temp_resp);
        bfm.axi_read(10'h018, temp_data, temp_resp);
        check("Read back skew write 1", 32'hAAAA_AAAA, temp_data);

        // Test 7b: Data first, address 1 cycle later
        bfm.axi_write_skewed(10'h01C, 32'hBBBB_BBBB, 1'b0, temp_resp);
        check("Skewed Write Data-first response", 2'b00, temp_resp);
        bfm.axi_read(10'h01C, temp_data, temp_resp);
        check("Read back skew write 2", 32'hBBBB_BBBB, temp_data);

        // =============================================================
        // Test 8: Read Data Registration Verification (Synchronous RDATA)
        // =============================================================
        $display("\n--- Test 8: Read Data Registration Verification ---");
        // In AXI4-Lite, if RDATA is registered, when ARVALID/ARREADY handshake happens,
        // the read data RDATA should NOT change instantly (combinational), but rather
        // updates on the NEXT rising edge of clk (when RVALID goes high).
        // Let's verify:
        // 1. Preload 0x55555555 into WEIGHT_DATA[0] (offset 0x000)
        dut.weight_mem[0] = 32'h5555_5555;
        // 2. Put old value in RDATA
        // 3. Drive ARADDR = 0, ARVALID = 1, RREADY = 1
        // 4. On the exact edge of ARVALID & ARREADY, we inspect RDATA.
        // It must NOT match the new value immediately on the same clock cycle,
        // it must only update to 0x55555555 on the NEXT rising clock edge.
        
        bfm.m_axi_araddr  = 10'h000;
        bfm.m_axi_arvalid = 1'b1;
        bfm.m_axi_rready  = 1'b1;
        
        // Wait until address handshake occurs (ARVALID & ARREADY high)
        while (!(bfm.m_axi_arvalid && bfm.m_axi_arready)) @(posedge clk);
        
        // Address is handshaked on this positive edge.
        // Let's wait a tiny fraction of a cycle (delta cycle) to verify RDATA does NOT
        // combinationaly update. It should still be the old value (0) because it registers
        // on the next clock cycle.
        #0.1;
        check("RDATA did NOT update combinationaly during address handshake (registered check)", 1'b1, (axi_rdata !== 32'h5555_5555));
        
        // Wait for the next clock edge when RVALID is asserted and RDATA registers.
        while (!axi_rvalid) @(posedge clk);
        #0.1;
        check("RDATA correctly registered on next clock cycle when RVALID is asserted", 32'h5555_5555, axi_rdata);
        
        // Clear signals
        bfm.m_axi_arvalid = 0;
        bfm.m_axi_araddr  = 0;
        bfm.m_axi_rready  = 0;
        @(posedge clk); #1;

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
