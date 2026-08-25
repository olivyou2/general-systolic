/**
 * Operand launcher for the 8x8 systolic array.
 *
 * GEMM mode consumes the original pre-packed A/B tiles. CNN mode performs
 * an implicit im2col address walk without materialising an im2col buffer:
 *
 *   A bank r: one output position of the tile. Each bank contains the input
 *             tensor in CHW layout, with A_DATAWIDTH/UNIT bytes per word.
 *   B bank k%8: one K row of the weight tile. Each word contains the eight
 *               output-channel weights for that K row.
 *
 * The address and byte-lane selectors are issued one cycle before the MAC
 * step that consumes them, matching the synchronous BRAM read latency. Once
 * the pipeline is primed, both operands are supplied every cycle; padding is
 * represented as a zero lane rather than a bubble.
 */

module systolic_launcher #(
    parameter int A_DATAWIDTH = 64,
    parameter int A_ADDRWIDTH = 9,
    parameter int A_BANKS = 8,

    parameter int B_DATAWIDTH = 64,
    parameter int B_ADDRWIDTH = 9,
    parameter int B_BANKS = 8,

    parameter int SYSTOLIC_UNITWIDTH = 8,
    parameter int SYSTOLIC_WIDTH = 8,
    parameter int SYSTOLIC_HEIGHT = 8
)(
    input logic clk,
    input logic rst_n,

    input logic [A_ADDRWIDTH-1:0] a_mat_base_offset,
    input logic [B_ADDRWIDTH-1:0] b_mat_base_offset,

    output logic [A_ADDRWIDTH-1:0] a_addr [0:A_BANKS-1],
    input logic [A_DATAWIDTH-1:0] a_data [0:A_BANKS-1],

    output logic [B_ADDRWIDTH-1:0] b_addr [0:B_BANKS-1],
    input logic [B_DATAWIDTH-1:0] b_data [0:B_BANKS-1],

    input logic fire,
    input logic cnn_fire,
    output logic busy,

    input logic [A_ADDRWIDTH-1:0] cnn_input_base,
    input logic [B_ADDRWIDTH-1:0] cnn_weight_base,
    input logic [15:0] cnn_input_width,
    input logic [15:0] cnn_input_height,
    input logic [15:0] cnn_input_channels,
    input logic [7:0] cnn_kernel_width,
    input logic [7:0] cnn_kernel_height,
    input logic [15:0] cnn_stride_x,
    input logic [15:0] cnn_stride_y,
    input logic [7:0] cnn_pad_left,
    input logic [7:0] cnn_pad_right,
    input logic [7:0] cnn_pad_top,
    input logic [7:0] cnn_pad_bottom,
    input logic [15:0] cnn_output_x,
    input logic [15:0] cnn_output_y,
    input logic [15:0] cnn_output_width,
    input logic [15:0] cnn_k_total,

    output logic [SYSTOLIC_UNITWIDTH-1:0]
        systolic_vertical_bar [0:SYSTOLIC_HEIGHT-1],
    output logic [SYSTOLIC_UNITWIDTH-1:0]
        systolic_horizontal_bar [0:SYSTOLIC_WIDTH-1],

    output logic systolic_add_signal,
    output logic systolic_flow_v_signal,
    output logic systolic_flow_h_signal,
    output logic systolic_broad_v_signal,
    output logic systolic_broad_h_signal
);
    localparam int A_LANE_COUNT = A_DATAWIDTH / SYSTOLIC_UNITWIDTH;
    localparam int B_LANE_COUNT = B_DATAWIDTH / SYSTOLIC_UNITWIDTH;
    localparam int A_LANE_SEL_WIDTH = (A_LANE_COUNT > 1)
        ? $clog2(A_LANE_COUNT) : 1;
    localparam int B_SEL_WIDTH = (B_BANKS > 1) ? $clog2(B_BANKS) : 1;
    localparam int K_COUNTER_WIDTH = 16;
    localparam logic [K_COUNTER_WIDTH-1:0] LAST_GEMM_K
        = K_COUNTER_WIDTH'(SYSTOLIC_WIDTH - 1);

    logic [3:0] fsm_status;
    logic cnn_mode;
    logic [A_LANE_SEL_WIDTH-1:0] a_col_sel;
    logic [A_LANE_SEL_WIDTH-1:0] a_lane_sel [0:A_BANKS-1];
    logic [A_BANKS-1:0] a_zero_lane;
    logic [B_SEL_WIDTH-1:0] b_bank_sel;
    logic [K_COUNTER_WIDTH-1:0] k_counter;
    logic [$clog2(A_BANKS)-1:0] setup_row;
    logic [15:0] setup_output_x;
    logic [15:0] setup_output_y;

    // CNN addresses are generated incrementally.  The old implementation
    // expanded variable multiply/divide/modulo expressions three times per
    // bank in the RUN state.  These registered setup values remove that long
    // combinational path while preserving one K step per clock once primed.
    logic signed [31:0] row_input_x [0:A_BANKS-1];
    logic signed [31:0] row_input_y [0:A_BANKS-1];
    logic row_output_valid [0:A_BANKS-1];
    logic signed [47:0] spatial_index [0:A_BANKS-1];
    logic signed [47:0] channel_offset;
    logic signed [47:0] image_plane;
    logic cnn_geometry_valid;
    logic [15:0] cnn_channel_counter;
    logic [7:0] cnn_kernel_x_counter;
    logic [7:0] cnn_kernel_y_counter;

    assign busy = (fsm_status != 0);
    assign systolic_flow_v_signal = busy;
    assign systolic_flow_h_signal = busy;
    assign systolic_broad_v_signal = 1'b1;
    assign systolic_broad_h_signal = 1'b1;

    function automatic logic cnn_coordinate_valid(
        input logic signed [31:0] x,
        input logic signed [31:0] y
    );
        cnn_coordinate_valid = (x >= 0) && (x < $signed({1'b0, cnn_input_width}))
                               && (y >= 0) && (y < $signed({1'b0, cnn_input_height}));
    endfunction

    generate
        for (genvar y = 0; y < SYSTOLIC_HEIGHT; y++) begin : vertical_lanes
            if (y < A_BANKS) begin : valid_bank
                always_comb begin
                    if (cnn_mode && a_zero_lane[y]) begin
                        systolic_vertical_bar[y] = '0;
                    end else if (cnn_mode) begin
                        systolic_vertical_bar[y]
                            = a_data[y][a_lane_sel[y]*SYSTOLIC_UNITWIDTH
                                       +: SYSTOLIC_UNITWIDTH];
                    end else begin
                        systolic_vertical_bar[y]
                            = a_data[y][a_col_sel*SYSTOLIC_UNITWIDTH
                                       +: SYSTOLIC_UNITWIDTH];
                    end
                end
            end else begin : missing_bank
                always_comb systolic_vertical_bar[y] = '0;
            end
        end

        for (genvar x = 0; x < SYSTOLIC_WIDTH; x++) begin : horizontal_lanes
            if (x < B_LANE_COUNT) begin : valid_lane
                always_comb begin
                    systolic_horizontal_bar[x]
                        = b_data[b_bank_sel][x*SYSTOLIC_UNITWIDTH
                                           +: SYSTOLIC_UNITWIDTH];
                end
            end else begin : missing_lane
                always_comb systolic_horizontal_bar[x] = '0;
            end
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_status <= 0;
            cnn_mode <= 1'b0;
            a_col_sel <= '0;
            b_bank_sel <= '0;
            k_counter <= '0;
            setup_row <= '0;
            setup_output_x <= '0;
            setup_output_y <= '0;
            channel_offset <= '0;
            image_plane <= '0;
            cnn_geometry_valid <= 1'b0;
            cnn_channel_counter <= '0;
            cnn_kernel_x_counter <= '0;
            cnn_kernel_y_counter <= '0;
            systolic_add_signal <= 1'b0;
            a_zero_lane <= '0;
            for (int i = 0; i < A_BANKS; i++) begin
                a_addr[i] <= '0;
                a_lane_sel[i] <= '0;
                row_input_x[i] <= '0;
                row_input_y[i] <= '0;
                row_output_valid[i] <= 1'b0;
                spatial_index[i] <= '0;
            end
            for (int i = 0; i < B_BANKS; i++) begin
                b_addr[i] <= '0;
            end
        end else begin
            case (fsm_status)
                0: begin
                    systolic_add_signal <= 1'b0;
                    if (fire) begin
                        cnn_mode <= 1'b0;
                        fsm_status <= 1;
                        a_col_sel <= '0;
                        b_bank_sel <= '0;
                        k_counter <= '0;
                        for (int i = 0; i < A_BANKS; i++) begin
                            a_addr[i] <= a_mat_base_offset;
                            a_lane_sel[i] <= '0;
                            a_zero_lane[i] <= 1'b0;
                        end
                        for (int i = 0; i < B_BANKS; i++) begin
                            b_addr[i] <= b_mat_base_offset;
                        end
                    end else if (cnn_fire && (cnn_k_total != 0)) begin
                        cnn_mode <= 1'b1;
                        // Set up one output row per cycle.  This turns output
                        // row wrapping into a compare/increment rather than a
                        // variable divide and modulo operation.
                        fsm_status <= 8;
                        k_counter <= '0;
                        b_bank_sel <= '0;
                        setup_row <= '0;
                        setup_output_x <= cnn_output_x;
                        setup_output_y <= cnn_output_y;
                    end
                end

                // One BRAM cycle to capture the first operands.  At this edge
                // the BRAM still sees k=0; pre-issue k=1 so its response is
                // available for the second MAC step.
                1: begin
                    fsm_status <= 2;
                end

                // One MAC step per cycle.  The next address/lane is written at
                // the same edge that consumes the current BRAM output.
                2: begin
                    systolic_add_signal <= 1'b1;
                    if (cnn_mode) begin
                        if (k_counter == cnn_k_total - 1'b1) begin
                            fsm_status <= 3;
                        end else begin
                            k_counter <= k_counter + 1'b1;
                            b_bank_sel <= B_SEL_WIDTH'((k_counter + 1'b1)
                                                       % B_BANKS);
                            for (int i = 0; i < A_BANKS; i++) begin
                                if (i < SYSTOLIC_HEIGHT) begin
                                    a_lane_sel[i] <= A_LANE_SEL_WIDTH'(
                                        (spatial_index[i] + channel_offset)
                                        % A_LANE_COUNT);
                                    a_zero_lane[i] <= !cnn_coordinate_valid(
                                        row_input_x[i], row_input_y[i])
                                        || !row_output_valid[i];
                                    if ((k_counter + 2) < cnn_k_total) begin
                                        if ((cnn_channel_counter + 1'b1)
                                            < cnn_input_channels) begin
                                            a_addr[i] <= cnn_input_base
                                                + A_ADDRWIDTH'((spatial_index[i]
                                                    + channel_offset
                                                    + image_plane)
                                                    / A_LANE_COUNT);
                                        end else if ((cnn_kernel_x_counter + 1'b1)
                                                     < cnn_kernel_width) begin
                                            a_addr[i] <= cnn_input_base
                                                + A_ADDRWIDTH'((spatial_index[i] + 1)
                                                    / A_LANE_COUNT);
                                        end else begin
                                            a_addr[i] <= cnn_input_base
                                                + A_ADDRWIDTH'((spatial_index[i]
                                                    + $signed({1'b0, cnn_input_width})
                                                    - $signed({1'b0, cnn_kernel_width})
                                                    + 1) / A_LANE_COUNT);
                                        end
                                    end
                                end
                            end
                            if ((k_counter + 2) < cnn_k_total) begin
                                for (int i = 0; i < B_BANKS; i++) begin
                                    b_addr[i] <= cnn_weight_base
                                        + B_ADDRWIDTH'((k_counter + 2)
                                                       / B_BANKS);
                                end
                            end

                            // Advance the compact CHW/kernel descriptor used
                            // to form the following cycle's address.
                            if ((cnn_channel_counter + 1'b1)
                                < cnn_input_channels) begin
                                cnn_channel_counter <= cnn_channel_counter + 1'b1;
                                channel_offset <= channel_offset + image_plane;
                            end else begin
                                cnn_channel_counter <= '0;
                                channel_offset <= '0;
                                if ((cnn_kernel_x_counter + 1'b1)
                                    < cnn_kernel_width) begin
                                    cnn_kernel_x_counter
                                        <= cnn_kernel_x_counter + 1'b1;
                                    for (int i = 0; i < A_BANKS; i++) begin
                                        row_input_x[i] <= row_input_x[i] + 1;
                                        spatial_index[i] <= spatial_index[i] + 1;
                                    end
                                end else begin
                                    cnn_kernel_x_counter <= '0;
                                    cnn_kernel_y_counter
                                        <= cnn_kernel_y_counter + 1'b1;
                                    for (int i = 0; i < A_BANKS; i++) begin
                                        row_input_x[i] <= row_input_x[i]
                                            - $signed({1'b0, cnn_kernel_width}) + 1;
                                        row_input_y[i] <= row_input_y[i] + 1;
                                        spatial_index[i] <= spatial_index[i]
                                            + $signed({1'b0, cnn_input_width})
                                            - $signed({1'b0, cnn_kernel_width}) + 1;
                                    end
                                end
                            end
                        end
                    end else begin
                        a_col_sel <= a_col_sel + 1'b1;
                        b_bank_sel <= b_bank_sel + 1'b1;
                        if (k_counter == LAST_GEMM_K) begin
                            fsm_status <= 3;
                        end else begin
                            k_counter <= k_counter + 1'b1;
                        end
                    end
                end

                3: begin
                    systolic_add_signal <= 1'b0;
                    fsm_status <= 0;
                end

                // CNN setup pipeline.  The launch latency grows by nineteen
                // clocks, but the steady-state MAC rate remains one K step
                // per clock and no divider is present in the RUN path.
                4: begin
                    row_input_x[setup_row] <=
                        $signed({1'b0, setup_output_x})
                        * $signed({1'b0, cnn_stride_x})
                        - $signed({1'b0, cnn_pad_left});
                    row_input_y[setup_row] <=
                        $signed({1'b0, setup_output_y})
                        * $signed({1'b0, cnn_stride_y})
                        - $signed({1'b0, cnn_pad_top});
                    fsm_status <= 9;
                end

                5: begin
                    for (int i = 0; i < A_BANKS; i++) begin
                        spatial_index[i] <= row_input_y[i]
                            * $signed({1'b0, cnn_input_width}) + row_input_x[i];
                    end
                    fsm_status <= 6;
                end

                6: begin
                    channel_offset <= '0;
                    cnn_channel_counter <= '0;
                    cnn_kernel_x_counter <= '0;
                    cnn_kernel_y_counter <= '0;
                    for (int i = 0; i < A_BANKS; i++) begin
                        if (i < SYSTOLIC_HEIGHT) begin
                            a_addr[i] <= cnn_input_base
                                + A_ADDRWIDTH'(spatial_index[i] / A_LANE_COUNT);
                            a_lane_sel[i] <= A_LANE_SEL_WIDTH'(
                                spatial_index[i] % A_LANE_COUNT);
                            a_zero_lane[i] <= !cnn_coordinate_valid(
                                row_input_x[i], row_input_y[i])
                                || !row_output_valid[i];
                        end else begin
                            a_addr[i] <= '0;
                            a_lane_sel[i] <= '0;
                            a_zero_lane[i] <= 1'b1;
                        end
                    end
                    for (int i = 0; i < B_BANKS; i++) begin
                        b_addr[i] <= cnn_weight_base;
                    end
                    fsm_status <= 7;
                end

                7: begin
                    // Pre-issue k=1 while retaining the k=0 lane selection.
                    if (cnn_k_total > 1) begin
                        if (cnn_input_channels > 1) begin
                            channel_offset <= image_plane;
                            cnn_channel_counter <= 1;
                            for (int i = 0; i < A_BANKS; i++) begin
                                a_addr[i] <= cnn_input_base
                                    + A_ADDRWIDTH'((spatial_index[i] + image_plane)
                                                   / A_LANE_COUNT);
                            end
                        end else if (cnn_kernel_width > 1) begin
                            cnn_kernel_x_counter <= 1;
                            for (int i = 0; i < A_BANKS; i++) begin
                                row_input_x[i] <= row_input_x[i] + 1;
                                spatial_index[i] <= spatial_index[i] + 1;
                                a_addr[i] <= cnn_input_base
                                    + A_ADDRWIDTH'((spatial_index[i] + 1)
                                                   / A_LANE_COUNT);
                            end
                        end else begin
                            cnn_kernel_y_counter <= 1;
                            for (int i = 0; i < A_BANKS; i++) begin
                                row_input_y[i] <= row_input_y[i] + 1;
                                spatial_index[i] <= spatial_index[i]
                                    + $signed({1'b0, cnn_input_width});
                                a_addr[i] <= cnn_input_base
                                    + A_ADDRWIDTH'((spatial_index[i]
                                        + $signed({1'b0, cnn_input_width}))
                                        / A_LANE_COUNT);
                            end
                        end
                    end
                    fsm_status <= 2;
                end

                // Register geometry terms before the per-row multiply/compare
                // stage.  Besides shortening the data path, this prevents
                // synthesis from folding the kernel-size test into the row
                // coordinate registers' clock enables.
                8: begin
                    image_plane <= $signed({1'b0, cnn_input_width})
                                   * $signed({1'b0, cnn_input_height});
                    cnn_geometry_valid <=
                        (cnn_stride_x != 0) && (cnn_stride_y != 0)
                        && (cnn_input_width != 0) && (cnn_input_height != 0)
                        && (cnn_input_channels != 0)
                        && (cnn_kernel_width != 0) && (cnn_kernel_height != 0)
                        && ((cnn_input_width + cnn_pad_left + cnn_pad_right)
                            >= cnn_kernel_width)
                        && ((cnn_input_height + cnn_pad_top + cnn_pad_bottom)
                            >= cnn_kernel_height);
                    fsm_status <= 4;
                end

                // Validate the registered input origin in a separate cycle.
                // This avoids a multiplier-plus-wide-compare path and leaves
                // only add/compare logic between setup registers.
                9: begin
                    row_output_valid[setup_row] <= cnn_geometry_valid
                        && ((row_input_x[setup_row]
                             + $signed({1'b0, cnn_kernel_width}))
                            <= ($signed({1'b0, cnn_input_width})
                                + $signed({1'b0, cnn_pad_right})))
                        && ((row_input_y[setup_row]
                             + $signed({1'b0, cnn_kernel_height}))
                            <= ($signed({1'b0, cnn_input_height})
                                + $signed({1'b0, cnn_pad_bottom})));
                    if (setup_row == A_BANKS-1) begin
                        fsm_status <= 5;
                    end else begin
                        setup_row <= setup_row + 1'b1;
                        if ((setup_output_x + 1'b1) >= cnn_output_width) begin
                            setup_output_x <= '0;
                            setup_output_y <= setup_output_y + 1'b1;
                        end else begin
                            setup_output_x <= setup_output_x + 1'b1;
                        end
                        fsm_status <= 4;
                    end
                end

                default: begin
                    fsm_status <= 0;
                end
            endcase
        end
    end

    initial begin
        if ((A_DATAWIDTH % SYSTOLIC_UNITWIDTH) != 0
            || (B_DATAWIDTH % SYSTOLIC_UNITWIDTH) != 0) begin
            $error("launcher word width must be divisible by unit width");
        end
        if (A_LANE_COUNT < 1 || B_LANE_COUNT < SYSTOLIC_WIDTH) begin
            $error("launcher does not have enough packed operand lanes");
        end
    end

endmodule
