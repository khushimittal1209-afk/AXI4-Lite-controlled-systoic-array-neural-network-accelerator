//-----------------------------------------------------------------------------
// Module: ping_pong_buffer
// Description: Parameterized dual-bank memory buffer (ping-pong buffer).
//              Enables simultaneous write (to the "back" bank) and read (from
//              the "front" bank). The role of each bank is swapped by pulsing
//              the 'swap' signal.
//
// Parameters:
//   - DATA_WIDTH: Bit width of each storage word.
//   - DEPTH: Number of words in each bank.
//   - ADDR_WIDTH: clog2(DEPTH).
//
// Read mechanism: COMBINATIONAL (read data is available immediately when
//                 rd_addr changes).
// Bank select after reset: 1'b0 (Bank 0 is front/read, Bank 1 is back/write).
//-----------------------------------------------------------------------------
module ping_pong_buffer #(
    parameter DATA_WIDTH = 32,         // Word width (matches AXI data bus or packed row/col width)
    parameter DEPTH      = 16,         // Entries per bank
    parameter ADDR_WIDTH = 4           // clog2(DEPTH)
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // Write port — writes to the BACK bank (load bank)
    input  wire                    wr_en,
    input  wire [ADDR_WIDTH-1:0]   wr_addr,
    input  wire [DATA_WIDTH-1:0]   wr_data,

    // Read port — reads from the FRONT bank (compute bank)
    input  wire                    rd_en,
    input  wire [ADDR_WIDTH-1:0]   rd_addr,
    output wire [DATA_WIDTH-1:0]   rd_data,

    // Bank control
    input  wire                    swap          // Pulse to swap front ↔ back banks
);

    // ---- Memory banks (2x behavioral reg arrays) ----
    reg [DATA_WIDTH-1:0] bank0 [0:DEPTH-1];
    reg [DATA_WIDTH-1:0] bank1 [0:DEPTH-1];

    // ---- Bank selection register ----
    // bank_select = 0: bank0 is front (read), bank1 is back (write)
    // bank_select = 1: bank1 is front (read), bank0 is back (write)
    reg bank_select;

    // ---- Swap and reset logic ----
    always @(posedge clk) begin
        if (!rst_n) begin
            bank_select <= 1'b0; // Default to Bank 0 as front after reset
        end else if (swap) begin
            bank_select <= ~bank_select;
        end
    end

    // ---- Write logic (always writes to the back/load bank) ----
    always @(posedge clk) begin
        if (wr_en) begin
            if (bank_select == 1'b0) begin
                bank1[wr_addr] <= wr_data; // Write to Bank 1 (back bank)
            end else begin
                bank0[wr_addr] <= wr_data; // Write to Bank 0 (back bank)
            end
        end
    end

    // ---- Read logic (combinational read from the front/compute bank) ----
    // When rd_en is deasserted, we output 0 to keep output buses clean/quiescent
    assign rd_data = (!rd_en) ? {DATA_WIDTH{1'b0}} :
                     (bank_select == 1'b0) ? bank0[rd_addr] :
                                             bank1[rd_addr];

endmodule
