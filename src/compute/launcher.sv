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

    logic [1:0] fsm_status;
    logic cnn_mode;
    logic [A_LANE_SEL_WIDTH-1:0] a_col_sel;
    logic [A_LANE_SEL_WIDTH-1:0] a_lane_sel [0:A_BANKS-1];
    logic [A_BANKS-1:0] a_zero_lane;
    logic [B_SEL_WIDTH-1:0] b_bank_sel;
    logic [K_COUNTER_WIDTH-1:0] k_counter;

    assign busy = (fsm_status != 0);
    assign systolic_flow_v_signal = busy;
    assign systolic_flow_h_signal = busy;
    assign systolic_broad_v_signal = 1'b1;
    assign systolic_broad_h_signal = 1'b1;

    // Return the CHW element selected by an im2col row and K index.  A bank
    // stores a complete logical input image; all eight banks are populated by
    // the CNN input loader so the eight output positions can be read in
    // parallel from independent BRAMs.
    /* verilator lint_off WIDTHEXPAND */
    function automatic integer cnn_input_element(
        input integer row,
        input integer k
    );
        integer output_linear;
        integer output_x;
        integer output_y;
        integer kernel_linear;
        integer kernel_x;
        integer kernel_y;
        integer channel;
        integer input_x;
        integer input_y;
        integer output_width_calc;
        integer output_height_calc;
        begin
            cnn_input_element = -1;
            if ((cnn_output_width != 0)
                && (cnn_input_width != 0)
                && (cnn_input_height != 0)
                && (cnn_input_channels != 0)
                && (cnn_kernel_width != 0)
                && (cnn_kernel_height != 0)) begin
                output_linear = cnn_output_y * cnn_output_width
                                + cnn_output_x + row;
                output_y = output_linear / cnn_output_width;
                output_x = output_linear % cnn_output_width;
                output_width_calc = 0;
                output_height_calc = 0;
                if ((cnn_stride_x != 0) && (cnn_stride_y != 0)
                    && (cnn_input_width + cnn_pad_left + cnn_pad_right
                        >= cnn_kernel_width)
                    && (cnn_input_height + cnn_pad_top + cnn_pad_bottom
                        >= cnn_kernel_height)) begin
                    output_width_calc
                        = (cnn_input_width + cnn_pad_left + cnn_pad_right
                           - cnn_kernel_width) / cnn_stride_x + 1;
                    output_height_calc
                        = (cnn_input_height + cnn_pad_top + cnn_pad_bottom
                           - cnn_kernel_height) / cnn_stride_y + 1;
                end
                channel = k % cnn_input_channels;
                kernel_linear = k / cnn_input_channels;
                kernel_x = kernel_linear % cnn_kernel_width;
                kernel_y = kernel_linear / cnn_kernel_width;
                input_x = output_x * cnn_stride_x + kernel_x
                          - cnn_pad_left;
                input_y = output_y * cnn_stride_y + kernel_y
                          - cnn_pad_top;

                if ((k < 0)
                    || (k >= cnn_k_total)
                    || (kernel_y >= cnn_kernel_height)
                    || (output_width_calc == 0)
                    || (output_height_calc == 0)
                    || (output_linear >= output_width_calc * output_height_calc)
                    || (input_x < 0) || (input_x >= cnn_input_width)
                    || (input_y < 0) || (input_y >= cnn_input_height)) begin
                    cnn_input_element = -1;
                end else begin
                    cnn_input_element
                        = (channel * cnn_input_height + input_y)
                          * cnn_input_width + input_x;
                end
            end
        end
    endfunction

    function automatic [A_ADDRWIDTH-1:0] cnn_a_address(
        input integer row,
        input integer k
    );
        integer element;
        begin
            element = cnn_input_element(row, k);
            if (element < 0) begin
                cnn_a_address = '0;
            end else begin
                cnn_a_address = cnn_input_base
                    + A_ADDRWIDTH'(element / A_LANE_COUNT);
            end
        end
    endfunction

    function automatic [A_LANE_SEL_WIDTH-1:0] cnn_a_lane(
        input integer row,
        input integer k
    );
        integer element;
        begin
            element = cnn_input_element(row, k);
            if (element < 0) begin
                cnn_a_lane = '0;
            end else begin
                cnn_a_lane = A_LANE_SEL_WIDTH'(element % A_LANE_COUNT);
            end
        end
    endfunction

    function automatic logic cnn_a_zero(
        input integer row,
        input integer k
    );
        begin
            cnn_a_zero = (cnn_input_element(row, k) < 0);
        end
    endfunction
    /* verilator lint_on WIDTHEXPAND */

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
            systolic_add_signal <= 1'b0;
            a_zero_lane <= '0;
            for (int i = 0; i < A_BANKS; i++) begin
                a_addr[i] <= '0;
                a_lane_sel[i] <= '0;
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
                        fsm_status <= 1;
                        k_counter <= '0;
                        b_bank_sel <= '0;
                        for (int i = 0; i < A_BANKS; i++) begin
                            if (i < SYSTOLIC_HEIGHT) begin
                                a_addr[i] <= cnn_a_address(i, 0);
                                a_lane_sel[i] <= cnn_a_lane(i, 0);
                                a_zero_lane[i] <= cnn_a_zero(i, 0);
                            end else begin
                                a_addr[i] <= '0;
                                a_lane_sel[i] <= '0;
                                a_zero_lane[i] <= 1'b1;
                            end
                        end
                        for (int i = 0; i < B_BANKS; i++) begin
                            b_addr[i] <= cnn_weight_base;
                        end
                    end
                end

                // One BRAM cycle to capture the first operands.  At this edge
                // the BRAM still sees k=0; pre-issue k=1 so its response is
                // available for the second MAC step.
                1: begin
                    if (cnn_mode && (cnn_k_total > 1)) begin
                        for (int i = 0; i < A_BANKS; i++) begin
                            if (i < SYSTOLIC_HEIGHT) begin
                                a_addr[i] <= cnn_a_address(i, 1);
                            end
                        end
                        for (int i = 0; i < B_BANKS; i++) begin
                            b_addr[i] <= cnn_weight_base
                                + B_ADDRWIDTH'(1 / B_BANKS);
                        end
                    end
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
                            b_bank_sel <= B_SEL_WIDTH'((int'(k_counter) + 1)
                                                       % B_BANKS);
                            for (int i = 0; i < A_BANKS; i++) begin
                                if (i < SYSTOLIC_HEIGHT) begin
                                    a_lane_sel[i]
                                        <= cnn_a_lane(i, int'(k_counter) + 1);
                                    a_zero_lane[i]
                                        <= cnn_a_zero(i, int'(k_counter) + 1);
                                    if ((k_counter + 2) < cnn_k_total) begin
                                        a_addr[i] <= cnn_a_address(
                                            i, int'(k_counter) + 2);
                                    end
                                end
                            end
                            if ((k_counter + 2) < cnn_k_total) begin
                                for (int i = 0; i < B_BANKS; i++) begin
                                    b_addr[i] <= cnn_weight_base
                                        + B_ADDRWIDTH'((int'(k_counter) + 2)
                                                       / B_BANKS);
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
