module output_scratchpad #(
    parameter vector_lanes = 8,
    parameter element_width = 32,
    parameter depth = 64
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [vector_lanes*element_width-1:0] write_data_in,
    input  logic write_valid_in,
    output wire write_ready_out,

    output wire [vector_lanes*element_width-1:0] stream_data_out,
    output wire stream_valid_out,
    input  logic stream_ready_in
);
    stream_fifo #(
        .data_width(vector_lanes * element_width),
        .depth(depth)
    ) storage (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(write_data_in),
        .valid_in(write_valid_in),
        .ready_out(write_ready_out),
        .data_out(stream_data_out),
        .valid_out(stream_valid_out),
        .ready_in(stream_ready_in)
    );

endmodule
