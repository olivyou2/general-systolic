// Two-entry ready/valid buffer used at every mesh-router input.
//
// in_ready depends only on registered occupancy.  Downstream ready therefore
// cannot propagate through a router and form a combinational loop around the
// torus.

module mesh_elastic_buffer #(
    parameter int ADDR_WIDTH = 40,
    parameter int DATA_WIDTH = 64
)(
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic [ADDR_WIDTH-1:0] addr_in,
    input  logic [DATA_WIDTH-1:0] data_in,
    input  logic                  valid_in,
    output logic                  ready_out,

    output logic [ADDR_WIDTH-1:0] addr_out,
    output logic [DATA_WIDTH-1:0] data_out,
    output logic                  valid_out,
    input  logic                  ready_in
);

    logic [ADDR_WIDTH-1:0] head_addr;
    logic [DATA_WIDTH-1:0] head_data;
    logic [ADDR_WIDTH-1:0] skid_addr;
    logic [DATA_WIDTH-1:0] skid_data;
    logic [1:0] occupancy;

    logic push;
    logic pop;

    assign ready_out = (occupancy != 2);
    assign valid_out = (occupancy != 0);
    assign addr_out = head_addr;
    assign data_out = head_data;

    assign push = valid_in && ready_out;
    assign pop = valid_out && ready_in;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_addr <= '0;
            head_data <= '0;
            skid_addr <= '0;
            skid_data <= '0;
            occupancy <= '0;
        end else begin
            case ({push, pop})
                2'b10: begin
                    if (occupancy == 0) begin
                        head_addr <= addr_in;
                        head_data <= data_in;
                    end else begin
                        skid_addr <= addr_in;
                        skid_data <= data_in;
                    end
                    occupancy <= occupancy + 1'b1;
                end

                2'b01: begin
                    if (occupancy == 2) begin
                        head_addr <= skid_addr;
                        head_data <= skid_data;
                    end
                    occupancy <= occupancy - 1'b1;
                end

                2'b11: begin
                    if (occupancy == 1) begin
                        head_addr <= addr_in;
                        head_data <= data_in;
                    end else begin
                        head_addr <= skid_addr;
                        head_data <= skid_data;
                        skid_addr <= addr_in;
                        skid_data <= data_in;
                    end
                end

                default: begin
                end
            endcase
        end
    end

endmodule
