// Parameterized unidirectional torus mesh.
//
// The default is a 16x16 grid with two independent channels per direction.
// Routers receive from west/north and transmit to east/south.  The last column
// wraps to column zero and the last row wraps to row zero.
//
// NODE_ENABLE_MASK is indexed as (y * MESH_X + x).  It is a compile-time
// parameter rather than a runtime enable.  Disabled positions retain only the
// transit router needed to preserve torus connectivity; their local injection
// buffer and endpoint delivery logic are absent, and packets addressed to such
// a position are discarded.

module torus_mesh #(
    parameter int ADDR_WIDTH = 40,
    parameter int DATA_WIDTH = 64,
    parameter int CHANNELS = 2,
    parameter int MESH_X = 16,
    parameter int MESH_Y = 16,
    parameter logic [MESH_X*MESH_Y-1:0] NODE_ENABLE_MASK = '1
)(
    input logic clk,
    input logic rst_n,

    input logic [ADDR_WIDTH-1:0]
        local_addr_in [0:MESH_X*MESH_Y-1][0:CHANNELS-1],
    input logic [DATA_WIDTH-1:0]
        local_data_in [0:MESH_X*MESH_Y-1][0:CHANNELS-1],
    input logic
        local_valid_in [0:MESH_X*MESH_Y-1][0:CHANNELS-1],
    output logic
        local_ready_out [0:MESH_X*MESH_Y-1][0:CHANNELS-1],

    output logic [ADDR_WIDTH-1:0]
        local_addr_out [0:MESH_X*MESH_Y-1][0:CHANNELS-1],
    output logic [DATA_WIDTH-1:0]
        local_data_out [0:MESH_X*MESH_Y-1][0:CHANNELS-1],
    output logic
        local_valid_out [0:MESH_X*MESH_Y-1][0:CHANNELS-1],
    input logic
        local_ready_in [0:MESH_X*MESH_Y-1][0:CHANNELS-1]
);

    logic [ADDR_WIDTH-1:0]
        east_addr [0:MESH_Y-1][0:MESH_X-1][0:CHANNELS-1];
    logic [DATA_WIDTH-1:0]
        east_data [0:MESH_Y-1][0:MESH_X-1][0:CHANNELS-1];
    logic east_valid [0:MESH_Y-1][0:MESH_X-1][0:CHANNELS-1];
    logic east_ready [0:MESH_Y-1][0:MESH_X-1][0:CHANNELS-1];

    logic [ADDR_WIDTH-1:0]
        south_addr [0:MESH_Y-1][0:MESH_X-1][0:CHANNELS-1];
    logic [DATA_WIDTH-1:0]
        south_data [0:MESH_Y-1][0:MESH_X-1][0:CHANNELS-1];
    logic south_valid [0:MESH_Y-1][0:MESH_X-1][0:CHANNELS-1];
    logic south_ready [0:MESH_Y-1][0:MESH_X-1][0:CHANNELS-1];

    generate
        for (genvar y = 0; y < MESH_Y; y++) begin : rows
            for (genvar x = 0; x < MESH_X; x++) begin : columns
                localparam int NODE_INDEX = y * MESH_X + x;
                localparam int WEST_X = (x == 0) ? MESH_X - 1 : x - 1;
                localparam int NORTH_Y = (y == 0) ? MESH_Y - 1 : y - 1;

                torus_mesh_router #(
                    .ADDR_WIDTH  (ADDR_WIDTH),
                    .DATA_WIDTH  (DATA_WIDTH),
                    .CHANNELS    (CHANNELS),
                    .MESH_X      (MESH_X),
                    .MESH_Y      (MESH_Y),
                    .X_COORD     (x),
                    .Y_COORD     (y),
                    .LOCAL_ENABLE(NODE_ENABLE_MASK[NODE_INDEX])
                ) router (
                    .clk            (clk),
                    .rst_n          (rst_n),

                    .west_addr_in   (east_addr[y][WEST_X]),
                    .west_data_in   (east_data[y][WEST_X]),
                    .west_valid_in  (east_valid[y][WEST_X]),
                    .west_ready_out (east_ready[y][WEST_X]),

                    .north_addr_in  (south_addr[NORTH_Y][x]),
                    .north_data_in  (south_data[NORTH_Y][x]),
                    .north_valid_in (south_valid[NORTH_Y][x]),
                    .north_ready_out(south_ready[NORTH_Y][x]),

                    .east_addr_out  (east_addr[y][x]),
                    .east_data_out  (east_data[y][x]),
                    .east_valid_out (east_valid[y][x]),
                    .east_ready_in  (east_ready[y][x]),

                    .south_addr_out (south_addr[y][x]),
                    .south_data_out (south_data[y][x]),
                    .south_valid_out(south_valid[y][x]),
                    .south_ready_in (south_ready[y][x]),

                    .local_addr_in  (local_addr_in[NODE_INDEX]),
                    .local_data_in  (local_data_in[NODE_INDEX]),
                    .local_valid_in (local_valid_in[NODE_INDEX]),
                    .local_ready_out(local_ready_out[NODE_INDEX]),
                    .local_addr_out (local_addr_out[NODE_INDEX]),
                    .local_data_out (local_data_out[NODE_INDEX]),
                    .local_valid_out(local_valid_out[NODE_INDEX]),
                    .local_ready_in (local_ready_in[NODE_INDEX])
                );
            end
        end
    endgenerate

    initial begin
        if ((MESH_X < 1) || (MESH_Y < 1)) begin
            $error("Mesh dimensions must be at least one");
        end
    end

endmodule
