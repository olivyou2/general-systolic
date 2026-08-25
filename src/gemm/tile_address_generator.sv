module tile_address_generator #(
    parameter address_width = 16,
    parameter elements_per_tile = 32,
    parameter loop_levels = 6
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start_job,
    input  logic [address_width-1:0] configuration_base_address,
    input  logic [address_width-1:0] configuration_element_stride,
    input  logic [15:0] configuration_loop_count [0:loop_levels-1],
    input  logic [address_width-1:0]
        configuration_loop_stride [0:loop_levels-1],

    input  logic start_tile,
    input  logic retire_tile,

    output wire request_valid,
    input  logic request_ready,
    output wire [address_width-1:0] request_address,
    output wire request_last,

    output wire [address_width-1:0] current_tile_base,
    output wire running,
    output wire tile_active,
    output wire job_last_tile,
    output logic tile_reads_done,
    output logic job_done
);
    localparam int element_index_width = (elements_per_tile > 1)
        ? $clog2(elements_per_tile) : 1;

    logic [address_width-1:0] base_address_reg;
    logic [address_width-1:0] element_stride_reg;
    logic [15:0] loop_count_reg [0:loop_levels-1];
    logic [address_width-1:0] loop_stride_reg [0:loop_levels-1];
    logic [15:0] loop_counter [0:loop_levels-1];
    logic [15:0] next_loop_counter [0:loop_levels-1];
    logic [element_index_width-1:0] element_index_reg;
    logic running_reg;
    logic tile_active_reg;
    logic [address_width-1:0] current_tile_base_internal;
    logic job_last_tile_internal;

    always_comb begin
        current_tile_base_internal = base_address_reg;
        job_last_tile_internal = running_reg;

        for (int level = 0; level < loop_levels; level++) begin
            current_tile_base_internal
                = current_tile_base_internal
                  + loop_counter[level] * loop_stride_reg[level];
            if ((loop_count_reg[level] == 0)
                || ((loop_counter[level] + 1) < loop_count_reg[level])) begin
                job_last_tile_internal = 1'b0;
            end
        end

        for (int level = 0; level < loop_levels; level++) begin
            next_loop_counter[level] = loop_counter[level];
        end

        begin : calculate_next_counter
            logic carry;
            carry = 1'b1;
            for (int level = 0; level < loop_levels; level++) begin
                if (carry) begin
                    if ((loop_count_reg[level] <= 1)
                        || ((loop_counter[level] + 1)
                            >= loop_count_reg[level])) begin
                        next_loop_counter[level] = '0;
                    end else begin
                        next_loop_counter[level] = loop_counter[level] + 1'b1;
                        carry = 1'b0;
                    end
                end
            end
        end
    end

    assign current_tile_base = current_tile_base_internal;
    assign running = running_reg;
    assign tile_active = tile_active_reg;
    assign request_valid = running_reg && tile_active_reg;
    assign request_address
        = current_tile_base_internal + element_index_reg * element_stride_reg;
    assign request_last = (element_index_reg == elements_per_tile - 1);
    assign job_last_tile = job_last_tile_internal;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base_address_reg <= '0;
            element_stride_reg <= '0;
            element_index_reg <= '0;
            running_reg <= 1'b0;
            tile_active_reg <= 1'b0;
            tile_reads_done <= 1'b0;
            job_done <= 1'b0;
            for (int level = 0; level < loop_levels; level++) begin
                loop_count_reg[level] <= 1;
                loop_stride_reg[level] <= '0;
                loop_counter[level] <= '0;
            end
        end else begin
            tile_reads_done <= 1'b0;
            job_done <= 1'b0;

            if (start_job) begin
                base_address_reg <= configuration_base_address;
                element_stride_reg <= configuration_element_stride;
                element_index_reg <= '0;
                running_reg <= 1'b1;
                tile_active_reg <= 1'b0;
                for (int level = 0; level < loop_levels; level++) begin
                    loop_count_reg[level] <= configuration_loop_count[level];
                    loop_stride_reg[level] <= configuration_loop_stride[level];
                    loop_counter[level] <= '0;
                    if (configuration_loop_count[level] == 0) begin
                        running_reg <= 1'b0;
                    end
                end
            end else begin
                if (start_tile && running_reg && !tile_active_reg) begin
                    element_index_reg <= '0;
                    tile_active_reg <= 1'b1;
                end

                if (request_valid && request_ready) begin
                    if (request_last) begin
                        element_index_reg <= '0;
                        tile_active_reg <= 1'b0;
                        tile_reads_done <= 1'b1;
                    end else begin
                        element_index_reg <= element_index_reg + 1'b1;
                    end
                end

                if (retire_tile && running_reg && !tile_active_reg) begin
                    if (job_last_tile_internal) begin
                        running_reg <= 1'b0;
                        job_done <= 1'b1;
                    end else begin
                        for (int level = 0; level < loop_levels; level++) begin
                            loop_counter[level] <= next_loop_counter[level];
                        end
                    end
                end
            end
        end
    end

endmodule
