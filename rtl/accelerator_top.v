//-----------------------------------------------------------------------------
// Module: accelerator_top
// Description: Top-level integration module.
//              Connects AXI4-Lite slave ↔ ping-pong buffers ↔ systolic array
//              ↔ result storage. Contains the compute-control FSM.
//-----------------------------------------------------------------------------
module accelerator_top #(
    parameter ADDR_WIDTH  = 10,        // AXI address width
    parameter DATA_WIDTH  = 32,        // AXI data bus width
    parameter N           = 8,         // Systolic array dimension (N×N)
    parameter INT_WIDTH   = 8,         // INT8 operand width
    parameter ACC_WIDTH   = 32         // Internal accumulator width
)(
    // ---- AXI global signals ----
    input  wire                        aclk,
    input  wire                        aresetn,

    // ---- AXI4-Lite Write Address Channel ----
    input  wire [ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  wire                        s_axi_awvalid,
    output wire                        s_axi_awready,

    // ---- AXI4-Lite Write Data Channel ----
    input  wire [DATA_WIDTH-1:0]       s_axi_wdata,
    input  wire [(DATA_WIDTH/8)-1:0]   s_axi_wstrb,
    input  wire                        s_axi_wvalid,
    output wire                        s_axi_wready,

    // ---- AXI4-Lite Write Response Channel ----
    output wire [1:0]                  s_axi_bresp,
    output wire                        s_axi_bvalid,
    input  wire                        s_axi_bready,

    // ---- AXI4-Lite Read Address Channel ----
    input  wire [ADDR_WIDTH-1:0]       s_axi_araddr,
    input  wire                        s_axi_arvalid,
    output wire                        s_axi_arready,

    // ---- AXI4-Lite Read Data Channel ----
    output wire [DATA_WIDTH-1:0]       s_axi_rdata,
    output wire [1:0]                  s_axi_rresp,
    output wire                        s_axi_rvalid,
    input  wire                        s_axi_rready
);

    // ---- Internal Control and Status ----
    wire                     ctrl_start;
    wire                     ctrl_soft_reset;
    reg                      status_busy;
    reg                      status_done;
    wire [7:0]               clk_gate_row_en;
    wire [7:0]               clk_gate_col_en;

    // ---- AXI slave interfaces to buffers ----
    wire                     weight_wr_en;
    wire [3:0]               weight_wr_addr;
    wire [DATA_WIDTH-1:0]    weight_wr_data;
    wire                     act_wr_en;
    wire [3:0]               act_wr_addr;
    wire [DATA_WIDTH-1:0]    act_wr_data;

    // ---- Buffer packing registers ----
    reg [31:0]               weight_tmp_reg;
    reg                      weight_buf_wr_en;
    reg [2:0]                weight_buf_wr_addr;
    reg [63:0]               weight_buf_wr_data;

    reg [31:0]               act_tmp_reg;
    reg                      act_buf_wr_en;
    reg [2:0]                act_buf_wr_addr;
    reg [63:0]               act_buf_wr_data;

    always @(posedge aclk) begin
        if (!aresetn || ctrl_soft_reset) begin
            weight_tmp_reg     <= 32'd0;
            weight_buf_wr_en   <= 1'b0;
            weight_buf_wr_addr <= 3'd0;
            weight_buf_wr_data <= 64'd0;
        end else begin
            if (weight_wr_en) begin
                if (weight_wr_addr[0] == 1'b0) begin
                    weight_tmp_reg   <= weight_wr_data;
                    weight_buf_wr_en <= 1'b0;
                end else begin
                    weight_buf_wr_en   <= 1'b1;
                    weight_buf_wr_addr <= weight_wr_addr[3:1];
                    weight_buf_wr_data <= {weight_wr_data, weight_tmp_reg};
                end
            end else begin
                weight_buf_wr_en <= 1'b0;
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn || ctrl_soft_reset) begin
            act_tmp_reg     <= 32'd0;
            act_buf_wr_en   <= 1'b0;
            act_buf_wr_addr <= 3'd0;
            act_buf_wr_data <= 64'd0;
        end else begin
            if (act_wr_en) begin
                if (act_wr_addr[0] == 1'b0) begin
                    act_tmp_reg   <= act_wr_data;
                    act_buf_wr_en <= 1'b0;
                end else begin
                    act_buf_wr_en   <= 1'b1;
                    act_buf_wr_addr <= act_wr_addr[3:1];
                    act_buf_wr_data <= {act_wr_data, act_tmp_reg};
                end
            end else begin
                act_buf_wr_en <= 1'b0;
            end
        end
    end

    // ---- Buffer Read Interfaces ----
    wire                     weight_buf_rd_en;
    wire [2:0]               weight_buf_rd_addr;
    wire [63:0]              weight_buf_rd_data;

    wire                     act_buf_rd_en;
    wire [2:0]               act_buf_rd_addr;
    wire [63:0]              act_buf_rd_data;

    wire                     buffers_swap;

    // ---- Instantiate buffers ----
    ping_pong_buffer #(
        .DATA_WIDTH (64),
        .DEPTH      (8),
        .ADDR_WIDTH (3)
    ) weight_buf (
        .clk      (aclk),
        .rst_n    (aresetn && !ctrl_soft_reset),
        .wr_en    (weight_buf_wr_en),
        .wr_addr  (weight_buf_wr_addr),
        .wr_data  (weight_buf_wr_data),
        .rd_en    (weight_buf_rd_en),
        .rd_addr  (weight_buf_rd_addr),
        .rd_data  (weight_buf_rd_data),
        .swap     (buffers_swap)
    );

    ping_pong_buffer #(
        .DATA_WIDTH (64),
        .DEPTH      (8),
        .ADDR_WIDTH (3)
    ) act_buf (
        .clk      (aclk),
        .rst_n    (aresetn && !ctrl_soft_reset),
        .wr_en    (act_buf_wr_en),
        .wr_addr  (act_buf_wr_addr),
        .wr_data  (act_buf_wr_data),
        .rd_en    (act_buf_rd_en),
        .rd_addr  (act_buf_rd_addr),
        .rd_data  (act_buf_rd_data),
        .swap     (buffers_swap)
    );

    // ---- FSM states ----
    localparam IDLE         = 3'd0;
    localparam SWAP         = 3'd1;
    localparam LOAD_WEIGHTS = 3'd2;
    localparam STREAM       = 3'd3;
    localparam DONE         = 3'd4;

    reg [2:0]  state;
    reg [4:0]  count_reg; // Counter for cycles inside states

    // FSM control signals
    assign buffers_swap       = (state == SWAP);
    assign weight_buf_rd_en   = (state == LOAD_WEIGHTS);
    assign weight_buf_rd_addr = count_reg[2:0];

    assign act_buf_rd_en      = (state == STREAM && count_reg < 8);
    assign act_buf_rd_addr    = count_reg[2:0];

    // Systolic Array Inputs
    reg                      sysarr_weight_load_en;
    reg [2:0]                sysarr_weight_load_row;
    reg [63:0]               sysarr_weight_load_data;
    reg [63:0]               sysarr_act_in;
    reg                      sysarr_act_valid;

    // Systolic Array Outputs
    wire [255:0]             sysarr_result_out;
    wire                     sysarr_result_valid;

    // ---- Readback Arrays ----
    reg signed [DATA_WIDTH-1:0] result_raw_mem [0:63];
    reg [DATA_WIDTH-1:0]        result_sat_mem [0:15];

    wire [5:0]               result_raw_addr;
    wire [3:0]               result_sat_addr;
    wire [DATA_WIDTH-1:0]    result_raw_rdata;
    wire [DATA_WIDTH-1:0]    result_sat_rdata;

    assign result_raw_rdata = result_raw_mem[result_raw_addr];
    assign result_sat_rdata = result_sat_mem[result_sat_addr];

    // ---- Unpack activation row data ----
    wire [7:0] act_row_data [0:7];
    generate
        for (genvar k = 0; k < 8; k = k + 1) begin : gen_unpack_act
            assign act_row_data[k] = act_buf_rd_data[k*8 +: 8];
        end
    endgenerate

    // ---- Activation delays ----
    reg [7:0] act_delay [0:7][0:7];
    integer r_idx, d_idx;
    always @(posedge aclk) begin
        if (!aresetn || ctrl_soft_reset) begin
            for (r_idx = 0; r_idx < 8; r_idx = r_idx + 1) begin
                for (d_idx = 0; d_idx < 8; d_idx = d_idx + 1) begin
                    act_delay[r_idx][d_idx] <= 8'h00;
                end
            end
        end else if (state == STREAM) begin
            for (r_idx = 0; r_idx < 8; r_idx = r_idx + 1) begin
                if (count_reg < 8) begin
                    act_delay[r_idx][0] <= act_row_data[r_idx];
                end else begin
                    act_delay[r_idx][0] <= 8'h00;
                end
                for (d_idx = 1; d_idx < 8; d_idx = d_idx + 1) begin
                    act_delay[r_idx][d_idx] <= act_delay[r_idx][d_idx-1];
                end
            end
        end
    end

    // ---- Drive Systolic Array Inputs ----
    always @(*) begin
        sysarr_weight_load_en   = 1'b0;
        sysarr_weight_load_row  = 3'd0;
        sysarr_weight_load_data = 64'd0;
        sysarr_act_in           = 64'd0;
        sysarr_act_valid        = 1'b0;

        if (state == LOAD_WEIGHTS) begin
            sysarr_weight_load_en   = 1'b1;
            sysarr_weight_load_row  = count_reg[2:0];
            sysarr_weight_load_data = weight_buf_rd_data;
        end else if (state == STREAM) begin
            sysarr_act_valid = (count_reg < 15);
            for (integer k = 0; k < 8; k = k + 1) begin
                if (k == 0) begin
                    sysarr_act_in[0*8 +: 8] = (count_reg < 8) ? act_row_data[0] : 8'h00;
                end else begin
                    sysarr_act_in[k*8 +: 8] = act_delay[k][k-1];
                end
            end
        end
    end

    // ---- FSM Transitions ----
    always @(posedge aclk) begin
        if (!aresetn || ctrl_soft_reset) begin
            state       <= IDLE;
            count_reg   <= 5'd0;
            status_busy <= 1'b0;
            status_done <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    status_busy <= 1'b0;
                    if (ctrl_start) begin
                        state       <= SWAP;
                        status_done <= 1'b0;
                        count_reg   <= 5'd0;
                    end
                end

                SWAP: begin
                    status_busy <= 1'b1;
                    state       <= LOAD_WEIGHTS;
                    count_reg   <= 5'd0;
                end

                LOAD_WEIGHTS: begin
                    status_busy <= 1'b1;
                    if (count_reg == 7) begin
                        state     <= STREAM;
                        count_reg <= 5'd0;
                    end else begin
                        count_reg <= count_reg + 5'd1;
                    end
                end

                STREAM: begin
                    status_busy <= 1'b1;
                    if (count_reg == 22) begin
                        state       <= DONE;
                        count_reg   <= 5'd0;
                    end else begin
                        count_reg <= count_reg + 5'd1;
                    end
                end

                DONE: begin
                    status_busy <= 1'b0;
                    status_done <= 1'b1;
                    if (ctrl_start) begin
                        state       <= SWAP;
                        status_done <= 1'b0;
                        count_reg   <= 5'd0;
                    end
                end
            endcase
        end
    end

    // ---- Unpack Col Output ----
    wire [ACC_WIDTH-1:0] col_result [0:7];
    generate
        for (genvar c = 0; c < 8; c = c + 1) begin : gen_col_result
            assign col_result[c] = sysarr_result_out[c*ACC_WIDTH +: ACC_WIDTH];
        end
    endgenerate

    // ---- Saturation clamp ----
    function [7:0] saturate;
        input signed [ACC_WIDTH-1:0] val;
        localparam signed [ACC_WIDTH-1:0] SAT_MAX = 127;
        localparam signed [ACC_WIDTH-1:0] SAT_MIN = -128;
        begin
            saturate = (val > SAT_MAX) ? 8'sd127 :
                       (val < SAT_MIN) ? -8'sd128 :
                       val[7:0];
        end
    endfunction

    // ---- Capture Results ----
    integer c_i;
    integer r_i;
    always @(posedge aclk) begin
        if (!aresetn || ctrl_soft_reset) begin
            for (c_i = 0; c_i < 64; c_i = c_i + 1) begin
                result_raw_mem[c_i] <= 32'd0;
            end
            for (c_i = 0; c_i < 16; c_i = c_i + 1) begin
                result_sat_mem[c_i] <= 32'd0;
            end
        end else if (state == STREAM) begin
            for (c_i = 0; c_i < 8; c_i = c_i + 1) begin
                r_i = count_reg - 8 - c_i;
                if (r_i >= 0 && r_i < 8) begin
                    result_raw_mem[r_i * 8 + c_i] <= col_result[c_i];
                    case ((r_i * 8 + c_i) % 4)
                        0: result_sat_mem[(r_i * 8 + c_i) / 4][7:0]   <= saturate(col_result[c_i]);
                        1: result_sat_mem[(r_i * 8 + c_i) / 4][15:8]  <= saturate(col_result[c_i]);
                        2: result_sat_mem[(r_i * 8 + c_i) / 4][23:16] <= saturate(col_result[c_i]);
                        3: result_sat_mem[(r_i * 8 + c_i) / 4][31:24] <= saturate(col_result[c_i]);
                    endcase
                end
            end
        end
    end

    // ---- Instantiate AXI Slave ----
    axi_lite_slave #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) slave_inst (
        .aclk             (aclk),
        .aresetn          (aresetn),
        .s_axi_awaddr     (s_axi_awaddr),
        .s_axi_awvalid    (s_axi_awvalid),
        .s_axi_awready    (s_axi_awready),
        .s_axi_wdata      (s_axi_wdata),
        .s_axi_wstrb      (s_axi_wstrb),
        .s_axi_wvalid     (s_axi_wvalid),
        .s_axi_wready     (s_axi_wready),
        .s_axi_bresp      (s_axi_bresp),
        .s_axi_bvalid     (s_axi_bvalid),
        .s_axi_bready     (s_axi_bready),
        .s_axi_araddr     (s_axi_araddr),
        .s_axi_arvalid    (s_axi_arvalid),
        .s_axi_arready    (s_axi_arready),
        .s_axi_rdata      (s_axi_rdata),
        .s_axi_rresp      (s_axi_rresp),
        .s_axi_rvalid     (s_axi_rvalid),
        .s_axi_rready     (s_axi_rready),
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

    // ---- Instantiate Systolic Array ----
    systolic_array #(
        .N          (8),
        .DATA_WIDTH (8),
        .ACC_WIDTH  (32)
    ) sysarr (
        .clk              (aclk),
        .rst_n            (aresetn && !ctrl_soft_reset),
        .row_clk_en       (clk_gate_row_en),
        .col_clk_en       (clk_gate_col_en),
        .weight_load_en   (sysarr_weight_load_en),
        .weight_load_row  (sysarr_weight_load_row),
        .weight_load_data (sysarr_weight_load_data),
        .act_in           (sysarr_act_in),
        .act_valid        (sysarr_act_valid),
        .result_out       (sysarr_result_out),
        .result_valid     (sysarr_result_valid)
    );
endmodule
