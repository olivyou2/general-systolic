module bram#(
    parameter ADDR_WIDTH=9,
    parameter DATA_WIDTH=64
)(
    input logic clk,

    input logic [ADDR_WIDTH-1: 0] addr_in,
    input logic [DATA_WIDTH-1: 0] data_in,
    input logic we,

    input logic [ADDR_WIDTH-1: 0] addr_out,
    output logic [DATA_WIDTH-1: 0] data_out
);

    logic [DATA_WIDTH-1: 0] data[2**ADDR_WIDTH];

    always @(posedge clk) begin
        if (we) begin
            data[addr_in] <= data_in;
        end

        data_out <= data[addr_out];
    end

endmodule
