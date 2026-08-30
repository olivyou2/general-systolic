// East/south dimension-ordered router for a unidirectional torus.
//
// Address layout for the default 16x16 mesh:
//   addr[39:36] : destination X
//   addr[35:32] : destination Y
//   addr[31:0]  : endpoint-defined address/tag
//
// Each physical direction has CHANNELS independent ready/valid channels.
// A channel never crosses into another channel.  West, north, and optional
// local traffic are arbitrated independently for east, south, and local
// outputs.  Input elastic buffers break all ready chains.

module torus_mesh_router #(
    parameter int ADDR_WIDTH = 40,
    parameter int DATA_WIDTH = 64,
    parameter int CHANNELS = 2,
    parameter int MESH_X = 16,
    parameter int MESH_Y = 16,
    parameter int X_COORD = 0,
    parameter int Y_COORD = 0,
    // This must be a constant parameter.  When zero, the local input buffer
    // and endpoint delivery path are removed by generate-time elaboration.
    parameter bit LOCAL_ENABLE = 1'b1
)(
    input logic clk,
    input logic rst_n,

    input  logic [ADDR_WIDTH-1:0] west_addr_in [0:CHANNELS-1],
    input  logic [DATA_WIDTH-1:0] west_data_in [0:CHANNELS-1],
    input  logic                  west_valid_in [0:CHANNELS-1],
    output logic                  west_ready_out [0:CHANNELS-1],

    input  logic [ADDR_WIDTH-1:0] north_addr_in [0:CHANNELS-1],
    input  logic [DATA_WIDTH-1:0] north_data_in [0:CHANNELS-1],
    input  logic                  north_valid_in [0:CHANNELS-1],
    output logic                  north_ready_out [0:CHANNELS-1],

    output logic [ADDR_WIDTH-1:0] east_addr_out [0:CHANNELS-1],
    output logic [DATA_WIDTH-1:0] east_data_out [0:CHANNELS-1],
    output logic                  east_valid_out [0:CHANNELS-1],
    input  logic                  east_ready_in [0:CHANNELS-1],

    output logic [ADDR_WIDTH-1:0] south_addr_out [0:CHANNELS-1],
    output logic [DATA_WIDTH-1:0] south_data_out [0:CHANNELS-1],
    output logic                  south_valid_out [0:CHANNELS-1],
    input  logic                  south_ready_in [0:CHANNELS-1],

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [ADDR_WIDTH-1:0] local_addr_in [0:CHANNELS-1],
    input  logic [DATA_WIDTH-1:0] local_data_in [0:CHANNELS-1],
    input  logic                  local_valid_in [0:CHANNELS-1],
    /* verilator lint_on UNUSEDSIGNAL */
    output logic                  local_ready_out [0:CHANNELS-1],

    output logic [ADDR_WIDTH-1:0] local_addr_out [0:CHANNELS-1],
    output logic [DATA_WIDTH-1:0] local_data_out [0:CHANNELS-1],
    output logic                  local_valid_out [0:CHANNELS-1],
    input  logic                  local_ready_in [0:CHANNELS-1]
);

    localparam int X_BITS = (MESH_X > 1) ? $clog2(MESH_X) : 1;
    localparam int Y_BITS = (MESH_Y > 1) ? $clog2(MESH_Y) : 1;
    localparam int INPUTS = 3;
    localparam int OUTPUTS = 3;
    localparam int INPUT_SEL_WIDTH = $clog2(INPUTS);

    localparam logic [1:0] ROUTE_EAST  = 2'd0;
    localparam logic [1:0] ROUTE_SOUTH = 2'd1;
    localparam logic [1:0] ROUTE_LOCAL = 2'd2;
    localparam logic [1:0] ROUTE_DROP  = 2'd3;

    localparam int WEST_SOURCE = 0;
    localparam int NORTH_SOURCE = 1;
    localparam int LOCAL_SOURCE = 2;

    logic [ADDR_WIDTH-1:0] source_addr [0:INPUTS-1][0:CHANNELS-1];
    logic [DATA_WIDTH-1:0] source_data [0:INPUTS-1][0:CHANNELS-1];
    logic source_valid [0:INPUTS-1][0:CHANNELS-1];
    logic source_consume [0:INPUTS-1][0:CHANNELS-1];
    logic [1:0] source_route [0:INPUTS-1][0:CHANNELS-1];

    logic [ADDR_WIDTH-1:0] output_addr [0:OUTPUTS-1][0:CHANNELS-1];
    logic [DATA_WIDTH-1:0] output_data [0:OUTPUTS-1][0:CHANNELS-1];
    logic output_valid [0:OUTPUTS-1][0:CHANNELS-1];
    logic output_ready [0:OUTPUTS-1][0:CHANNELS-1];

    logic grant_valid [0:OUTPUTS-1][0:CHANNELS-1];
    logic [INPUT_SEL_WIDTH-1:0] grant_source [0:OUTPUTS-1][0:CHANNELS-1];
    logic [INPUT_SEL_WIDTH:0] arbitration_choice [0:OUTPUTS-1][0:CHANNELS-1];
    logic grant_locked [0:OUTPUTS-1][0:CHANNELS-1];
    logic [INPUT_SEL_WIDTH-1:0] locked_source [0:OUTPUTS-1][0:CHANNELS-1];
    logic [INPUT_SEL_WIDTH-1:0] round_robin_start [0:OUTPUTS-1][0:CHANNELS-1];

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [1:0] route_address(
        input logic [ADDR_WIDTH-1:0] address
    );
        logic [X_BITS-1:0] destination_x;
        logic [Y_BITS-1:0] destination_y;
        begin
            destination_x = address[ADDR_WIDTH-1 -: X_BITS];
            destination_y = address[ADDR_WIDTH-X_BITS-1 -: Y_BITS];

            if (destination_x != X_BITS'(X_COORD)) begin
                route_address = ROUTE_EAST;
            end else if (destination_y != Y_BITS'(Y_COORD)) begin
                route_address = ROUTE_SOUTH;
            end else if (LOCAL_ENABLE) begin
                route_address = ROUTE_LOCAL;
            end else begin
                // A packet addressed to a disabled endpoint is consumed here
                // instead of circulating forever around the torus.
                route_address = ROUTE_DROP;
            end
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    function automatic logic [INPUT_SEL_WIDTH:0] choose_grant(
        input logic [INPUT_SEL_WIDTH-1:0] start,
        input logic request_0,
        input logic request_1,
        input logic request_2
    );
        begin
            choose_grant = '0;
            case (start)
                INPUT_SEL_WIDTH'(0): begin
                    if (request_0)
                        choose_grant = {1'b1, INPUT_SEL_WIDTH'(0)};
                    else if (request_1)
                        choose_grant = {1'b1, INPUT_SEL_WIDTH'(1)};
                    else if (request_2)
                        choose_grant = {1'b1, INPUT_SEL_WIDTH'(2)};
                end
                INPUT_SEL_WIDTH'(1): begin
                    if (request_1)
                        choose_grant = {1'b1, INPUT_SEL_WIDTH'(1)};
                    else if (request_2)
                        choose_grant = {1'b1, INPUT_SEL_WIDTH'(2)};
                    else if (request_0)
                        choose_grant = {1'b1, INPUT_SEL_WIDTH'(0)};
                end
                default: begin
                    if (request_2)
                        choose_grant = {1'b1, INPUT_SEL_WIDTH'(2)};
                    else if (request_0)
                        choose_grant = {1'b1, INPUT_SEL_WIDTH'(0)};
                    else if (request_1)
                        choose_grant = {1'b1, INPUT_SEL_WIDTH'(1)};
                end
            endcase
        end
    endfunction

    generate
        for (genvar channel = 0; channel < CHANNELS; channel++) begin : inputs
            mesh_elastic_buffer #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH)
            ) west_buffer (
                .clk      (clk),
                .rst_n    (rst_n),
                .addr_in  (west_addr_in[channel]),
                .data_in  (west_data_in[channel]),
                .valid_in (west_valid_in[channel]),
                .ready_out(west_ready_out[channel]),
                .addr_out (source_addr[WEST_SOURCE][channel]),
                .data_out (source_data[WEST_SOURCE][channel]),
                .valid_out(source_valid[WEST_SOURCE][channel]),
                .ready_in (source_consume[WEST_SOURCE][channel])
            );

            mesh_elastic_buffer #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH)
            ) north_buffer (
                .clk      (clk),
                .rst_n    (rst_n),
                .addr_in  (north_addr_in[channel]),
                .data_in  (north_data_in[channel]),
                .valid_in (north_valid_in[channel]),
                .ready_out(north_ready_out[channel]),
                .addr_out (source_addr[NORTH_SOURCE][channel]),
                .data_out (source_data[NORTH_SOURCE][channel]),
                .valid_out(source_valid[NORTH_SOURCE][channel]),
                .ready_in (source_consume[NORTH_SOURCE][channel])
            );

            if (LOCAL_ENABLE) begin : enabled_local_port
                mesh_elastic_buffer #(
                    .ADDR_WIDTH(ADDR_WIDTH),
                    .DATA_WIDTH(DATA_WIDTH)
                ) local_buffer (
                    .clk      (clk),
                    .rst_n    (rst_n),
                    .addr_in  (local_addr_in[channel]),
                    .data_in  (local_data_in[channel]),
                    .valid_in (local_valid_in[channel]),
                    .ready_out(local_ready_out[channel]),
                    .addr_out (source_addr[LOCAL_SOURCE][channel]),
                    .data_out (source_data[LOCAL_SOURCE][channel]),
                    .valid_out(source_valid[LOCAL_SOURCE][channel]),
                    .ready_in (source_consume[LOCAL_SOURCE][channel])
                );
            end else begin : disabled_local_port
                always_comb begin
                    local_ready_out[channel] = 1'b0;
                    source_addr[LOCAL_SOURCE][channel] = '0;
                    source_data[LOCAL_SOURCE][channel] = '0;
                    source_valid[LOCAL_SOURCE][channel] = 1'b0;
                end
            end
        end
    endgenerate

    always_comb begin
        for (int channel = 0; channel < CHANNELS; channel++) begin
            east_addr_out[channel] = '0;
            east_data_out[channel] = '0;
            east_valid_out[channel] = 1'b0;
            south_addr_out[channel] = '0;
            south_data_out[channel] = '0;
            south_valid_out[channel] = 1'b0;
            local_addr_out[channel] = '0;
            local_data_out[channel] = '0;
            local_valid_out[channel] = 1'b0;

            for (int source = 0; source < INPUTS; source++) begin
                source_route[source][channel] = ROUTE_DROP;
                if (source_valid[source][channel]) begin
                    source_route[source][channel]
                        = route_address(source_addr[source][channel]);
                end
                source_consume[source][channel]
                    = source_valid[source][channel]
                      && (source_route[source][channel] == ROUTE_DROP);
            end

            for (int output_index = 0;
                 output_index < OUTPUTS; output_index++) begin
                output_addr[output_index][channel] = '0;
                output_data[output_index][channel] = '0;
                output_valid[output_index][channel] = 1'b0;
                output_ready[output_index][channel] = 1'b0;
                grant_valid[output_index][channel] = 1'b0;
                grant_source[output_index][channel] = '0;
                arbitration_choice[output_index][channel]
                    = choose_grant(
                        round_robin_start[output_index][channel],
                        source_valid[0][channel]
                            && (source_route[0][channel] == 2'(output_index)),
                        source_valid[1][channel]
                            && (source_route[1][channel] == 2'(output_index)),
                        source_valid[2][channel]
                            && (source_route[2][channel] == 2'(output_index))
                    );

                case (output_index)
                    0:
                        output_ready[output_index][channel]
                            = east_ready_in[channel];
                    1:
                        output_ready[output_index][channel]
                            = south_ready_in[channel];
                    default:
                        output_ready[output_index][channel]
                            = LOCAL_ENABLE && local_ready_in[channel];
                endcase

                if (grant_locked[output_index][channel]) begin
                    grant_source[output_index][channel]
                        = locked_source[output_index][channel];
                    grant_valid[output_index][channel]
                        = source_valid[locked_source[output_index][channel]][channel]
                          && (source_route[locked_source[output_index][channel]][channel]
                              == 2'(output_index));
                end else begin
                    grant_valid[output_index][channel]
                        = arbitration_choice[output_index][channel]
                          [INPUT_SEL_WIDTH];
                    grant_source[output_index][channel]
                        = arbitration_choice[output_index][channel]
                          [INPUT_SEL_WIDTH-1:0];
                end

                output_valid[output_index][channel]
                    = grant_valid[output_index][channel];

                if (grant_valid[output_index][channel]) begin
                    output_addr[output_index][channel]
                        = source_addr[grant_source[output_index][channel]][channel];
                    output_data[output_index][channel]
                        = source_data[grant_source[output_index][channel]][channel];
                    if (output_ready[output_index][channel]) begin
                        source_consume[grant_source[output_index][channel]][channel]
                            = 1'b1;
                    end
                end
            end

            east_addr_out[channel] = output_addr[ROUTE_EAST][channel];
            east_data_out[channel] = output_data[ROUTE_EAST][channel];
            east_valid_out[channel] = output_valid[ROUTE_EAST][channel];
            south_addr_out[channel] = output_addr[ROUTE_SOUTH][channel];
            south_data_out[channel] = output_data[ROUTE_SOUTH][channel];
            south_valid_out[channel] = output_valid[ROUTE_SOUTH][channel];

            if (LOCAL_ENABLE) begin
                local_addr_out[channel] = output_addr[ROUTE_LOCAL][channel];
                local_data_out[channel] = output_data[ROUTE_LOCAL][channel];
                local_valid_out[channel] = output_valid[ROUTE_LOCAL][channel];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int output_index = 0;
                 output_index < OUTPUTS; output_index++) begin
                for (int channel = 0; channel < CHANNELS; channel++) begin
                    grant_locked[output_index][channel] <= 1'b0;
                    locked_source[output_index][channel] <= '0;
                    round_robin_start[output_index][channel] <= '0;
                end
            end
        end else begin
            for (int output_index = 0;
                 output_index < OUTPUTS; output_index++) begin
                for (int channel = 0; channel < CHANNELS; channel++) begin
                    if (output_valid[output_index][channel]
                        && !output_ready[output_index][channel]
                        && !grant_locked[output_index][channel]) begin
                        grant_locked[output_index][channel] <= 1'b1;
                        locked_source[output_index][channel]
                            <= grant_source[output_index][channel];
                    end else if (output_valid[output_index][channel]
                                 && output_ready[output_index][channel]) begin
                        grant_locked[output_index][channel] <= 1'b0;
                        if (grant_source[output_index][channel]
                            == INPUT_SEL_WIDTH'(INPUTS - 1)) begin
                            round_robin_start[output_index][channel] <= '0;
                        end else begin
                            round_robin_start[output_index][channel]
                                <= grant_source[output_index][channel] + 1'b1;
                        end
                    end
                end
            end
        end
    end

    initial begin
        if (ADDR_WIDTH < X_BITS + Y_BITS) begin
            $error("ADDR_WIDTH cannot contain both torus coordinates");
        end
        if (CHANNELS < 1) begin
            $error("CHANNELS must be at least one");
        end
        if ((X_COORD < 0) || (X_COORD >= MESH_X)
            || (Y_COORD < 0) || (Y_COORD >= MESH_Y)) begin
            $error("Router coordinate is outside the mesh");
        end
    end

endmodule
