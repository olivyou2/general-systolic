module systolic#(
    parameter WIDTH=16,
    parameter HEIGHT=16,
    parameter UNIT_WIDTH=8,
    parameter ACCUMULATOR_WIDTH=16
)(
    input logic clk,
    input logic rst_n,

    input logic [UNIT_WIDTH-1:0] vertical_bar[HEIGHT],
    input logic [UNIT_WIDTH-1:0] horizontal_bar[WIDTH],

    output logic [UNIT_WIDTH-1:0] horizontal_drain_bar[WIDTH],
    input logic [3:0] result_saturation,

    (* max_fanout = 16, maxfan = 16 *) input logic add,
    (* max_fanout = 16, maxfan = 16 *) input logic flow_v,
    (* max_fanout = 16, maxfan = 16 *) input logic flow_h,
    input logic drain,      // <- Drain Result Signal

    input logic broad_v,     // <- Broadcast Vertical Activations
    input logic broad_h     // <- Broadcast Horizontal Activations
);
    // Both Intel and Xilinx attributes are present; each tool ignores the
    // attribute it does not own. Keeping the multiply result explicit makes
    // the 8x8 multiplier visible to DSP inference instead of burying it in a
    // large procedural array expression.
    (* use_dsp = "yes" *)
    logic [ACCUMULATOR_WIDTH-1:0] result[WIDTH][HEIGHT];
    (* multstyle = "dsp", use_dsp = "yes" *)
    logic [(2*UNIT_WIDTH)-1:0] product[WIDTH][HEIGHT];

    logic [UNIT_WIDTH-1:0] horizontal_flow[WIDTH][HEIGHT]; // x ++
    logic [UNIT_WIDTH-1:0] vertical_flow[WIDTH][HEIGHT]; // y ++

    generate
        for (genvar product_x = 0; product_x < WIDTH; product_x++) begin : products_x
            for (genvar product_y = 0; product_y < HEIGHT; product_y++) begin : products_y
                assign product[product_x][product_y]
                    = horizontal_flow[product_x][product_y]
                      * vertical_flow[product_x][product_y];
            end
        end
    endgenerate

    // A synchronous clear is compatible with DSP accumulator registers on the
    // common FPGA families. The surrounding core already holds reset across
    // clock edges, so this does not change its reset protocol.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i=0; i<WIDTH; i++) begin
                horizontal_drain_bar[i] <= 0;
                for (int j=0; j<HEIGHT; j++) begin
                    result[i][j] <= 0;
                    horizontal_flow[i][j] <= 0;
                    vertical_flow[i][j] <= 0;
                end
            end
        end else begin

            if (drain) begin
                for (int i=0; i<WIDTH; i++) begin
                    result[i][0] <= 0;
                    horizontal_drain_bar[i] <= UNIT_WIDTH'(
                        result[i][HEIGHT-1] >> result_saturation);

                    for (int j=1; j<HEIGHT; j++) begin
                        result[i][j] <= result[i][j-1];
                    end
                end
            end else begin
                if (add) begin
                    for (int i=0; i<WIDTH; i++) begin
                        for (int j=0; j<HEIGHT; j++) begin
                            result[i][j] <= result[i][j] + product[i][j];
                        end
                    end
                end

                if (flow_v) begin
                    if (!broad_v) begin
                        for (int i=0; i<WIDTH; i++) begin
                            vertical_flow[i][0] <= horizontal_bar[i];

                            for (int j=1; j<HEIGHT; j++) begin
                                vertical_flow[i][j] <= vertical_flow[i][j-1];
                            end
                        end
                    end else begin
                        for (int i=0; i<WIDTH; i++) begin
                            for (int j=0; j<HEIGHT; j++) begin
                                vertical_flow[i][j] <= horizontal_bar[i];
                            end
                        end
                    end
                end

                if (flow_h) begin
                    if (!broad_h) begin
                        for (int i=0; i<HEIGHT; i++) begin
                            horizontal_flow[0][i] <= vertical_bar[i];
                            
                            for (int j=1; j<WIDTH; j++) begin
                                horizontal_flow[j][i] <= horizontal_flow[j-1][i];
                            end
                        end
                    end else begin
                        for (int i=0; i<HEIGHT; i++) begin
                            for (int j=0; j<WIDTH; j++) begin
                                horizontal_flow[j][i] <= vertical_bar[i];
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
