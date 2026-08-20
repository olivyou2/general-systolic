module data_distribution #(
    parameter data_width = 32,
    parameter input_streams = 2,
    parameter output_streams = 2,
    parameter schedule_depth = 16
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [31:0] configuration_addr_in,
    input  logic [31:0] configuration_data_in,
    input  logic configuration_valid_in,

    input  logic [data_width-1:0] data_in [0:input_streams-1],
    input  logic data_valid_in [0:input_streams-1],
    output wire data_ready_out [0:input_streams-1],

    output wire [data_width-1:0] data_out [0:output_streams-1],
    output wire data_valid_out [0:output_streams-1],
    input  logic data_ready_in [0:output_streams-1]
);
    localparam int source_width = (input_streams > 1)
        ? $clog2(input_streams) : 1;
    localparam int destination_width = (output_streams > 1)
        ? $clog2(output_streams) : 1;
    localparam int schedule_value_count = (input_streams > output_streams)
        ? input_streams : output_streams;
    localparam int schedule_value_width = (schedule_value_count > 1)
        ? $clog2(schedule_value_count) : 1;
    localparam int schedule_index_width = (schedule_depth > 1)
        ? $clog2(schedule_depth) : 1;
    localparam int schedule_length_width = $clog2(schedule_depth + 1);

    localparam logic mode_many_to_one = 1'b0;
    localparam logic mode_one_to_many = 1'b1;
    localparam logic [15:0] register_control = 16'h0000;
    localparam logic [15:0] register_schedule_length = 16'h0001;
    localparam logic [15:0] register_many_to_one_output = 16'h0002;
    localparam logic [15:0] register_one_to_many_input = 16'h0003;
    localparam logic [15:0] register_schedule_base = 16'h0100;

    // Configuration map (writes other than CONTROL are accepted only while
    // disabled):
    //   0x0000 CONTROL: bit 0 enable, bit 1 mode, bit 2 restart
    //   0x0001 schedule length (1..schedule_depth)
    //   0x0002 many-to-one destination output index
    //   0x0003 one-to-many source input index
    //   0x0100+n schedule[n]: input index in M:1, output index in 1:M
    logic unit_enable;
    logic distribution_mode;
    logic [schedule_length_width-1:0] schedule_length;
    logic [source_width-1:0] one_to_many_input;
    logic [destination_width-1:0] many_to_one_output;
    logic [schedule_value_width-1:0] schedule_table [0:schedule_depth-1];
    logic [schedule_index_width-1:0] schedule_index;
    wire [15:0] configuration_register = configuration_addr_in[15:0];

    logic transfer_complete;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            unit_enable <= 1'b0;
            distribution_mode <= mode_many_to_one;
            schedule_length <= '0;
            one_to_many_input <= '0;
            many_to_one_output <= '0;
            schedule_index <= '0;
            for (int i = 0; i < schedule_depth; i++) begin
                schedule_table[i] <= '0;
            end
        end else begin
            if (configuration_valid_in) begin
                if (configuration_register == register_control) begin
                    if (!unit_enable) begin
                        distribution_mode <= configuration_data_in[1];
                    end
                    if ((!unit_enable && configuration_data_in[0])
                        || (!unit_enable && configuration_data_in[2])) begin
                        schedule_index <= '0;
                    end
                    unit_enable <= configuration_data_in[0];
                end else if (!unit_enable) begin
                    if ((configuration_register == register_schedule_length)
                        && (configuration_data_in <= schedule_depth)) begin
                        schedule_length
                            <= configuration_data_in[schedule_length_width-1:0];
                    end else if ((configuration_register
                                  == register_many_to_one_output)
                                 && (configuration_data_in < output_streams)) begin
                        many_to_one_output
                            <= configuration_data_in[destination_width-1:0];
                    end else if ((configuration_register
                                  == register_one_to_many_input)
                                 && (configuration_data_in < input_streams)) begin
                        one_to_many_input
                            <= configuration_data_in[source_width-1:0];
                    end else if ((configuration_register >= register_schedule_base)
                                 && (configuration_register
                                     < register_schedule_base + schedule_depth)) begin
                        schedule_table[configuration_register
                                       - register_schedule_base]
                            <= configuration_data_in[schedule_value_width-1:0];
                    end
                end
            end else if (unit_enable && transfer_complete) begin
                if ((schedule_index + 1) >= schedule_length) begin
                    schedule_index <= '0;
                end else begin
                    schedule_index <= schedule_index + 1'b1;
                end
            end
        end
    end

    // Every input owns a two-entry FIFO. data_ready_out is a decode of the
    // registered occupancy and therefore contains no output-ready timing path.
    logic [data_width-1:0] input_head_data [0:input_streams-1];
    logic [data_width-1:0] input_skid_data [0:input_streams-1];
    logic [1:0] input_occupancy [0:input_streams-1];
    logic input_enabled [0:input_streams-1];
    logic input_ready_internal [0:input_streams-1];
    logic input_enqueue [0:input_streams-1];
    logic input_pop [0:input_streams-1];

    logic [source_width-1:0] selected_input;
    logic [destination_width-1:0] selected_output;
    logic selected_route_valid;
    logic [data_width-1:0] output_data_internal [0:output_streams-1];
    logic output_valid_internal [0:output_streams-1];

    always_comb begin
        selected_input = '0;
        selected_output = '0;
        selected_route_valid = 1'b0;

        if (unit_enable && (schedule_length != 0)) begin
            if (distribution_mode == mode_many_to_one) begin
                selected_input = schedule_table[schedule_index][source_width-1:0];
                selected_output = many_to_one_output;
                selected_route_valid
                    = (schedule_table[schedule_index] < input_streams)
                    && (many_to_one_output < output_streams);
            end else begin
                selected_input = one_to_many_input;
                selected_output
                    = schedule_table[schedule_index][destination_width-1:0];
                selected_route_valid
                    = (one_to_many_input < input_streams)
                    && (schedule_table[schedule_index] < output_streams);
            end
        end

        for (int input_index = 0; input_index < input_streams; input_index++) begin
            input_enabled[input_index] = 1'b0;
            input_pop[input_index] = 1'b0;
        end

        if (unit_enable && (schedule_length != 0)) begin
            if (distribution_mode == mode_many_to_one) begin
                for (int entry = 0; entry < schedule_depth; entry++) begin
                    if ((entry < schedule_length)
                        && (schedule_table[entry] < input_streams)) begin
                        input_enabled[schedule_table[entry]] = 1'b1;
                    end
                end
            end else if (one_to_many_input < input_streams) begin
                input_enabled[one_to_many_input] = 1'b1;
            end
        end

        for (int output_index = 0; output_index < output_streams; output_index++) begin
            output_data_internal[output_index] = '0;
            output_valid_internal[output_index] = 1'b0;
        end

        if (selected_route_valid) begin
            output_data_internal[selected_output] = input_head_data[selected_input];
            output_valid_internal[selected_output]
                = (input_occupancy[selected_input] != 0);
        end

        transfer_complete
            = selected_route_valid
            && (input_occupancy[selected_input] != 0)
            && data_ready_in[selected_output];

        if (transfer_complete) begin
            input_pop[selected_input] = 1'b1;
        end

        for (int input_index = 0; input_index < input_streams; input_index++) begin
            input_ready_internal[input_index]
                = input_enabled[input_index]
                && (input_occupancy[input_index] != 2);
            input_enqueue[input_index]
                = data_valid_in[input_index]
                && input_ready_internal[input_index];
        end
    end

    generate
        for (genvar input_index = 0;
             input_index < input_streams;
             input_index++) begin : input_ready_outputs
            assign data_ready_out[input_index]
                = input_ready_internal[input_index];
        end

        for (genvar output_index = 0;
             output_index < output_streams;
             output_index++) begin : distribution_outputs
            assign data_out[output_index]
                = output_data_internal[output_index];
            assign data_valid_out[output_index]
                = output_valid_internal[output_index];
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < input_streams; i++) begin
                input_head_data[i] <= '0;
                input_skid_data[i] <= '0;
                input_occupancy[i] <= 0;
            end
        end else begin
            for (int i = 0; i < input_streams; i++) begin
                case ({input_enqueue[i], input_pop[i]})
                    2'b01: begin
                        if (input_occupancy[i] == 2) begin
                            input_head_data[i] <= input_skid_data[i];
                            input_occupancy[i] <= 1;
                        end else begin
                            input_occupancy[i] <= 0;
                        end
                    end

                    2'b10: begin
                        if (input_occupancy[i] == 0) begin
                            input_head_data[i] <= data_in[i];
                            input_occupancy[i] <= 1;
                        end else begin
                            input_skid_data[i] <= data_in[i];
                            input_occupancy[i] <= 2;
                        end
                    end

                    2'b11: begin
                        input_head_data[i] <= data_in[i];
                        input_occupancy[i] <= 1;
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

endmodule
