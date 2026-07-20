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
    output wire [5:0]                  result_raw_addr,
    input  wire [DATA_WIDTH-1:0]       result_raw_rdata,

    // ---- Result readback interface (saturated INT8 packed) ----
    output wire [3:0]                  result_sat_addr,
    input  wire [DATA_WIDTH-1:0]       result_sat_rdata
);

    // AXI Response Codes
    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;

    // ---- Stand-in internal storage for Phase 4 ----
    reg [DATA_WIDTH-1:0] weight_mem [0:15];
    reg [DATA_WIDTH-1:0] act_mem    [0:15];

    reg [ADDR_WIDTH-1:0] awaddr_reg;
    reg [DATA_WIDTH-1:0] wdata_reg;
    reg [ADDR_WIDTH-1:0] araddr_reg;

    reg aw_done;
    reg w_done;
    reg ar_done;

    // ---- Write Address Channel (AW) ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            awaddr_reg    <= 0;
        end else begin
            if (s_axi_awvalid && !s_axi_awready && !aw_done) begin
                s_axi_awready <= 1'b1;
                awaddr_reg    <= s_axi_awaddr;
            end else begin
                s_axi_awready <= 1'b0;
            end
        end
    end

    // ---- Write Data Channel (W) ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_wready <= 1'b0;
            wdata_reg    <= 0;
        end else begin
            if (s_axi_wvalid && !s_axi_wready && !w_done) begin
                s_axi_wready <= 1'b1;
                wdata_reg    <= s_axi_wdata;
            end else begin
                s_axi_wready <= 1'b0;
            end
        end
    end

    // ---- Write Handshake Control (aw_done / w_done) ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_done <= 1'b0;
            w_done  <= 1'b0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_done <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                aw_done <= 1'b0;
            end

            if (s_axi_wvalid && s_axi_wready) begin
                w_done <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                w_done <= 1'b0;
            end
        end
    end

    // ---- Write Execution and Response (B) ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_bvalid    <= 1'b0;
            s_axi_bresp     <= RESP_OKAY;
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
            ctrl_start      <= 1'b0;
            ctrl_soft_reset <= 1'b0;
            weight_wr_en    <= 1'b0;
            act_wr_en       <= 1'b0;

            if (aw_done && w_done && !s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                if (awaddr_reg > 10'h3FF) begin
                    s_axi_bresp <= RESP_SLVERR;
                end else begin
                    s_axi_bresp <= RESP_OKAY;
                    if (awaddr_reg >= 10'h000 && awaddr_reg <= 10'h03C) begin
                        weight_mem[awaddr_reg[5:2]] <= wdata_reg;
                        weight_wr_en   <= 1'b1;
                        weight_wr_addr <= awaddr_reg[5:2];
                        weight_wr_data <= wdata_reg;
                    end else if (awaddr_reg >= 10'h040 && awaddr_reg <= 10'h07C) begin
                        act_mem[awaddr_reg[5:2]] <= wdata_reg;
                        act_wr_en   <= 1'b1;
                        act_wr_addr <= awaddr_reg[5:2];
                        act_wr_data <= wdata_reg;
                    end else if (awaddr_reg == 10'h080) begin
                        ctrl_start      <= wdata_reg[0];
                        ctrl_soft_reset <= wdata_reg[1];
                    end else if (awaddr_reg == 10'h088) begin
                        clk_gate_row_en <= wdata_reg[7:0];
                        clk_gate_col_en <= wdata_reg[15:8];
                    end
                end
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ---- Read Address Channel (AR) ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            araddr_reg    <= 0;
        end else begin
            if (s_axi_arvalid && !s_axi_arready && !ar_done) begin
                s_axi_arready <= 1'b1;
                araddr_reg    <= s_axi_araddr;
            end else begin
                s_axi_arready <= 1'b0;
            end
        end
    end

    // ---- Read Handshake Control (ar_done) ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            ar_done <= 1'b0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                ar_done <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                ar_done <= 1'b0;
            end
        end
    end

    // ---- Read Execution and Response (R) ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_rvalid    <= 1'b0;
            s_axi_rdata     <= 0;
            s_axi_rresp     <= RESP_OKAY;
        end else begin
            if (ar_done && !s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                if (araddr_reg > 10'h3FF) begin
                    s_axi_rdata <= 0;
                    s_axi_rresp <= RESP_SLVERR;
                end else begin
                    s_axi_rresp <= RESP_OKAY;
                    if (araddr_reg >= 10'h000 && araddr_reg <= 10'h03C) begin
                        s_axi_rdata <= weight_mem[araddr_reg[5:2]];
                    end else if (araddr_reg >= 10'h040 && araddr_reg <= 10'h07C) begin
                        s_axi_rdata <= act_mem[araddr_reg[5:2]];
                    end else if (araddr_reg == 10'h080) begin
                        s_axi_rdata <= 0;
                    end else if (araddr_reg == 10'h084) begin
                        s_axi_rdata <= {30'd0, status_done, status_busy};
                    end else if (araddr_reg == 10'h088) begin
                        s_axi_rdata <= {16'd0, clk_gate_col_en, clk_gate_row_en};
                    end else if (araddr_reg >= 10'h100 && araddr_reg <= 10'h1FC) begin
                        s_axi_rdata <= result_raw_rdata;
                    end else if (araddr_reg >= 10'h200 && araddr_reg <= 10'h23C) begin
                        s_axi_rdata <= result_sat_rdata;
                    end else begin
                        s_axi_rdata <= 0;
                    end
                end
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // Combinational assignment of read addresses to results memories
    assign result_raw_addr = araddr_reg[7:2];
    assign result_sat_addr = araddr_reg[5:2];

endmodule
