`timescale 1ns / 1ps

//-----------------------------------------------------------------------------
// Module: axi_lite_master_bfm
// Description: AXI4-Lite Master Bus Functional Model (testbench utility).
//              Provides task-based write/read procedures to drive the DUT's
//              AXI4-Lite slave interface from directed testbenches.
//-----------------------------------------------------------------------------
module axi_lite_master_bfm #(
    parameter ADDR_WIDTH = 10,         // Must match DUT's ADDR_WIDTH
    parameter DATA_WIDTH = 32          // Must match DUT's DATA_WIDTH
)(
    // ---- AXI global signals ----
    input  wire                        aclk,
    input  wire                        aresetn,

    // ---- AXI4-Lite Write Address Channel (master drives) ----
    output reg  [ADDR_WIDTH-1:0]       m_axi_awaddr,
    output reg                         m_axi_awvalid,
    input  wire                        m_axi_awready,

    // ---- AXI4-Lite Write Data Channel (master drives) ----
    output reg  [DATA_WIDTH-1:0]       m_axi_wdata,
    output reg  [(DATA_WIDTH/8)-1:0]   m_axi_wstrb,
    output reg                         m_axi_wvalid,
    input  wire                        m_axi_wready,

    // ---- AXI4-Lite Write Response Channel (master receives) ----
    input  wire [1:0]                  m_axi_bresp,
    input  wire                        m_axi_bvalid,
    output reg                         m_axi_bready,

    // ---- AXI4-Lite Read Address Channel (master drives) ----
    output reg  [ADDR_WIDTH-1:0]       m_axi_araddr,
    output reg                         m_axi_arvalid,
    input  wire                        m_axi_arready,

    // ---- AXI4-Lite Read Data Channel (master receives) ----
    input  wire [DATA_WIDTH-1:0]       m_axi_rdata,
    input  wire [1:0]                  m_axi_rresp,
    input  wire                        m_axi_rvalid,
    output reg                         m_axi_rready
);

    // Initialize all master-driven outputs
    initial begin
        m_axi_awaddr  = 0;
        m_axi_awvalid = 0;
        m_axi_wdata   = 0;
        m_axi_wstrb   = 0;
        m_axi_wvalid  = 0;
        m_axi_bready  = 0;
        m_axi_araddr  = 0;
        m_axi_arvalid = 0;
        m_axi_rready  = 0;
    end

    // ---- Standard AXI4-Lite Write Task ----
    task axi_write;
        input  [ADDR_WIDTH-1:0] addr;
        input  [DATA_WIDTH-1:0] data;
        output [1:0]            resp;
        reg                     aw_done;
        reg                     w_done;
        begin
            aw_done = 1'b0;
            w_done  = 1'b0;

            m_axi_awaddr  = addr;
            m_axi_awvalid = 1'b1;
            m_axi_wdata   = data;
            m_axi_wstrb   = {DATA_WIDTH/8{1'b1}}; // Write all byte lanes
            m_axi_wvalid  = 1'b1;

            while (!aw_done || !w_done) begin
                @(posedge aclk);
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awvalid = 1'b0;
                    aw_done       = 1'b1;
                end
                if (m_axi_wvalid && m_axi_wready) begin
                    m_axi_wvalid = 1'b0;
                    w_done       = 1'b1;
                end
            end

            m_axi_awaddr = 0;
            m_axi_wdata  = 0;
            m_axi_wstrb  = 0;

            // Wait for write response handshake
            m_axi_bready = 1'b1;
            @(posedge aclk);
            while (!m_axi_bvalid) begin
                @(posedge aclk);
            end
            resp         = m_axi_bresp;
            @(posedge aclk);      // Let slave see bready=1 in W_RESP
            m_axi_bready = 1'b0;
            @(posedge aclk);
        end
    endtask

    // ---- Skewed AXI4-Lite Write Task ----
    task axi_write_skewed;
        input  [ADDR_WIDTH-1:0] addr;
        input  [DATA_WIDTH-1:0] data;
        input                   addr_first; // 1 = address first, 0 = data first
        output [1:0]            resp;
        begin
            if (addr_first) begin
                // 1. Drive Address first
                m_axi_awaddr  = addr;
                m_axi_awvalid = 1'b1;
                @(posedge aclk);
                while (!m_axi_awready) begin
                    @(posedge aclk);
                end
                m_axi_awvalid = 1'b0;
                m_axi_awaddr  = 0;

                // Wait a clock cycle
                @(posedge aclk);

                // 2. Drive Data
                m_axi_wdata  = data;
                m_axi_wstrb  = {DATA_WIDTH/8{1'b1}};
                m_axi_wvalid = 1'b1;
                @(posedge aclk);
                while (!m_axi_wready) begin
                    @(posedge aclk);
                end
                m_axi_wvalid = 1'b0;
                m_axi_wdata  = 0;
                m_axi_wstrb  = 0;
            end else begin
                // 1. Drive Data first
                m_axi_wdata  = data;
                m_axi_wstrb  = {DATA_WIDTH/8{1'b1}};
                m_axi_wvalid = 1'b1;
                @(posedge aclk);
                while (!m_axi_wready) begin
                    @(posedge aclk);
                end
                m_axi_wvalid = 1'b0;
                m_axi_wdata  = 0;
                m_axi_wstrb  = 0;

                // Wait a clock cycle
                @(posedge aclk);

                // 2. Drive Address
                m_axi_awaddr  = addr;
                m_axi_awvalid = 1'b1;
                @(posedge aclk);
                while (!m_axi_awready) begin
                    @(posedge aclk);
                end
                m_axi_awvalid = 1'b0;
                m_axi_awaddr  = 0;
            end

            // Wait for response
            m_axi_bready = 1'b1;
            @(posedge aclk);
            while (!m_axi_bvalid) begin
                @(posedge aclk);
            end
            resp         = m_axi_bresp;
            @(posedge aclk);      // Let slave see bready=1 in W_RESP
            m_axi_bready = 1'b0;
            @(posedge aclk);
        end
    endtask

    // ---- Standard AXI4-Lite Read Task ----
    task axi_read;
        input  [ADDR_WIDTH-1:0] addr;
        output [DATA_WIDTH-1:0] returned_data;
        output [1:0]            resp;
        begin
            m_axi_araddr  = addr;
            m_axi_arvalid = 1'b1;

            @(posedge aclk);
            while (!m_axi_arready) begin
                @(posedge aclk);
            end
            m_axi_arvalid = 1'b0;
            m_axi_araddr  = 0;

            // Wait for read data valid (RVALID)
            m_axi_rready = 1'b1;
            @(posedge aclk);
            while (!m_axi_rvalid) begin
                @(posedge aclk);
            end
            returned_data = m_axi_rdata;
            resp          = m_axi_rresp;
            @(posedge aclk);      // Let slave see rready=1 in R_RESP
            m_axi_rready  = 1'b0;
            @(posedge aclk);
        end
    endtask

endmodule
