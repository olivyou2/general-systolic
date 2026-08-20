module systolic#(
    parameter WIDTH=16,
    parameter HEIGHT=16
)(
    input logic clk,
    input logic rst_n,

    input logic [7:0] vertical_bar[HEIGHT],
    input logic [7:0] horizontal_bar[WIDTH],

    output logic [7:0] horizontal_drain_bar[WIDTH],
    input logic [3:0] result_saturation,

    input logic add,        // <- Add Multiply Number to Result
    input logic flow_v,     // <- Flow Vertical Flow
    input logic flow_h,     // <- Flow Horizontal Flow
    input logic drain,      // <- Drain Result Signal

    input logic broad_h     // <- Broadcast Horizontal Activations
);
    logic [15:0] result[WIDTH][HEIGHT];

    logic [7:0] horizontal_flow[WIDTH][HEIGHT]; // x ++
    logic [7:0] vertical_flow[WIDTH][HEIGHT]; // y ++

    genvar ii;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i=0; i<WIDTH; i++) begin
                horizontal_drain_bar[i] <= 0;
                for (int j=0; j<HEIGHT; j++) begin
                    result[i][j] <= 0;
                end
            end
        end else begin

            if (drain) begin
                for (int i=0; i<WIDTH; i++) begin
                    result[i][0] <= 0;
                    horizontal_drain_bar[i] <= 8'(result[i][HEIGHT-1] >> result_saturation);

                    for (int j=1; j<HEIGHT; j++) begin
                        result[i][j] <= result[i][j-1];
                    end
                end
            end else begin
                if (add) begin
                    for (int i=0; i<WIDTH; i++) begin
                        for (int j=0; j<HEIGHT; j++) begin
                            result[i][j] <= result[i][j] + horizontal_flow[i][j] * vertical_flow[i][j];
                        end
                    end
                end

                if (flow_v) begin
                    for (int i=0; i<WIDTH; i++) begin
                        vertical_flow[i][0] <= horizontal_bar[i];

                        for (int j=1; j<HEIGHT; j++) begin
                            vertical_flow[i][j] <= vertical_flow[i][j-1];
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