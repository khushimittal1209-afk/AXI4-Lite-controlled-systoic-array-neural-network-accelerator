//-----------------------------------------------------------------------------
// Testbench: ping_pong_buffer_tb
// Description: Directed self-checking testbench for ping_pong_buffer.v (Phase 3).
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps

module ping_pong_buffer_tb;

    parameter DATA_WIDTH = 32;
    parameter DEPTH      = 16;
    parameter ADDR_WIDTH = 4;

    reg                    clk;
    reg                    rst_n;
    reg                    wr_en;
    reg  [ADDR_WIDTH-1:0]  wr_addr;
    reg  [DATA_WIDTH-1:0]  wr_data;
    reg                    rd_en;
    reg  [ADDR_WIDTH-1:0]  rd_addr;
    wire [DATA_WIDTH-1:0]  rd_data;
    reg                    swap;

    // Score keeping
    integer pass_count;
    integer fail_count;

    // DUT Instantiation
    ping_pong_buffer #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_en   (rd_en),
        .rd_addr (rd_addr),
        .rd_data (rd_data),
        .swap    (swap)
    );

    // Clock generation (100 MHz, 10ns period)
    initial clk = 0;
    always #5 clk = ~clk;

    // Self-checking tasks
    task check;
        input [80*8-1:0] name;
        input [DATA_WIDTH-1:0] expected;
        input [DATA_WIDTH-1:0] actual;
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

    // Helper: Reset DUT
    task reset_dut;
        begin
            rst_n = 0;
            @(posedge clk); #1;
            rst_n = 1;
            @(posedge clk); #1;
        end
    endtask

    // Helper: Write a word to back bank
    task write_back;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        begin
            wr_en   = 1;
            wr_addr = addr;
            wr_data = data;
            @(posedge clk); #1;
            wr_en   = 0;
            wr_addr = 0;
            wr_data = 0;
        end
    endtask

    // Helper: Swap banks
    task swap_banks;
        begin
            swap = 1;
            @(posedge clk); #1;
            swap = 0;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        $display("================================================");
        $display("  Ping-Pong Buffer Testbench  (Phase 3)");
        $display("================================================");

        pass_count = 0;
        fail_count = 0;

        // Default inputs
        wr_en   = 0;
        wr_addr = 0;
        wr_data = 0;
        rd_en   = 0;
        rd_addr = 0;
        swap    = 0;

        // =============================================================
        // Test 1: Reset behavior and bank_select defaults
        // =============================================================
        $display("\n--- Test 1: Reset Behavior ---");
        reset_dut;
        // Verify bank_select is 0 by writing to back (Bank 1) and checking front (Bank 0)
        // Since we didn't write to Bank 0, reading Bank 0 should be x or undefined (not bank1).
        // Let's write to back bank (Bank 1)
        write_back(4'd0, 32'hAAAA_BBBB);
        
        // Read from Bank 0 (front bank)
        rd_en   = 1;
        rd_addr = 4'd0;
        #1; // Combinational read
        // If bank_select defaulted to 0, reading front bank (Bank 0) should NOT give hAAAA_BBBB.
        if (rd_data === 32'hAAAA_BBBB) begin
            $display("[FAIL] Bank select did not default to 0 on reset (Bank 1 read back on Bank 0)");
            fail_count = fail_count + 1;
        end else begin
            $display("[PASS] Bank select defaulted to 0 on reset (front is Bank 0, write went to Bank 1)");
            pass_count = pass_count + 1;
        end
        rd_en = 0;

        // =============================================================
        // Test 2: Basic Write/Read and Swap
        // =============================================================
        $display("\n--- Test 2: Basic Write/Read and Swap ---");
        // Write 0xDEADBEEF to address 5 of back bank (Bank 1)
        write_back(4'd5, 32'hDEAD_BEEF);
        
        // Swap banks (Bank 1 becomes front, Bank 0 becomes back)
        swap_banks;

        // Read address 5 of front bank (now Bank 1)
        rd_en   = 1;
        rd_addr = 4'd5;
        #1;
        check("Read after swap", 32'hDEAD_BEEF, rd_data);
        rd_en = 0;

        // =============================================================
        // Test 3: Write Isolation
        // =============================================================
        $display("\n--- Test 3: Write Isolation ---");
        // Front bank is Bank 1 (holds 0xDEADBEEF at addr 5)
        // Back bank is Bank 0. Let's write 0xCAFEBABE to addr 5 of back bank (Bank 0)
        write_back(4'd5, 32'hCAFE_BABE);

        // Verify that reading from front bank (Bank 1) still yields 0xDEADBEEF
        rd_en   = 1;
        rd_addr = 4'd5;
        #1;
        check("Front bank value unchanged after back bank write", 32'hDEAD_BEEF, rd_data);
        rd_en = 0;

        // =============================================================
        // Test 4: Simultaneous Load-While-Read (No-Stall)
        // =============================================================
        $display("\n--- Test 4: Simultaneous Load-While-Read ---");
        // Front bank is Bank 1 (read addr 5 should give DEADBEEF)
        // Back bank is Bank 0. Let's read addr 5 from front AND write 0x12345678 to addr 3 of back in same cycle.
        rd_en   = 1;
        rd_addr = 4'd5;
        wr_en   = 1;
        wr_addr = 4'd3;
        wr_data = 32'h1234_5678;
        
        @(posedge clk);
        #1;
        check("Simultaneous read from front bank correct", 32'hDEAD_BEEF, rd_data);
        
        // Deassert ports
        wr_en   = 0;
        wr_addr = 0;
        wr_data = 0;
        rd_en   = 0;

        // Swap to make Bank 0 front
        swap_banks;

        // Verify the written value in Bank 0 (front bank)
        rd_en   = 1;
        rd_addr = 4'd3;
        #1;
        check("Simultaneous write to back bank verified after swap", 32'h1234_5678, rd_data);
        rd_en = 0;

        // =============================================================
        // Test 5: Multiple Swap Cycles (3 consecutive load->swap->read)
        // =============================================================
        $display("\n--- Test 5: Multiple Swap Cycles ---");
        // Phase 5-style streaming simulator:
        // We will perform three consecutive matrix buffer fills and swaps:
        // Phase A: Write Pattern A to back. Swap. Read Pattern A while writing Pattern B.
        // Phase B: Swap. Read Pattern B while writing Pattern C.
        // Phase C: Swap. Read Pattern C.

        // --- Step 1: Write Pattern A to back bank (Bank 0) ---
        write_back(4'd0, 32'hAAAA_0000);
        write_back(4'd1, 32'hAAAA_0001);
        swap_banks; // Front = Bank 0, Back = Bank 1

        // --- Step 2: Read Pattern A (front) while Writing Pattern B (back) ---
        rd_en   = 1;
        rd_addr = 4'd0;
        #1;
        check("Pattern A [0] read correct", 32'hAAAA_0000, rd_data);
        rd_addr = 4'd1;
        #1;
        check("Pattern A [1] read correct", 32'hAAAA_0001, rd_data);
        rd_en = 0;

        write_back(4'd0, 32'hBBBB_0000);
        write_back(4'd1, 32'hBBBB_0001);
        swap_banks; // Front = Bank 1, Back = Bank 0

        // --- Step 3: Read Pattern B (front) while Writing Pattern C (back) ---
        rd_en   = 1;
        rd_addr = 4'd0;
        #1;
        check("Pattern B [0] read correct", 32'hBBBB_0000, rd_data);
        rd_addr = 4'd1;
        #1;
        check("Pattern B [1] read correct", 32'hBBBB_0001, rd_data);
        rd_en = 0;

        write_back(4'd0, 32'hCCCC_0000);
        write_back(4'd1, 32'hCCCC_0001);
        swap_banks; // Front = Bank 0, Back = Bank 1

        // --- Step 4: Read Pattern C (front) ---
        rd_en   = 1;
        rd_addr = 4'd0;
        #1;
        check("Pattern C [0] read correct", 32'hCCCC_0000, rd_data);
        rd_addr = 4'd1;
        #1;
        check("Pattern C [1] read correct", 32'hCCCC_0001, rd_data);
        rd_en = 0;

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
