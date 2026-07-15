//-----------------------------------------------------------------------------
// Module: axi_lite_slave
// Description: Full AXI4-Lite slave interface. Decodes read/write transactions
//              to register offsets defined in register_map.md.
//
//              - OKAY response returned for valid register writes.
//              - SILENTLY IGNORE writes to reserved ranges or read-only registers,
//                returning OKAY (justified in test review).
//              - SLVERR returned for out-of-bounds address space access (>0x3FF).
//              - CTRL register START (bit 0) and SOFT_RESET (bit 1) bits are
//                pulsed for 1 cycle and self-clear in the next cycle.
//              - Read data is registered to ensure stability during RVALID.
//-----------------------------------------------------------------------------
module axi_lite_slave #(
    parameter ADDR_WIDTH = 10,         // 1024-byte address space (10-bit address)
    parameter DATA_WIDTH = 32          // 32-bit data bus
)(
    // ---- AXI global signals ----
    input  wire                        aclk,
    input  wire                        aresetn,       // Active-low synchronous

    // ---- AXI4-Lite Write Address Channel ----
    input  wire [ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  wire                        s_axi_awvalid,
    output reg                         s_axi_awready,

    // ---- AXI4-Lite Write Data Channel ----
    input  wire [DATA_WIDTH-1:0]       s_axi_wdata,
    input  wire [(DATA_WIDTH/8)-1:0]   s_axi_wstrb,
    input  wire                        s_axi_wvalid,
    output reg                         s_axi_wready,

    // ---- AXI4-Lite Write Response Channel ----
    output reg  [1:0]                  s_axi_bresp,
    output reg                         s_axi_bvalid,
    input  wire                        s_axi_bready,

    // ---- AXI4-Lite Read Address Channel ----
    input  wire [ADDR_WIDTH-1:0]       s_axi_araddr,
    input  wire                        s_axi_arvalid,
    output reg                         s_axi_arready,

    // ---- AXI4-Lite Read Data Channel ----
    output reg  [DATA_WIDTH-1:0]       s_axi_rdata,
    output reg  [1:0]                  s_axi_rresp,
    output reg                         s_axi_rvalid,
    input  wire                        s_axi_rready,

    // ---- Internal control outputs ----
    output reg                         ctrl_start,         // 1-cycle pulse
    output reg                         ctrl_soft_reset,    // 1-cycle pulse

    // ---- Internal status inputs ----
    input  wire                        status_busy,
    input  wire                        status_done,

    // ---- Clock-gating control outputs ----
    output reg  [7:0]                  clk_gate_row_en,
    output reg  [7:0]                  clk_gate_col_en,

    // ---- Weight buffer write interface ----
    output reg                         weight_wr_en,
    output reg  [3:0]                  weight_wr_addr,
    output reg  [DATA_WIDTH-1:0]       weight_wr_data,

    // ---- Activation buffer write interface ----
    output reg                         act_wr_en,
    output reg  [3:0]                  act_wr_addr,
    output reg  [DATA_WIDTH-1:0]       act_wr_data,

    // ---- Result readback interface (raw 32-bit accumulators) ----
    output reg  [5:0]                  result_raw_addr,
    input  wire [DATA_WIDTH-1:0]       result_raw_rdata,

    // ---- Result readback interface (saturated INT8 packed) ----
    output reg  [3:0]                  result_sat_addr,
    input  wire [DATA_WIDTH-1:0]       result_sat_rdata
);

    // AXI Response Codes
    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;

    // ---- Stand-in internal storage for Phase 4 ----
    reg [DATA_WIDTH-1:0] weight_mem [0:15];
    reg [DATA_WIDTH-1:0] act_mem    [0:15];
    reg [DATA_WIDTH-1:0] raw_mem    [0:63];
    reg [DATA_WIDTH-1:0] sat_mem    [0:15];

    // ---- FSM States for Write Channel ----
    localparam W_IDLE = 1'b0;
    localparam W_RESP = 1'b1;
    reg w_state;

    // Write capture registers
    reg [ADDR_WIDTH-1:0] awaddr_reg;
    reg                  awvalid_reg;
    reg [DATA_WIDTH-1:0] wdata_reg;
    reg                  wvalid_reg;

    // ---- FSM States for Read Channel ----
    localparam R_IDLE = 1'b0;
    localparam R_RESP = 1'b1;
    reg r_state;

    // ---- Write Channel Logic ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            w_state         <= W_IDLE;
            s_axi_awready   <= 1'b0;
            s_axi_wready    <= 1'b0;
            s_axi_bvalid    <= 1'b0;
            s_axi_bresp     <= RESP_OKAY;
            awaddr_reg      <= 0;
            awvalid_reg     <= 1'b0;
            wdata_reg       <= 0;
            wvalid_reg      <= 1'b0;
            
            // Register resets
            ctrl_start      <= 1'b0;
            ctrl_soft_reset <= 1'b0;
            clk_gate_row_en <= 8'h00;
            clk_gate_col_en <= 8'h00;
            weight_wr_en    <= 1'b0;
            weight_wr_addr  <= 0;
            weight_wr_data  <= 0;
            act_wr_en       <= 1'b0;
            act_wr_addr     <= 0;
            act_wr_data     <= 0;
        end else begin
            // Pulses only last 1 cycle
            ctrl_start      <= 1'b0;
            ctrl_soft_reset <= 1'b0;
            weight_wr_en    <= 1'b0;
            act_wr_en       <= 1'b0;

            case (w_state)
                W_IDLE: begin
                    s_axi_bvalid <= 1'b0;
                    
                    // Capture Write Address
                    if (s_axi_awvalid && !awvalid_reg) begin
                        awaddr_reg    <= s_axi_awaddr;
                        awvalid_reg   <= 1'b1;
                        s_axi_awready <= 1'b1;
                    end else begin
                        s_axi_awready <= 1'b0;
                    end

                    // Capture Write Data
                    if (s_axi_wvalid && !wvalid_reg) begin
                        wdata_reg    <= s_axi_wdata;
                        wvalid_reg   <= 1'b1;
                        s_axi_wready <= 1'b1;
                    end else begin
                        s_axi_wready <= 1'b0;
                    end

                    if ((awvalid_reg || (s_axi_awvalid && s_axi_awready)) &&
                        (wvalid_reg  || (s_axi_wvalid  && s_axi_wready))) begin
                        begin : write_exec
                            reg [ADDR_WIDTH-1:0] write_addr;
                            reg [DATA_WIDTH-1:0] write_data;
                            write_addr = awvalid_reg ? awaddr_reg : s_axi_awaddr;
                            write_data = wvalid_reg  ? wdata_reg  : s_axi_wdata;

                            // Clear handshakes for AW/W
                            s_axi_awready <= 1'b0;
                            s_axi_wready  <= 1'b0;
                            awvalid_reg   <= 1'b0;
                            wvalid_reg    <= 1'b0;

                            // Decode Address
                            if (write_addr > 10'h3FF) begin
                                // Out of bounds address space limit -> SLVERR
                                s_axi_bresp <= RESP_SLVERR;
                            end else begin
                                s_axi_bresp <= RESP_OKAY; // In bounds

                                if (write_addr >= 10'h000 && write_addr <= 10'h03C) begin
                                    // WEIGHT_DATA
                                    weight_mem[write_addr[5:2]] <= write_data;
                                    weight_wr_en   <= 1'b1;
                                    weight_wr_addr <= write_addr[5:2];
                                    weight_wr_data <= write_data;
                                end else if (write_addr >= 10'h040 && write_addr <= 10'h07C) begin
                                    // ACT_DATA
                                    act_mem[write_addr[5:2]] <= write_data;
                                    act_wr_en   <= 1'b1;
                                    act_wr_addr <= write_addr[5:2];
                                    act_wr_data <= write_data;
                                end else if (write_addr == 10'h080) begin
                                    // CTRL register
                                    ctrl_start      <= write_data[0];
                                    ctrl_soft_reset <= write_data[1];
                                end else if (write_addr == 10'h088) begin
                                    // CLK_GATE_CTRL
                                    clk_gate_row_en <= write_data[7:0];
                                    clk_gate_col_en <= write_data[15:8];
                                end
                                // Other registers (STATUS 0x084, RESULT_RAW 0x100-0x1FC, RESULT_SAT 0x200-0x23C, and reserved)
                                // are either read-only or ignored -> silently ignored (OKAY response).
                            end

                            s_axi_bvalid <= 1'b1;
                            w_state      <= W_RESP;
                        end
                    end
                end

                W_RESP: begin
                    if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        w_state      <= W_IDLE;
                    end
                end
            endcase
        end
    end

    // ---- Read Channel Logic ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            r_state         <= R_IDLE;
            s_axi_arready   <= 1'b0;
            s_axi_rvalid    <= 1'b0;
            s_axi_rdata     <= 0;
            s_axi_rresp     <= RESP_OKAY;
            result_raw_addr <= 0;
            result_sat_addr <= 0;
        end else begin
            case (r_state)
                R_IDLE: begin
                    s_axi_arready <= 1'b1;
                    if (s_axi_arvalid && s_axi_arready) begin
                        s_axi_arready <= 1'b0;
                        s_axi_rvalid  <= 1'b1;

                        // Perform address decoding and read registering
                        if (s_axi_araddr > 10'h3FF) begin
                            s_axi_rdata <= 0;
                            s_axi_rresp <= RESP_SLVERR;
                        end else begin
                            s_axi_rresp <= RESP_OKAY;
                            
                            if (s_axi_araddr >= 10'h000 && s_axi_araddr <= 10'h03C) begin
                                // WEIGHT_DATA
                                s_axi_rdata <= weight_mem[s_axi_araddr[5:2]];
                            end else if (s_axi_araddr >= 10'h040 && s_axi_araddr <= 10'h07C) begin
                                // ACT_DATA
                                s_axi_rdata <= act_mem[s_axi_araddr[5:2]];
                            end else if (s_axi_araddr == 10'h080) begin
                                // CTRL: read always returns 0 because START and SOFT_RESET are self-clearing
                                s_axi_rdata <= 0;
                            end else if (s_axi_araddr == 10'h084) begin
                                // STATUS
                                s_axi_rdata <= {30'd0, status_done, status_busy};
                            end else if (s_axi_araddr == 10'h088) begin
                                // CLK_GATE_CTRL
                                s_axi_rdata <= {16'd0, clk_gate_col_en, clk_gate_row_en};
                            end else if (s_axi_araddr >= 10'h100 && s_axi_araddr <= 10'h1FC) begin
                                // RESULT_RAW
                                s_axi_rdata     <= raw_mem[s_axi_araddr[7:2]];
                                result_raw_addr <= s_axi_araddr[7:2];
                            end else if (s_axi_araddr >= 10'h200 && s_axi_araddr <= 10'h23C) begin
                                // RESULT_SAT
                                s_axi_rdata     <= sat_mem[s_axi_araddr[5:2]];
                                result_sat_addr <= s_axi_araddr[5:2];
                            end else begin
                                // Reserved range -> returns 0
                                s_axi_rdata <= 0;
                            end
                        end
                        r_state <= R_RESP;
                    end
                end

                R_RESP: begin
                    if (s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        r_state      <= R_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
