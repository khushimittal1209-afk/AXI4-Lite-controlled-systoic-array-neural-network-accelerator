//-----------------------------------------------------------------------------
// Module: systolic_array
// Description: N×N weight-stationary systolic PE grid.
//              Activations flow left-to-right (west-to-east).
//              Partial sums flow top-to-bottom (north-to-south).
//              Weights are pre-loaded row-by-row.
//              Each PE[r][c] is clock-enabled by: row_clk_en[r] && col_clk_en[c].
//-----------------------------------------------------------------------------
module systolic_array #(
    parameter N          = 8,          // Grid dimension (N×N PEs)
    parameter DATA_WIDTH = 8,          // INT8 operand width
    parameter ACC_WIDTH  = 32          // Accumulator width
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Per-row / per-column clock-gate enables (active-high = enabled)
    input  wire [N-1:0]                 row_clk_en,
    input  wire [N-1:0]                 col_clk_en,

    // Weight load interface (row-by-row loading)
    input  wire                         weight_load_en,              // Assert to load one row
    input  wire [$clog2(N)-1:0]         weight_load_row,             // Target row index
    input  wire [N*DATA_WIDTH-1:0]      weight_load_data,            // N packed INT8 weights for that row

    // Activation input (one INT8 value per row, fed into column 0)
    input  wire [N*DATA_WIDTH-1:0]      act_in,                      // Packed: row[N-1] … row[0]
    input  wire                         act_valid,                   // Activations valid this cycle

    // Result output (partial sums leaving bottom row, one per column)
    output wire [N*ACC_WIDTH-1:0]       result_out,                  // Packed: col[N-1] … col[0]
    output wire                         result_valid                 // Results valid flag
);

    // ---- Internal 2D arrays for chaining PEs ----
    // Activation connections: act_conn[r][c] is the activation leaving column c-1 (entering column c)
    // There are N rows, and N+1 activation boundaries (0 to N)
    wire signed [DATA_WIDTH-1:0] act_conn [0:N-1][0:N];

    // Partial sum connections: psum_conn[r][c] is the partial sum leaving row r-1 (entering row r)
    // There are N columns, and N+1 partial sum boundaries (0 to N)
    wire signed [ACC_WIDTH-1:0]  psum_conn[0:N][0:N-1];

    // ---- West boundary: activations entering column 0 ----
    genvar r, c;
    generate
        for (r = 0; r < N; r = r + 1) begin : gen_west_boundary
            // Activations enter column 0 if act_valid is asserted, otherwise 0 to prevent spurious accumulation
            assign act_conn[r][0] = act_valid ? act_in[r*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}};
        end
    endgenerate

    // ---- North boundary: partial sums entering row 0 ----
    generate
        for (c = 0; c < N; c = c + 1) begin : gen_north_boundary
            assign psum_conn[0][c] = {ACC_WIDTH{1'b0}}; // northernmost boundary tied to 0
        end
    endgenerate

    // ---- Instantiate 2D PE Grid ----
    generate
        for (r = 0; r < N; r = r + 1) begin : gen_pe_row
            for (c = 0; c < N; c = c + 1) begin : gen_pe_col
                // Clock gating control for this PE
                wire pe_clk_en = row_clk_en[r] && col_clk_en[c];

                // Weight load controls for this PE
                wire pe_weight_load = weight_load_en && (weight_load_row == r);
                wire [DATA_WIDTH-1:0] pe_weight_in = weight_load_data[c*DATA_WIDTH +: DATA_WIDTH];

                pe #(
                    .DATA_WIDTH (DATA_WIDTH),
                    .ACC_WIDTH  (ACC_WIDTH)
                ) u_pe (
                    .clk         (clk),
                    .rst_n       (rst_n),
                    .clk_en      (pe_clk_en),
                    .weight_load (pe_weight_load),
                    .weight_in   (pe_weight_in),
                    .acc_clear   (1'b0), // Not using local accumulator clear in systolic grid mode
                    .act_in      (act_conn[r][c]),
                    .psum_in     (psum_conn[r][c]),
                    .act_out     (act_conn[r][c+1]),
                    .psum_out    (psum_conn[r+1][c]),
                    .result_raw  (), // local accumulator raw output unused in systolic grid mode
                    .result_sat  ()  // local accumulator saturated output unused in systolic grid mode
                );
            end
        end
    endgenerate

    // ---- South boundary: results leaving row N-1 ----
    generate
        for (c = 0; c < N; c = c + 1) begin : gen_south_boundary
            assign result_out[c*ACC_WIDTH +: ACC_WIDTH] = psum_conn[N][c];
        end
    endgenerate

    // ---- Result Valid Propagation ----
    // To generate a simple result_valid, we delay act_valid.
    // The first result element (row 0, col 0) takes N cycles to exit the bottom of col 0.
    // Specifically, act_valid entering at cycle t will propagate through the array.
    // Let's create a shift register of length N+N (or similar) to track when outputs are valid.
    // A simple shift register of depth 2*N (16 cycles) covers the pipeline latency.
    reg [2*N-1:0] valid_shifter;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_shifter <= 0;
        end else begin
            valid_shifter <= {valid_shifter[2*N-2:0], act_valid};
        end
    end

    // The results start becoming valid at cycle N, and are completely finished at cycle 2*N-1.
    // For this module, we can define result_valid to be high if any valid results are flowing out.
    // Specifically, if the pipeline has valid data in its final stages.
    // Let's set result_valid to be the delayed act_valid by N cycles (when column 0 results start exiting).
    assign result_valid = valid_shifter[N-1];

endmodule
