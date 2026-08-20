module vector_engine #(
    parameter lanes = 8,
    parameter accumulator_width = 32,
    parameter output_element_width = 32
)(
    input  logic clk,
    input  logic rst_n,

    input  logic enable_bias,
    input  logic enable_relu,
    input  logic [5:0] requantize_shift,
    input  logic signed [accumulator_width-1:0] scalar_bias,

    input  logic [lanes*accumulator_width-1:0] data_in,
    input  logic valid_in,
    output wire ready_out,

    output wire [lanes*output_element_width-1:0] data_out,
    output wire valid_out,
    input  logic ready_in
);
    logic [lanes*output_element_width-1:0] data_reg;
    logic valid_reg;

    function automatic [output_element_width-1:0] transform_element(
        input logic signed [accumulator_width-1:0] value
    );
        logic signed [accumulator_width:0] biased_value;
        logic signed [accumulator_width:0] shifted_value;
        logic signed [accumulator_width:0] maximum_value;
        logic signed [accumulator_width:0] minimum_value;
        begin
            biased_value = value;
            if (enable_bias) begin
                biased_value = biased_value + scalar_bias;
            end
            if (enable_relu && (biased_value < 0)) begin
                biased_value = '0;
            end

            shifted_value = biased_value >>> requantize_shift;
            maximum_value = '0;
            minimum_value = '0;
            for (int bit_index = 0;
                 bit_index < output_element_width - 1;
                 bit_index++) begin
                maximum_value[bit_index] = 1'b1;
            end
            for (int bit_index = output_element_width - 1;
                 bit_index <= accumulator_width;
                 bit_index++) begin
                minimum_value[bit_index] = 1'b1;
            end

            if (shifted_value > maximum_value) begin
                transform_element = maximum_value[output_element_width-1:0];
            end else if (shifted_value < minimum_value) begin
                transform_element = minimum_value[output_element_width-1:0];
            end else begin
                transform_element = shifted_value[output_element_width-1:0];
            end
        end
    endfunction

    assign ready_out = !valid_reg || ready_in;
    assign data_out = data_reg;
    assign valid_out = valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_reg <= '0;
            valid_reg <= 1'b0;
        end else if (ready_out) begin
            valid_reg <= valid_in;
            if (valid_in) begin
                for (int lane = 0; lane < lanes; lane++) begin
                    data_reg[lane*output_element_width +: output_element_width]
                        <= transform_element($signed(data_in[
                            lane*accumulator_width +: accumulator_width]));
                end
            end
        end
    end

endmodule
