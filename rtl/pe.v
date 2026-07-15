//-----------------------------------------------------------------------------
// Module: pe
// Description: Single Processing Element — INT8 weight-stationary MAC unit.
//
//   Stationary weight:   Loaded once via weight_load, held across cycles.
//   Accumulator:         32-bit signed, adds  weight × act_in  each enabled
//                        cycle (suppressed during weight-load).
//   Saturation:          result_sat clamps acc to [-128, +127].
//   Systolic outputs:    act_out  = act_in  delayed 1 cycle (pass-through).
//                        psum_out = psum_in + weight×act_in (registered,
//                                  for Phase 2 partial-sum chaining).
//
// Reset:  Active-low synchronous (rst_n).
// Clock gate: clk_en = 1 → enabled; clk_en = 0 → all registers hold.
//-----------------------------------------------------------------------------
module pe #(
    parameter DATA_WIDTH = 8,              // INT8 operand width
    parameter ACC_WIDTH  = 32              // Internal accumulator width
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          clk_en,

    // Weight load interface
    input  wire                          weight_load,   // Pulse to capture weight_in
    input  wire signed [DATA_WIDTH-1:0]  weight_in,

    // Accumulator control
    input  wire                          acc_clear,     // Pulse to zero the accumulator

    // Systolic dataflow
    input  wire signed [DATA_WIDTH-1:0]  act_in,        // Activation from left / input
    input  wire signed [ACC_WIDTH-1:0]   psum_in,       // Partial sum from above / zero
    output reg  signed [DATA_WIDTH-1:0]  act_out,       // Activation to right  (registered)
    output reg  signed [ACC_WIDTH-1:0]   psum_out,      // Partial sum to below (registered)

    // Result outputs
    output wire signed [ACC_WIDTH-1:0]   result_raw,    // Raw 32-bit accumulator
    output wire signed [DATA_WIDTH-1:0]  result_sat     // Saturated INT8
);

    // ---- Saturation bounds (parameterised) ----
    localparam signed [ACC_WIDTH-1:0] SAT_MAX =  (2**(DATA_WIDTH-1)) - 1;  // +127
    localparam signed [ACC_WIDTH-1:0] SAT_MIN = -(2**(DATA_WIDTH-1));       // -128

    // ---- Internal state ----
    reg signed [DATA_WIDTH-1:0] weight_reg;
    reg signed [ACC_WIDTH-1:0]  acc_reg;

    // ---- Signed product (context-widened to ACC_WIDTH by Verilog rules) ----
    wire signed [ACC_WIDTH-1:0] product;
    assign product = weight_reg * act_in;

    // ---- Weight register: latch when weight_load is asserted ----
    always @(posedge clk) begin
        if (!rst_n)
            weight_reg <= {DATA_WIDTH{1'b0}};
        else if (clk_en && weight_load)
            weight_reg <= weight_in;
    end

    // ---- Accumulator: MAC when enabled; clear on acc_clear;
    //      suppressed during weight_load to avoid stale-weight products ----
    always @(posedge clk) begin
        if (!rst_n)
            acc_reg <= {ACC_WIDTH{1'b0}};
        else if (clk_en) begin
            if (acc_clear)
                acc_reg <= {ACC_WIDTH{1'b0}};
            else if (!weight_load)
                acc_reg <= acc_reg + product;
        end
    end

    // ---- Activation pass-through (1-cycle systolic delay) ----
    always @(posedge clk) begin
        if (!rst_n)
            act_out <= {DATA_WIDTH{1'b0}};
        else if (clk_en)
            act_out <= act_in;
    end

    // ---- Partial-sum pass-through (registered, Phase 2 chaining) ----
    always @(posedge clk) begin
        if (!rst_n)
            psum_out <= {ACC_WIDTH{1'b0}};
        else if (clk_en && !weight_load)
            psum_out <= psum_in + product;
    end

    // ---- Raw accumulator output ----
    assign result_raw = acc_reg;

    // ---- Saturated INT8 output ----
    assign result_sat = (acc_reg > SAT_MAX) ? SAT_MAX[DATA_WIDTH-1:0] :
                        (acc_reg < SAT_MIN) ? SAT_MIN[DATA_WIDTH-1:0] :
                        acc_reg[DATA_WIDTH-1:0];

endmodule
