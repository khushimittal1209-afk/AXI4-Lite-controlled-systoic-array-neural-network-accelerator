//-----------------------------------------------------------------------------
// Module: accelerator_top
// Description: Top-level integration module.
//              Connects AXI4-Lite slave ↔ ping-pong buffers ↔ systolic array
//              ↔ result storage. Contains the compute-control FSM.
// Phase:  Stub created in Phase 0; logic added in Phase 5.
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

    // Phase 5 implementation placeholder

endmodule
