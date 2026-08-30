// Register slice for the window descriptors produced by window_loop.
//
// Keeping this storage separate avoids exposing a many-kilobit combinational
// array to the launcher. Only one descriptor is written per setup clock and
// all descriptors are stable throughout the K loop.
module window_generator #(
    parameter int WINDOWS = 8
)(
    input  logic clk,
    input  logic rst_n,
    input  logic capture,
    input  logic [(WINDOWS > 1 ? $clog2(WINDOWS) : 1)-1:0] window_index,
    input  logic signed [31:0] window_x_in,
    input  logic signed [31:0] window_y_in,
    input  logic signed [47:0] spatial_index_in,
    input  logic output_valid_in,
    output logic signed [WINDOWS-1:0][31:0] window_x,
    output logic signed [WINDOWS-1:0][31:0] window_y,
    output logic signed [WINDOWS-1:0][47:0] spatial_index,
    output logic        [WINDOWS-1:0]       output_valid
);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            window_x <= '0;
            window_y <= '0;
            spatial_index <= '0;
            output_valid <= '0;
        end else if (capture) begin
            window_x[window_index] <= window_x_in;
            window_y[window_index] <= window_y_in;
            spatial_index[window_index] <= spatial_index_in;
            output_valid[window_index] <= output_valid_in;
        end
    end

    initial begin
        if (WINDOWS < 1) $error("window_generator requires at least one window");
    end
endmodule
