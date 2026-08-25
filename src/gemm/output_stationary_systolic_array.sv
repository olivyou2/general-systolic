module output_stationary_systolic_array #(
    parameter array_m = 8,
    parameter array_n = 8,
    parameter element_width = 8,
    parameter accumulator_width = 32
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start_tile,
    input  logic stall_in,
    input  logic [array_m*element_width-1:0] a_vector_in,
    input  logic [array_n*element_width-1:0] b_vector_in,
    input  logic step_valid_in,
    output wire step_ready_out,
    input  logic step_last_in,

    output wire [array_n*accumulator_width-1:0] result_vector_out,
    output wire result_valid_out,
    input  logic result_ready_in,
    output logic tile_done,
    output wire busy
);
    localparam logic [1:0] state_idle = 2'd0;
    localparam logic [1:0] state_accumulate = 2'd1;
    localparam logic [1:0] state_drain = 2'd2;
    localparam int row_width = (array_m > 1) ? $clog2(array_m) : 1;

    logic [1:0] state;
    logic [row_width-1:0] drain_row;
    logic signed [accumulator_width-1:0]
        accumulators [0:array_m-1][0:array_n-1];
    logic [array_n*accumulator_width-1:0] result_vector_internal;

    assign step_ready_out = (state == state_accumulate) && !stall_in;
    assign result_valid_out = (state == state_drain) && !stall_in;
    assign result_vector_out = result_vector_internal;
    assign busy = (state != state_idle);

    always_comb begin
        result_vector_internal = '0;
        for (int column = 0; column < array_n; column++) begin
            result_vector_internal[column*accumulator_width +: accumulator_width]
                = accumulators[drain_row][column];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= state_idle;
            drain_row <= '0;
            tile_done <= 1'b0;
            for (int row = 0; row < array_m; row++) begin
                for (int column = 0; column < array_n; column++) begin
                    accumulators[row][column] <= '0;
                end
            end
        end else begin
            tile_done <= 1'b0;

            if (start_tile && (state == state_idle)) begin
                state <= state_accumulate;
                drain_row <= '0;
                for (int row = 0; row < array_m; row++) begin
                    for (int column = 0; column < array_n; column++) begin
                        accumulators[row][column] <= '0;
                    end
                end
            end

            if ((state == state_accumulate)
                && step_valid_in
                && step_ready_out) begin
                for (int row = 0; row < array_m; row++) begin
                    for (int column = 0; column < array_n; column++) begin
                        accumulators[row][column]
                            <= accumulators[row][column]
                               + $signed(a_vector_in[
                                   row*element_width +: element_width])
                                 * $signed(b_vector_in[
                                   column*element_width +: element_width]);
                    end
                end

                if (step_last_in) begin
                    state <= state_drain;
                    drain_row <= '0;
                end
            end

            if ((state == state_drain)
                && result_valid_out
                && result_ready_in) begin
                if (drain_row == array_m - 1) begin
                    state <= state_idle;
                    drain_row <= '0;
                    tile_done <= 1'b1;
                end else begin
                    drain_row <= drain_row + 1'b1;
                end
            end
        end
    end

endmodule
