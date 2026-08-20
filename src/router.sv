module router #(
    parameter configuration_device_len = 16,
    parameter configuration_mesh_out = 2,
    parameter data_mesh_links = 2,
    parameter data_mesh_data_width = 32,
    parameter local_unit_streams = 2,
    parameter local_unit_source_streams = 2,
    parameter router_device_id = 0,
    parameter local_unit_device_id = 16'h8000
)(
    input  logic clk,
    input  logic rst_n,

    // Shared configuration network input and onward propagation outputs.
    input  logic [31:0] configuration_addr_in,
    input  logic [31:0] configuration_data_in,
    input  logic configuration_valid_in,
    output wire [31:0] configuration_addr_out [0:configuration_mesh_out-1],
    output wire [31:0] configuration_data_out [0:configuration_mesh_out-1],
    output wire configuration_valid_out [0:configuration_mesh_out-1],

    // Configuration packets addressed to the attached local unit.
    output wire [31:0] local_unit_configuration_addr_out,
    output wire [31:0] local_unit_configuration_data_out,
    output wire local_unit_configuration_valid_out,

    input  logic [data_mesh_data_width-1:0] data_mesh_data_in [0:data_mesh_links-1],
    input  logic data_mesh_valid_in [0:data_mesh_links-1],
    output wire data_mesh_ready_out [0:data_mesh_links-1],

    output wire [data_mesh_data_width-1:0] data_mesh_data_out [0:data_mesh_links-1],
    output wire data_mesh_valid_out [0:data_mesh_links-1],
    input  logic data_mesh_ready_in [0:data_mesh_links-1],

    // Independently backpressured streams delivered to the attached local unit.
    output wire [data_mesh_data_width-1:0] local_unit_data_out [0:local_unit_streams-1],
    output wire local_unit_valid_out [0:local_unit_streams-1],
    input  logic local_unit_ready_in [0:local_unit_streams-1],

    // Streams produced by the local unit and injected into the router.
    input  logic [data_mesh_data_width-1:0] local_unit_data_in [0:local_unit_source_streams-1],
    input  logic local_unit_valid_in [0:local_unit_source_streams-1],
    output wire local_unit_ready_out [0:local_unit_source_streams-1]
);
    localparam int source_count = data_mesh_links + local_unit_source_streams;
    localparam int source_select_width = (source_count > 1)
        ? $clog2(source_count) : 1;
    localparam int destination_count = data_mesh_links + local_unit_streams;
    localparam logic [15:0] local_stream_register_base = 16'h0100;

    wire [15:0] configuration_device_id = configuration_addr_in[31:16];
    wire [15:0] configuration_register_id = configuration_addr_in[15:0];

    // Every packet continues through the configuration network. In parallel,
    // packets for local_unit_device_id are copied to the local-unit interface.
    logic [31:0] configuration_addr_reg [0:configuration_mesh_out-1];
    logic [31:0] configuration_data_reg [0:configuration_mesh_out-1];
    logic configuration_valid_reg [0:configuration_mesh_out-1];
    logic [31:0] local_unit_configuration_addr_reg;
    logic [31:0] local_unit_configuration_data_reg;
    logic local_unit_configuration_valid_reg;

    generate
        for (genvar configuration_index = 0;
             configuration_index < configuration_mesh_out;
             configuration_index++) begin : configuration_outputs
            assign configuration_addr_out[configuration_index]
                = configuration_addr_reg[configuration_index];
            assign configuration_data_out[configuration_index]
                = configuration_data_reg[configuration_index];
            assign configuration_valid_out[configuration_index]
                = configuration_valid_reg[configuration_index];
        end
    endgenerate

    assign local_unit_configuration_addr_out
        = local_unit_configuration_addr_reg;
    assign local_unit_configuration_data_out
        = local_unit_configuration_data_reg;
    assign local_unit_configuration_valid_out
        = local_unit_configuration_valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < configuration_mesh_out; i++) begin
                configuration_addr_reg[i] <= '0;
                configuration_data_reg[i] <= '0;
                configuration_valid_reg[i] <= 1'b0;
            end
            local_unit_configuration_addr_reg <= '0;
            local_unit_configuration_data_reg <= '0;
            local_unit_configuration_valid_reg <= 1'b0;
        end else begin
            for (int i = 0; i < configuration_mesh_out; i++) begin
                configuration_addr_reg[i] <= configuration_addr_in;
                configuration_data_reg[i] <= configuration_data_in;
                configuration_valid_reg[i] <= configuration_valid_in;
            end

            local_unit_configuration_addr_reg <= configuration_addr_in;
            local_unit_configuration_data_reg <= configuration_data_in;
            local_unit_configuration_valid_reg
                <= configuration_valid_in
                && (configuration_device_id == local_unit_device_id);
        end
    end

    // Router-owned configuration register map:
    //   0x0000 + mesh output index:
    //       data = selected source index
    //   0x0100 + local stream index:
    //       data[31] = stream enable, data[select width-1:0] = source index
    // Source indices 0..data_mesh_links-1 are mesh inputs; the remaining
    // indices are streams produced by the local unit.
    logic [source_select_width-1:0] mesh_out_feed_selector [0:data_mesh_links-1];
    logic [source_select_width-1:0] local_unit_feed_selector [0:local_unit_streams-1];
    logic local_unit_stream_enable [0:local_unit_streams-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < data_mesh_links; i++) begin
                mesh_out_feed_selector[i] <= source_select_width'(i);
            end
            for (int i = 0; i < local_unit_streams; i++) begin
                local_unit_feed_selector[i]
                    <= source_select_width'(i % data_mesh_links);
                local_unit_stream_enable[i] <= 1'b0;
            end
        end else if (configuration_valid_in
                     && (configuration_device_id == router_device_id)) begin
            if ((configuration_register_id < data_mesh_links)
                && (configuration_data_in < source_count)) begin
                mesh_out_feed_selector[configuration_register_id]
                    <= configuration_data_in[source_select_width-1:0];
            end else if ((configuration_register_id >= local_stream_register_base)
                         && (configuration_register_id
                             < local_stream_register_base + local_unit_streams)
                         && (configuration_data_in[source_select_width-1:0]
                             < source_count)) begin
                local_unit_feed_selector[
                    configuration_register_id - local_stream_register_base]
                    <= configuration_data_in[source_select_width-1:0];
                local_unit_stream_enable[
                    configuration_register_id - local_stream_register_base]
                    <= configuration_data_in[31];
            end
        end
    end

    // Each source owns a two-entry head+skid FIFO. Source ready depends only on
    // the registered occupancy, so no destination-ready combinational path can
    // propagate to an upstream router. Each entry carries its own multicast
    // pending mask.
    wire [data_mesh_data_width-1:0] source_data [0:source_count-1];
    wire source_valid [0:source_count-1];
    logic source_ready_internal [0:source_count-1];
    logic [data_mesh_data_width-1:0] source_head_data [0:source_count-1];
    logic [data_mesh_data_width-1:0] source_skid_data [0:source_count-1];
    logic [destination_count-1:0] source_head_pending [0:source_count-1];
    logic [destination_count-1:0] source_skid_pending [0:source_count-1];
    logic [1:0] source_occupancy [0:source_count-1];
    logic [destination_count-1:0] route_mask [0:source_count-1];
    logic [destination_count-1:0] consumed_destinations [0:source_count-1];
    logic source_head_complete [0:source_count-1];
    logic source_enqueue [0:source_count-1];

    always_comb begin
        for (int source_index = 0; source_index < source_count; source_index++) begin
            route_mask[source_index] = '0;
            consumed_destinations[source_index] = '0;
        end

        for (int output_index = 0; output_index < data_mesh_links; output_index++) begin
            route_mask[mesh_out_feed_selector[output_index]][output_index] = 1'b1;
        end

        for (int stream_index = 0; stream_index < local_unit_streams; stream_index++) begin
            if (local_unit_stream_enable[stream_index]) begin
                route_mask[local_unit_feed_selector[stream_index]]
                          [data_mesh_links + stream_index] = 1'b1;
            end
        end

        for (int source_index = 0; source_index < source_count; source_index++) begin
            for (int output_index = 0; output_index < data_mesh_links; output_index++) begin
                consumed_destinations[source_index][output_index]
                    = source_head_pending[source_index][output_index]
                    && data_mesh_ready_in[output_index];
            end

            for (int stream_index = 0; stream_index < local_unit_streams; stream_index++) begin
                consumed_destinations[source_index][data_mesh_links + stream_index]
                    = source_head_pending[source_index][data_mesh_links + stream_index]
                    && local_unit_ready_in[stream_index];
            end

            source_head_complete[source_index]
                = (source_occupancy[source_index] != 0)
                && ((source_head_pending[source_index]
                     & ~consumed_destinations[source_index]) == '0);

            // This is deliberately independent of every downstream ready.
            source_ready_internal[source_index]
                = (source_occupancy[source_index] != 2);

            source_enqueue[source_index]
                = source_valid[source_index]
                && source_ready_internal[source_index]
                && (route_mask[source_index] != '0);
        end
    end

    generate
        for (genvar input_index = 0;
             input_index < data_mesh_links;
             input_index++) begin : mesh_input_ready_outputs
            assign source_data[input_index] = data_mesh_data_in[input_index];
            assign source_valid[input_index] = data_mesh_valid_in[input_index];
            assign data_mesh_ready_out[input_index]
                = source_ready_internal[input_index];
        end

        for (genvar stream_index = 0;
             stream_index < local_unit_source_streams;
             stream_index++) begin : local_unit_source_inputs
            assign source_data[data_mesh_links + stream_index]
                = local_unit_data_in[stream_index];
            assign source_valid[data_mesh_links + stream_index]
                = local_unit_valid_in[stream_index];
            assign local_unit_ready_out[stream_index]
                = source_ready_internal[data_mesh_links + stream_index];
        end

        for (genvar output_index = 0;
             output_index < data_mesh_links;
             output_index++) begin : mesh_data_outputs
            wire [source_select_width-1:0] selected_source
                = mesh_out_feed_selector[output_index];

            assign data_mesh_data_out[output_index]
                = source_head_data[selected_source];
            assign data_mesh_valid_out[output_index]
                = (source_occupancy[selected_source] != 0)
                && source_head_pending[selected_source][output_index];
        end

        for (genvar stream_index = 0;
             stream_index < local_unit_streams;
             stream_index++) begin : local_unit_data_outputs
            wire [source_select_width-1:0] selected_source
                = local_unit_feed_selector[stream_index];

            assign local_unit_data_out[stream_index]
                = source_head_data[selected_source];
            assign local_unit_valid_out[stream_index]
                = local_unit_stream_enable[stream_index]
                && (source_occupancy[selected_source] != 0)
                && source_head_pending[selected_source]
                                       [data_mesh_links + stream_index];
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < source_count; i++) begin
                source_head_data[i] <= '0;
                source_skid_data[i] <= '0;
                source_head_pending[i] <= '0;
                source_skid_pending[i] <= '0;
                source_occupancy[i] <= 0;
            end
        end else begin
            for (int i = 0; i < source_count; i++) begin
                case ({source_enqueue[i], source_head_complete[i]})
                    2'b01: begin
                        if (source_occupancy[i] == 2) begin
                            source_head_data[i] <= source_skid_data[i];
                            source_head_pending[i] <= source_skid_pending[i];
                            source_skid_pending[i] <= '0;
                            source_occupancy[i] <= 1;
                        end else begin
                            source_head_pending[i] <= '0;
                            source_occupancy[i] <= 0;
                        end
                    end

                    2'b10: begin
                        if (source_occupancy[i] == 0) begin
                            source_head_data[i] <= source_data[i];
                            source_head_pending[i] <= route_mask[i];
                            source_occupancy[i] <= 1;
                        end else begin
                            source_skid_data[i] <= source_data[i];
                            source_skid_pending[i] <= route_mask[i];
                            source_head_pending[i]
                                <= source_head_pending[i]
                                   & ~consumed_destinations[i];
                            source_occupancy[i] <= 2;
                        end
                    end

                    2'b11: begin
                        // A one-entry FIFO can retire its head and accept the
                        // next item in the same cycle without a throughput gap.
                        source_head_data[i] <= source_data[i];
                        source_head_pending[i] <= route_mask[i];
                        source_occupancy[i] <= 1;
                    end

                    default: begin
                        if (source_occupancy[i] != 0) begin
                            source_head_pending[i]
                                <= source_head_pending[i]
                                   & ~consumed_destinations[i];
                        end
                    end
                endcase
            end
        end
    end

endmodule
