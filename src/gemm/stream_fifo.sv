module stream_fifo #(
    parameter data_width = 256,
    parameter depth = 4
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [data_width-1:0] data_in,
    input  logic valid_in,
    output wire ready_out,

    output wire [data_width-1:0] data_out,
    output wire valid_out,
    input  logic ready_in
);
    localparam int pointer_width = (depth > 1) ? $clog2(depth) : 1;
    localparam int count_width = $clog2(depth + 1);

    logic [data_width-1:0] memory [0:depth-1];
    logic [pointer_width-1:0] write_pointer;
    logic [pointer_width-1:0] read_pointer;
    logic [count_width-1:0] occupancy;
    wire push = valid_in && ready_out;
    wire pop = valid_out && ready_in;

    assign ready_out = (occupancy < depth);
    assign valid_out = (occupancy != 0);
    assign data_out = memory[read_pointer];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_pointer <= '0;
            read_pointer <= '0;
            occupancy <= '0;
        end else begin
            if (push) begin
                memory[write_pointer] <= data_in;
                if (write_pointer == depth - 1) begin
                    write_pointer <= '0;
                end else begin
                    write_pointer <= write_pointer + 1'b1;
                end
            end

            if (pop) begin
                if (read_pointer == depth - 1) begin
                    read_pointer <= '0;
                end else begin
                    read_pointer <= read_pointer + 1'b1;
                end
            end

            case ({push, pop})
                2'b10: occupancy <= occupancy + 1'b1;
                2'b01: occupancy <= occupancy - 1'b1;
                default: occupancy <= occupancy;
            endcase
        end
    end

endmodule
