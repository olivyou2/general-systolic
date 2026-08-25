module gemm_unit #(
    parameter array_m = 8,
    parameter array_n = 8,
    parameter element_width = 8,
    parameter accumulator_width = 32,
    parameter output_element_width = 32,
    parameter k_chunk = 32,
    parameter a_scratchpad_tile_slots = 2,
    parameter b_scratchpad_tile_slots = 2,
    parameter agu_loop_levels = 6,
    parameter result_fifo_depth = 4,
    parameter output_scratchpad_depth = 64
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [31:0] configuration_addr_in,
    input  logic [31:0] configuration_data_in,
    input  logic configuration_valid_in,

    input  logic [array_m*element_width-1:0] a_stream_data_in,
    input  logic a_stream_valid_in,
    output wire a_stream_ready_out,

    input  logic [array_n*element_width-1:0] b_stream_data_in,
    input  logic b_stream_valid_in,
    output wire b_stream_ready_out,

    output wire [array_n*output_element_width-1:0] output_stream_data_out,
    output wire output_stream_valid_out,
    input  logic output_stream_ready_in,

    output wire busy,
    output logic job_done
);
    localparam int a_total_words = a_scratchpad_tile_slots * k_chunk;
    localparam int b_total_words = b_scratchpad_tile_slots * k_chunk;
    localparam int a_address_width = (a_total_words > 1)
        ? $clog2(a_total_words) : 1;
    localparam int b_address_width = (b_total_words > 1)
        ? $clog2(b_total_words) : 1;
    localparam int a_slot_width = (a_scratchpad_tile_slots > 1)
        ? $clog2(a_scratchpad_tile_slots) : 1;
    localparam int b_slot_width = (b_scratchpad_tile_slots > 1)
        ? $clog2(b_scratchpad_tile_slots) : 1;
    localparam int result_vector_width = array_n * accumulator_width;
    localparam int output_vector_width = array_n * output_element_width;

    localparam logic [15:0] register_control = 16'h0000;
    localparam logic [15:0] register_a_write_slot = 16'h0001;
    localparam logic [15:0] register_b_write_slot = 16'h0002;
    localparam logic [15:0] register_a_base = 16'h0003;
    localparam logic [15:0] register_b_base = 16'h0004;
    localparam logic [15:0] register_a_tile_stride = 16'h0005;
    localparam logic [15:0] register_b_tile_stride = 16'h0006;
    localparam logic [15:0] register_tile_count = 16'h0007;
    localparam logic [15:0] register_release_a = 16'h0008;
    localparam logic [15:0] register_release_b = 16'h0009;
    localparam logic [15:0] register_vector_control = 16'h0010;
    localparam logic [15:0] register_vector_bias = 16'h0011;
    localparam logic [15:0] register_loop_count_base = 16'h0020;
    localparam logic [15:0] register_a_loop_stride_base = 16'h0040;
    localparam logic [15:0] register_b_loop_stride_base = 16'h0060;

    // CONTROL bit 0 enables the unit, bit 1 submits the configured job, and
    // bit 2 globally stalls the systolic pipeline without losing its state.
    // Address/stride values are scratchpad word addresses. A tile stride of 0
    // retains and reuses the same tile for every output tile in the job.
    wire [15:0] configuration_register = configuration_addr_in[15:0];
    logic unit_enable;
    logic systolic_pipeline_stall;
    logic start_job_pulse;
    logic release_a_pulse;
    logic release_b_pulse;
    logic [a_slot_width-1:0] a_write_slot;
    logic [b_slot_width-1:0] b_write_slot;
    logic [a_slot_width-1:0] a_release_slot;
    logic [b_slot_width-1:0] b_release_slot;
    logic [a_address_width-1:0] a_base_address;
    logic [b_address_width-1:0] b_base_address;
    logic [15:0] configured_loop_count [0:agu_loop_levels-1];
    logic [a_address_width-1:0] a_loop_stride [0:agu_loop_levels-1];
    logic [b_address_width-1:0] b_loop_stride [0:agu_loop_levels-1];
    logic vector_bias_enable;
    logic vector_relu_enable;
    logic [5:0] vector_requantize_shift;
    logic signed [accumulator_width-1:0] vector_scalar_bias;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            unit_enable <= 1'b0;
            systolic_pipeline_stall <= 1'b0;
            start_job_pulse <= 1'b0;
            release_a_pulse <= 1'b0;
            release_b_pulse <= 1'b0;
            a_write_slot <= '0;
            b_write_slot <= '0;
            a_release_slot <= '0;
            b_release_slot <= '0;
            a_base_address <= '0;
            b_base_address <= '0;
            vector_bias_enable <= 1'b0;
            vector_relu_enable <= 1'b0;
            vector_requantize_shift <= '0;
            vector_scalar_bias <= '0;
            for (int level = 0; level < agu_loop_levels; level++) begin
                configured_loop_count[level] <= 1;
                a_loop_stride[level] <= '0;
                b_loop_stride[level] <= '0;
            end
            a_loop_stride[0] <= k_chunk;
            b_loop_stride[0] <= k_chunk;
        end else begin
            start_job_pulse <= 1'b0;
            release_a_pulse <= 1'b0;
            release_b_pulse <= 1'b0;

            if (configuration_valid_in) begin
                case (configuration_register)
                    register_control: begin
                        unit_enable <= configuration_data_in[0];
                        systolic_pipeline_stall <= configuration_data_in[2];
                        start_job_pulse
                            <= configuration_data_in[0]
                               && configuration_data_in[1];
                    end
                    register_a_write_slot:
                        a_write_slot <= configuration_data_in[a_slot_width-1:0];
                    register_b_write_slot:
                        b_write_slot <= configuration_data_in[b_slot_width-1:0];
                    register_a_base:
                        a_base_address <= configuration_data_in[a_address_width-1:0];
                    register_b_base:
                        b_base_address <= configuration_data_in[b_address_width-1:0];
                    register_a_tile_stride:
                        a_loop_stride[0]
                            <= configuration_data_in[a_address_width-1:0];
                    register_b_tile_stride:
                        b_loop_stride[0]
                            <= configuration_data_in[b_address_width-1:0];
                    register_tile_count:
                        configured_loop_count[0] <= configuration_data_in[15:0];
                    register_release_a: begin
                        a_release_slot <= configuration_data_in[a_slot_width-1:0];
                        release_a_pulse <= 1'b1;
                    end
                    register_release_b: begin
                        b_release_slot <= configuration_data_in[b_slot_width-1:0];
                        release_b_pulse <= 1'b1;
                    end
                    register_vector_control: begin
                        vector_bias_enable <= configuration_data_in[0];
                        vector_relu_enable <= configuration_data_in[1];
                        vector_requantize_shift <= configuration_data_in[13:8];
                    end
                    register_vector_bias:
                        vector_scalar_bias
                            <= configuration_data_in[accumulator_width-1:0];
                    default: begin
                        if ((configuration_register >= register_loop_count_base)
                            && (configuration_register
                                < register_loop_count_base + agu_loop_levels)) begin
                            configured_loop_count[
                                configuration_register - register_loop_count_base]
                                <= configuration_data_in[15:0];
                        end else if ((configuration_register
                                     >= register_a_loop_stride_base)
                                    && (configuration_register
                                        < register_a_loop_stride_base
                                          + agu_loop_levels)) begin
                            a_loop_stride[
                                configuration_register - register_a_loop_stride_base]
                                <= configuration_data_in[a_address_width-1:0];
                        end else if ((configuration_register
                                     >= register_b_loop_stride_base)
                                    && (configuration_register
                                        < register_b_loop_stride_base
                                          + agu_loop_levels)) begin
                            b_loop_stride[
                                configuration_register - register_b_loop_stride_base]
                                <= configuration_data_in[b_address_width-1:0];
                        end
                    end
                endcase
            end
        end
    end

    wire [a_scratchpad_tile_slots-1:0] a_tile_ready;
    wire [b_scratchpad_tile_slots-1:0] b_tile_ready;
    wire a_spad_request_ready;
    wire b_spad_request_ready;
    wire [array_m*element_width-1:0] a_read_data;
    wire [array_n*element_width-1:0] b_read_data;
    wire a_read_valid;
    wire b_read_valid;
    wire a_read_last;
    wire b_read_last;
    wire a_read_data_ready;
    wire b_read_data_ready;

    wire a_agu_request_valid;
    wire b_agu_request_valid;
    wire [a_address_width-1:0] a_agu_request_address;
    wire [b_address_width-1:0] b_agu_request_address;
    wire a_agu_request_last;
    wire b_agu_request_last;
    wire [a_address_width-1:0] a_current_tile_base;
    wire [b_address_width-1:0] b_current_tile_base;
    wire a_agu_running;
    wire b_agu_running;
    wire a_job_last_tile;
    wire b_job_last_tile;
    logic start_tile_pulse;
    logic retire_tile_pulse;
    wire paired_read_request
        = a_agu_request_valid
          && b_agu_request_valid
          && a_spad_request_ready
          && b_spad_request_ready;
    wire a_agu_request_ready
        = b_agu_request_valid && a_spad_request_ready && b_spad_request_ready;
    wire b_agu_request_ready
        = a_agu_request_valid && a_spad_request_ready && b_spad_request_ready;

    banked_tile_scratchpad #(
        .lanes(array_m),
        .element_width(element_width),
        .words_per_tile(k_chunk),
        .tile_slots(a_scratchpad_tile_slots)
    ) a_scratchpad (
        .clk(clk), .rst_n(rst_n),
        .write_slot(a_write_slot),
        .stream_data_in(a_stream_data_in),
        .stream_valid_in(a_stream_valid_in),
        .stream_ready_out(a_stream_ready_out),
        .release_valid(release_a_pulse),
        .release_slot(a_release_slot),
        .tile_ready_out(a_tile_ready),
        .read_request_valid(paired_read_request),
        .read_request_ready(a_spad_request_ready),
        .read_request_address(a_agu_request_address),
        .read_request_last(a_agu_request_last),
        .read_data_out(a_read_data),
        .read_data_valid_out(a_read_valid),
        .read_data_ready_in(a_read_data_ready),
        .read_data_last_out(a_read_last)
    );

    banked_tile_scratchpad #(
        .lanes(array_n),
        .element_width(element_width),
        .words_per_tile(k_chunk),
        .tile_slots(b_scratchpad_tile_slots)
    ) b_scratchpad (
        .clk(clk), .rst_n(rst_n),
        .write_slot(b_write_slot),
        .stream_data_in(b_stream_data_in),
        .stream_valid_in(b_stream_valid_in),
        .stream_ready_out(b_stream_ready_out),
        .release_valid(release_b_pulse),
        .release_slot(b_release_slot),
        .tile_ready_out(b_tile_ready),
        .read_request_valid(paired_read_request),
        .read_request_ready(b_spad_request_ready),
        .read_request_address(b_agu_request_address),
        .read_request_last(b_agu_request_last),
        .read_data_out(b_read_data),
        .read_data_valid_out(b_read_valid),
        .read_data_ready_in(b_read_data_ready),
        .read_data_last_out(b_read_last)
    );

    tile_address_generator #(
        .address_width(a_address_width),
        .elements_per_tile(k_chunk),
        .loop_levels(agu_loop_levels)
    ) a_address_generator (
        .clk(clk), .rst_n(rst_n),
        .start_job(start_job_pulse && unit_enable),
        .configuration_base_address(a_base_address),
        .configuration_element_stride(a_address_width'(1)),
        .configuration_loop_count(configured_loop_count),
        .configuration_loop_stride(a_loop_stride),
        .start_tile(start_tile_pulse),
        .retire_tile(retire_tile_pulse),
        .request_valid(a_agu_request_valid),
        .request_ready(a_agu_request_ready),
        .request_address(a_agu_request_address),
        .request_last(a_agu_request_last),
        .current_tile_base(a_current_tile_base),
        .running(a_agu_running),
        .tile_active(),
        .job_last_tile(a_job_last_tile),
        .tile_reads_done(),
        .job_done()
    );

    tile_address_generator #(
        .address_width(b_address_width),
        .elements_per_tile(k_chunk),
        .loop_levels(agu_loop_levels)
    ) b_address_generator (
        .clk(clk), .rst_n(rst_n),
        .start_job(start_job_pulse && unit_enable),
        .configuration_base_address(b_base_address),
        .configuration_element_stride(b_address_width'(1)),
        .configuration_loop_count(configured_loop_count),
        .configuration_loop_stride(b_loop_stride),
        .start_tile(start_tile_pulse),
        .retire_tile(retire_tile_pulse),
        .request_valid(b_agu_request_valid),
        .request_ready(b_agu_request_ready),
        .request_address(b_agu_request_address),
        .request_last(b_agu_request_last),
        .current_tile_base(b_current_tile_base),
        .running(b_agu_running),
        .tile_active(),
        .job_last_tile(b_job_last_tile),
        .tile_reads_done(),
        .job_done()
    );

    wire [a_slot_width-1:0] a_compute_slot = a_current_tile_base / k_chunk;
    wire [b_slot_width-1:0] b_compute_slot = b_current_tile_base / k_chunk;
    wire selected_tiles_ready
        = (a_current_tile_base < a_total_words)
          && (b_current_tile_base < b_total_words)
          && a_tile_ready[a_compute_slot]
          && b_tile_ready[b_compute_slot];

    wire systolic_step_ready;
    wire systolic_result_ready;
    wire systolic_tile_done;
    wire systolic_busy;
    wire [result_vector_width-1:0] systolic_result_data;
    wire systolic_result_valid;
    wire paired_operand_valid = a_read_valid && b_read_valid;

    assign a_read_data_ready = systolic_step_ready && b_read_valid;
    assign b_read_data_ready = systolic_step_ready && a_read_valid;

    output_stationary_systolic_array #(
        .array_m(array_m),
        .array_n(array_n),
        .element_width(element_width),
        .accumulator_width(accumulator_width)
    ) systolic_array (
        .clk(clk), .rst_n(rst_n),
        .start_tile(start_tile_pulse),
        .stall_in(systolic_pipeline_stall),
        .a_vector_in(a_read_data),
        .b_vector_in(b_read_data),
        .step_valid_in(paired_operand_valid),
        .step_ready_out(systolic_step_ready),
        .step_last_in(a_read_last && b_read_last),
        .result_vector_out(systolic_result_data),
        .result_valid_out(systolic_result_valid),
        .result_ready_in(systolic_result_ready),
        .tile_done(systolic_tile_done),
        .busy(systolic_busy)
    );

    wire [result_vector_width-1:0] result_fifo_data;
    wire result_fifo_valid;
    wire result_fifo_ready;

    stream_fifo #(
        .data_width(result_vector_width),
        .depth(result_fifo_depth)
    ) systolic_result_fifo (
        .clk(clk), .rst_n(rst_n),
        .data_in(systolic_result_data),
        .valid_in(systolic_result_valid),
        .ready_out(systolic_result_ready),
        .data_out(result_fifo_data),
        .valid_out(result_fifo_valid),
        .ready_in(result_fifo_ready)
    );

    wire [output_vector_width-1:0] vector_result_data;
    wire vector_result_valid;
    wire vector_result_ready;

    vector_engine #(
        .lanes(array_n),
        .accumulator_width(accumulator_width),
        .output_element_width(output_element_width)
    ) postprocess_engine (
        .clk(clk), .rst_n(rst_n),
        .enable_bias(vector_bias_enable),
        .enable_relu(vector_relu_enable),
        .requantize_shift(vector_requantize_shift),
        .scalar_bias(vector_scalar_bias),
        .data_in(result_fifo_data),
        .valid_in(result_fifo_valid),
        .ready_out(result_fifo_ready),
        .data_out(vector_result_data),
        .valid_out(vector_result_valid),
        .ready_in(vector_result_ready)
    );

    output_scratchpad #(
        .vector_lanes(array_n),
        .element_width(output_element_width),
        .depth(output_scratchpad_depth)
    ) result_scratchpad (
        .clk(clk), .rst_n(rst_n),
        .write_data_in(vector_result_data),
        .write_valid_in(vector_result_valid),
        .write_ready_out(vector_result_ready),
        .stream_data_out(output_stream_data_out),
        .stream_valid_out(output_stream_valid_out),
        .stream_ready_in(output_stream_ready_in)
    );

    localparam logic [1:0] scheduler_idle = 2'd0;
    localparam logic [1:0] scheduler_wait_tile = 2'd1;
    localparam logic [1:0] scheduler_compute = 2'd2;
    logic [1:0] scheduler_state;

    assign busy = (scheduler_state != scheduler_idle)
                  || systolic_busy
                  || a_agu_running
                  || b_agu_running;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scheduler_state <= scheduler_idle;
            start_tile_pulse <= 1'b0;
            retire_tile_pulse <= 1'b0;
            job_done <= 1'b0;
        end else begin
            start_tile_pulse <= 1'b0;
            retire_tile_pulse <= 1'b0;
            job_done <= 1'b0;

            case (scheduler_state)
                scheduler_idle: begin
                    if (start_job_pulse && unit_enable) begin
                        scheduler_state <= scheduler_wait_tile;
                    end
                end

                scheduler_wait_tile: begin
                    if (a_agu_running
                        && b_agu_running
                        && selected_tiles_ready
                        && !systolic_busy) begin
                        start_tile_pulse <= 1'b1;
                        scheduler_state <= scheduler_compute;
                    end
                end

                scheduler_compute: begin
                    if (systolic_tile_done) begin
                        retire_tile_pulse <= 1'b1;
                        if (a_job_last_tile && b_job_last_tile) begin
                            scheduler_state <= scheduler_idle;
                            job_done <= 1'b1;
                        end else begin
                            scheduler_state <= scheduler_wait_tile;
                        end
                    end
                end

                default: scheduler_state <= scheduler_idle;
            endcase
        end
    end

endmodule
