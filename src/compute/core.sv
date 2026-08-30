// Top-level compute core.
//
// The device side is a packet stream.  The address is kept together with the
// data in the ingress FIFO, so a backpressured device cannot separate a write
// address from its payload.  The memory map is:
//
//   0x0bbb_aaaa : A bank write (bbb = bank, aaaa = word address)
//   0x1bbb_aaaa : B bank write
//   0x2bbb_aaaa : C bank write/readback storage
//   0xf000_0010 : A matrix base offset
//   0xf000_0014 : B matrix base offset
//   0xf000_0018 : C result base offset
//   0xf000_0000 : command, data[3:0] == 1 starts DMA, 2 launches compute
//   0xf000_0020 : DMA config (data[1:0] = 0 external, 1 A, 2 B)
//   0xf000_0024 : DMA source C address
//   0xf000_0028 : DMA destination A/B address
//   0xf000_002c : DMA transfer length
//   0xf000_0030 : DMA starting destination bank (increments per transferred row)
//   0xf000_0040 : CNN control (bit 0 replicates A input writes to all A banks)
//   0xf000_0044 : CNN input base (CHW, packed by eight INT8 values)
//   0xf000_0048 : CNN weight base (K-major, eight output channels per word)
//   0xf000_004c : CNN input width
//   0xf000_0050 : CNN input height
//   0xf000_0054 : CNN input channels
//   0xf000_0058 : CNN kernel width/height (low/high 8 bits)
//   0xf000_005c : CNN stride x/y (low/high 16 bits)
//   0xf000_0060 : CNN padding left/right (low/high 8 bits)
//   0xf000_0064 : CNN padding top/bottom (low/high 8 bits)
//   0xf000_0068 : CNN output tile origin x/y (low/high 16 bits)
//   0xf000_006c : CNN output width
//   0xf000_0000 : command, data[3:0] == 3 starts an im2col CNN tile
//
// A, B and C each consist of eight BRAM banks.  A and B are read by the
// launcher; C receives one byte per bank on every result-drain cycle. Results
// leave C only through an explicit DMA request.

module core #(
    parameter int DATA_WIDTH       = 64,
    parameter int ADDR_WIDTH       = 9,
    parameter int BANKS            = 8,
    parameter int FIFO_DEPTH       = 16,
    parameter int SYSTOLIC_WIDTH   = 8,
    parameter int SYSTOLIC_HEIGHT  = 8,
    parameter int SYSTOLIC_UNITWIDTH = 8
)(
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic [DATA_WIDTH-1:0] dev_data_in,
    input  logic [31:0]           dev_addr_in,
    input  logic                  dev_data_in_valid,
    output logic                  dev_data_in_ready,

    output logic [DATA_WIDTH-1:0] dev_data_out,
    output logic                  dev_data_out_valid,
    input  logic                  dev_data_out_ready
);

    localparam int BANK_SEL_WIDTH = (BANKS > 1) ? $clog2(BANKS) : 1;
    localparam int PACKET_WIDTH   = DATA_WIDTH + 32;

    localparam logic [31:0] COMMAND_ADDR   = 32'hf000_0000;
    localparam logic [31:0] A_BASE_REG     = 32'hf000_0010;
    localparam logic [31:0] B_BASE_REG     = 32'hf000_0014;
    localparam logic [31:0] C_BASE_REG     = 32'hf000_0018;
    localparam logic [31:0] DMA_CONFIG_REG = 32'hf000_0020;
    localparam logic [31:0] DMA_SOURCE_REG = 32'hf000_0024;
    localparam logic [31:0] DMA_DEST_REG   = 32'hf000_0028;
    localparam logic [31:0] DMA_LENGTH_REG = 32'hf000_002c;
    localparam logic [31:0] DMA_BANK_REG   = 32'hf000_0030;
    localparam logic [31:0] CNN_CONTROL_REG = 32'hf000_0040;
    localparam logic [31:0] CNN_INPUT_BASE_REG = 32'hf000_0044;
    localparam logic [31:0] CNN_WEIGHT_BASE_REG = 32'hf000_0048;
    localparam logic [31:0] CNN_INPUT_WIDTH_REG = 32'hf000_004c;
    localparam logic [31:0] CNN_INPUT_HEIGHT_REG = 32'hf000_0050;
    localparam logic [31:0] CNN_INPUT_CHANNELS_REG = 32'hf000_0054;
    localparam logic [31:0] CNN_KERNEL_REG = 32'hf000_0058;
    localparam logic [31:0] CNN_STRIDE_REG = 32'hf000_005c;
    localparam logic [31:0] CNN_PAD_X_REG = 32'hf000_0060;
    localparam logic [31:0] CNN_PAD_Y_REG = 32'hf000_0064;
    localparam logic [31:0] CNN_OUTPUT_ORIGIN_REG = 32'hf000_0068;
    localparam logic [31:0] CNN_OUTPUT_WIDTH_REG = 32'hf000_006c;
    localparam logic [3:0]  DMA_MODE       = 4'd1;
    localparam logic [ADDR_WIDTH:0] DEFAULT_DMA_LENGTH
        = (ADDR_WIDTH + 1)'(SYSTOLIC_HEIGHT);
    localparam logic [3:0]  LAUNCH_MODE    = 4'd2;
    localparam logic [3:0]  CNN_MODE       = 4'd3;
    localparam logic [3:0]  LAST_DRAIN_STEP = 4'(SYSTOLIC_HEIGHT - 1);

    logic [ADDR_WIDTH-1:0] a_mat_base_offset;
    logic [ADDR_WIDTH-1:0] b_mat_base_offset;
    logic [ADDR_WIDTH-1:0] c_mat_base_offset;
    logic [1:0] dma_destination;
    logic [ADDR_WIDTH-1:0] dma_source_base;
    logic [ADDR_WIDTH-1:0] dma_destination_base;
    logic [ADDR_WIDTH:0] dma_transfer_length;
    logic [BANK_SEL_WIDTH-1:0] dma_destination_bank;
    logic cnn_input_broadcast;
    logic [ADDR_WIDTH-1:0] cnn_input_base;
    logic [ADDR_WIDTH-1:0] cnn_weight_base;
    logic [15:0] cnn_input_width;
    logic [15:0] cnn_input_height;
    logic [15:0] cnn_input_channels;
    logic [7:0] cnn_kernel_width;
    logic [7:0] cnn_kernel_height;
    logic [15:0] cnn_stride_x;
    logic [15:0] cnn_stride_y;
    logic [7:0] cnn_pad_left;
    logic [7:0] cnn_pad_right;
    logic [7:0] cnn_pad_top;
    logic [7:0] cnn_pad_bottom;
    logic [15:0] cnn_output_x;
    logic [15:0] cnn_output_y;
    logic [15:0] cnn_output_width;
    logic [15:0] cnn_k_product;
    logic [15:0] cnn_k_total;
    assign cnn_k_product = cnn_kernel_width * cnn_kernel_height
                           * cnn_input_channels;
    assign cnn_k_total = cnn_k_product;

    logic [PACKET_WIDTH-1:0] ingress_data_in;
    logic                    ingress_valid_in;
    logic                    ingress_ready_in;
    logic [PACKET_WIDTH-1:0] ingress_data_out;
    logic                    ingress_valid_out;
    logic                    ingress_ready_out;

    assign ingress_data_in = {dev_addr_in, dev_data_in};
    assign ingress_valid_in = dev_data_in_valid;
    assign dev_data_in_ready = ingress_ready_in;

    fifo #(
        .DATA_WIDTH(PACKET_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) ingress_fifo (
        .clk          (clk),
        .rst_n        (rst_n),
        .data_in     (ingress_data_in),
        .data_in_valid(ingress_valid_in),
        .data_in_ready(ingress_ready_in),
        .data_out    (ingress_data_out),
        .data_out_valid(ingress_valid_out),
        .data_out_ready(ingress_ready_out)
    );

    logic [31:0]           packet_addr;
    logic [DATA_WIDTH-1:0] packet_data;
    logic [3:0]            packet_mode;
    logic [BANK_SEL_WIDTH-1:0] packet_bank;
    logic [ADDR_WIDTH-1:0] packet_word_addr;

    assign packet_addr     = ingress_data_out[PACKET_WIDTH-1 -: 32];
    assign packet_data     = ingress_data_out[DATA_WIDTH-1:0];
    assign packet_mode     = packet_data[3:0];
    assign packet_bank     = packet_addr[ADDR_WIDTH + BANK_SEL_WIDTH - 1 -: BANK_SEL_WIDTH];
    assign packet_word_addr = packet_addr[ADDR_WIDTH-1:0];

    logic packet_is_command;
    logic packet_is_a_write;
    logic packet_is_b_write;
    logic packet_is_c_write;
    logic packet_is_launch;
    logic packet_is_dma_start;
    logic packet_is_cnn;
    logic packet_accept;
    logic ingress_pop;

    assign packet_is_command = (packet_addr == COMMAND_ADDR);
    assign packet_is_a_write = (packet_addr[31:28] == 4'h0);
    assign packet_is_b_write = (packet_addr[31:28] == 4'h1);
    assign packet_is_c_write = (packet_addr[31:28] == 4'h2);
    assign packet_is_launch = packet_is_command && (packet_mode == LAUNCH_MODE);
    assign packet_is_dma_start = packet_is_command && (packet_mode == DMA_MODE);
    assign packet_is_cnn = packet_is_command && (packet_mode == CNN_MODE);

    // A launch command stays at the FIFO head until the current operation has
    // completely drained.  All ordinary writes/configuration packets can be
    // consumed while the array is running.
    logic launcher_busy;
    logic drain_active;
    logic dma_busy;
    assign packet_accept = ingress_valid_out
        && (!packet_is_launch || (!launcher_busy && !drain_active && !dma_busy))
        && (!packet_is_dma_start || (!launcher_busy && !drain_active && !dma_busy))
        && (!packet_is_cnn || (!launcher_busy && !drain_active && !dma_busy
                               && (cnn_k_total != 0)))
        && (!packet_is_c_write || !drain_active)
        && (!(packet_is_a_write || packet_is_b_write || packet_is_c_write) || !dma_busy);
    assign ingress_ready_out = packet_accept;
    assign ingress_pop = packet_accept;

    logic launcher_fire;
    assign launcher_fire = ingress_pop && packet_is_launch;
    logic dma_request;
    assign dma_request = ingress_pop && packet_is_dma_start;
    logic cnn_fire;
    assign cnn_fire = ingress_pop && packet_is_cnn;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_mat_base_offset <= '0;
            b_mat_base_offset <= '0;
            c_mat_base_offset <= '0;
            dma_destination <= 2'd0;
            dma_source_base <= '0;
            dma_destination_base <= '0;
            dma_transfer_length <= DEFAULT_DMA_LENGTH;
            dma_destination_bank <= '0;
            cnn_input_broadcast <= 1'b0;
            cnn_input_base <= '0;
            cnn_weight_base <= '0;
            cnn_input_width <= '0;
            cnn_input_height <= '0;
            cnn_input_channels <= '0;
            cnn_kernel_width <= '0;
            cnn_kernel_height <= '0;
            cnn_stride_x <= 1;
            cnn_stride_y <= 1;
            cnn_pad_left <= '0;
            cnn_pad_right <= '0;
            cnn_pad_top <= '0;
            cnn_pad_bottom <= '0;
            cnn_output_x <= '0;
            cnn_output_y <= '0;
            cnn_output_width <= '0;
        end else if (ingress_pop) begin
            if (packet_addr == A_BASE_REG) begin
                a_mat_base_offset <= packet_data[ADDR_WIDTH-1:0];
            end else if (packet_addr == B_BASE_REG) begin
                b_mat_base_offset <= packet_data[ADDR_WIDTH-1:0];
            end else if (packet_addr == C_BASE_REG) begin
                c_mat_base_offset <= packet_data[ADDR_WIDTH-1:0];
                dma_source_base <= packet_data[ADDR_WIDTH-1:0];
            end else if (packet_addr == DMA_CONFIG_REG) begin
                dma_destination <= packet_data[1:0];
            end else if (packet_addr == DMA_SOURCE_REG) begin
                dma_source_base <= packet_data[ADDR_WIDTH-1:0];
            end else if (packet_addr == DMA_DEST_REG) begin
                dma_destination_base <= packet_data[ADDR_WIDTH-1:0];
            end else if (packet_addr == DMA_LENGTH_REG) begin
                dma_transfer_length <= packet_data[ADDR_WIDTH:0];
            end else if (packet_addr == DMA_BANK_REG) begin
                dma_destination_bank <= packet_data[BANK_SEL_WIDTH-1:0];
            end else if (packet_addr == CNN_CONTROL_REG) begin
                cnn_input_broadcast <= packet_data[0];
            end else if (packet_addr == CNN_INPUT_BASE_REG) begin
                cnn_input_base <= packet_data[ADDR_WIDTH-1:0];
            end else if (packet_addr == CNN_WEIGHT_BASE_REG) begin
                cnn_weight_base <= packet_data[ADDR_WIDTH-1:0];
            end else if (packet_addr == CNN_INPUT_WIDTH_REG) begin
                cnn_input_width <= packet_data[15:0];
            end else if (packet_addr == CNN_INPUT_HEIGHT_REG) begin
                cnn_input_height <= packet_data[15:0];
            end else if (packet_addr == CNN_INPUT_CHANNELS_REG) begin
                cnn_input_channels <= packet_data[15:0];
            end else if (packet_addr == CNN_KERNEL_REG) begin
                cnn_kernel_width <= packet_data[7:0];
                cnn_kernel_height <= packet_data[15:8];
            end else if (packet_addr == CNN_STRIDE_REG) begin
                cnn_stride_x <= packet_data[15:0];
                cnn_stride_y <= packet_data[31:16];
            end else if (packet_addr == CNN_PAD_X_REG) begin
                cnn_pad_left <= packet_data[7:0];
                cnn_pad_right <= packet_data[15:8];
            end else if (packet_addr == CNN_PAD_Y_REG) begin
                cnn_pad_top <= packet_data[7:0];
                cnn_pad_bottom <= packet_data[15:8];
            end else if (packet_addr == CNN_OUTPUT_ORIGIN_REG) begin
                cnn_output_x <= packet_data[15:0];
                cnn_output_y <= packet_data[31:16];
            end else if (packet_addr == CNN_OUTPUT_WIDTH_REG) begin
                cnn_output_width <= packet_data[15:0];
            end
        end
    end

    logic [ADDR_WIDTH-1:0] a_addr [0:BANKS-1];
    logic [DATA_WIDTH-1:0] a_data [0:BANKS-1];
    logic [ADDR_WIDTH-1:0] b_addr [0:BANKS-1];
    logic [DATA_WIDTH-1:0] b_data [0:BANKS-1];

    logic [ADDR_WIDTH-1:0] c_write_addr;
    // C is the DMA source; its read data is packed by compute_dma.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [DATA_WIDTH-1:0] c_data_out [0:BANKS-1];
    /* verilator lint_on UNUSEDSIGNAL */
    logic [DATA_WIDTH-1:0] c_write_data [0:BANKS-1];
    logic                  drain_request_valid;
    logic                  drain_capture_valid;
    logic [ADDR_WIDTH-1:0] c_read_addr;
    logic                  dma_a_write_enable;
    logic                  dma_b_write_enable;
    logic [BANK_SEL_WIDTH-1:0] dma_write_bank;
    logic [ADDR_WIDTH-1:0] dma_write_addr;
    logic [DATA_WIDTH-1:0] dma_write_data;

    logic a_write_enable;
    logic b_write_enable;
    logic c_host_write_enable;

    assign a_write_enable = ingress_pop && packet_is_a_write;
    assign b_write_enable = ingress_pop && packet_is_b_write;
    assign c_host_write_enable = ingress_pop && packet_is_c_write && !drain_active;

    generate
        genvar bank;
        for (bank = 0; bank < BANKS; bank = bank + 1) begin : a_bram_banks
            bram #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH)
            ) bank_memory (
                .clk     (clk),
                .addr_in (dma_a_write_enable ? dma_write_addr : packet_word_addr),
                .data_in (dma_a_write_enable ? dma_write_data : packet_data),
                .we      (dma_a_write_enable ? (dma_write_bank == bank)
                          : (a_write_enable
                             && (cnn_input_broadcast || (packet_bank == bank)))),
                .addr_out(a_addr[bank]),
                .data_out(a_data[bank])
            );
        end

        for (bank = 0; bank < BANKS; bank = bank + 1) begin : b_bram_banks
            bram #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH)
            ) bank_memory (
                .clk     (clk),
                .addr_in (dma_b_write_enable ? dma_write_addr : packet_word_addr),
                .data_in (dma_b_write_enable ? dma_write_data : packet_data),
                .we      (dma_b_write_enable ? (dma_write_bank == bank)
                          : (b_write_enable && (packet_bank == bank))),
                .addr_out(b_addr[bank]),
                .data_out(b_data[bank])
            );
        end

        for (bank = 0; bank < BANKS; bank = bank + 1) begin : c_bram_banks
            bram #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH)
            ) bank_memory (
                .clk     (clk),
                .addr_in (c_host_write_enable ? packet_word_addr : c_write_addr),
                .data_in (c_host_write_enable ? packet_data : c_write_data[bank]),
                .we      ((c_host_write_enable && (packet_bank == bank))
                          || drain_capture_valid),
                .addr_out(c_read_addr),
                .data_out(c_data_out[bank])
            );
        end
    endgenerate

    compute_dma #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .BANKS      (BANKS),
        .LANE_WIDTH (SYSTOLIC_UNITWIDTH)
    ) dma (
        .clk               (clk),
        .rst_n             (rst_n),
        .request           (dma_request),
        .destination       (dma_destination),
        .destination_bank (dma_destination_bank),
        .source_base      (dma_source_base),
        .destination_base (dma_destination_base),
        .transfer_length  (dma_transfer_length),
        .busy              (dma_busy),
        .c_read_addr      (c_read_addr),
        .c_data           (c_data_out),
        .a_write_enable   (dma_a_write_enable),
        .b_write_enable   (dma_b_write_enable),
        .write_bank       (dma_write_bank),
        .write_addr       (dma_write_addr),
        .write_data       (dma_write_data),
        .data_out         (dev_data_out),
        .data_out_valid   (dev_data_out_valid),
        .data_out_ready   (dev_data_out_ready)
    );

    logic [SYSTOLIC_UNITWIDTH-1:0] systolic_vertical_bar [0:SYSTOLIC_HEIGHT-1];
    logic [SYSTOLIC_UNITWIDTH-1:0] systolic_horizontal_bar [0:SYSTOLIC_WIDTH-1];
    logic [SYSTOLIC_UNITWIDTH-1:0] systolic_drain_bar [0:SYSTOLIC_WIDTH-1];
    logic systolic_add_signal;
    logic systolic_flow_v_signal;
    logic systolic_flow_h_signal;
    logic systolic_broad_v_signal;
    logic systolic_broad_h_signal;

    systolic_launcher #(
        .A_DATAWIDTH(DATA_WIDTH),
        .A_ADDRWIDTH(ADDR_WIDTH),
        .A_BANKS(BANKS),
        .B_DATAWIDTH(DATA_WIDTH),
        .B_ADDRWIDTH(ADDR_WIDTH),
        .B_BANKS(BANKS),
        .SYSTOLIC_UNITWIDTH(SYSTOLIC_UNITWIDTH),
        .SYSTOLIC_WIDTH(SYSTOLIC_WIDTH),
        .SYSTOLIC_HEIGHT(SYSTOLIC_HEIGHT)
    ) launcher (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .a_mat_base_offset        (a_mat_base_offset),
        .b_mat_base_offset        (b_mat_base_offset),
        .a_addr                   (a_addr),
        .a_data                   (a_data),
        .b_addr                   (b_addr),
        .b_data                   (b_data),
        .fire                     (launcher_fire),
        .cnn_fire                 (cnn_fire),
        .busy                     (launcher_busy),
        .cnn_input_base           (cnn_input_base),
        .cnn_weight_base          (cnn_weight_base),
        .cnn_input_width          (cnn_input_width),
        .cnn_input_height         (cnn_input_height),
        .cnn_input_channels       (cnn_input_channels),
        .cnn_kernel_width         (cnn_kernel_width),
        .cnn_kernel_height        (cnn_kernel_height),
        .cnn_stride_x             (cnn_stride_x),
        .cnn_stride_y             (cnn_stride_y),
        .cnn_pad_left             (cnn_pad_left),
        .cnn_pad_right            (cnn_pad_right),
        .cnn_pad_top              (cnn_pad_top),
        .cnn_pad_bottom           (cnn_pad_bottom),
        .cnn_output_x             (cnn_output_x),
        .cnn_output_y             (cnn_output_y),
        .cnn_output_width         (cnn_output_width),
        .cnn_k_total              (cnn_k_total),
        .systolic_vertical_bar    (systolic_vertical_bar),
        .systolic_horizontal_bar  (systolic_horizontal_bar),
        .systolic_add_signal      (systolic_add_signal),
        .systolic_flow_v_signal   (systolic_flow_v_signal),
        .systolic_flow_h_signal   (systolic_flow_h_signal),
        .systolic_broad_v_signal  (systolic_broad_v_signal),
        .systolic_broad_h_signal  (systolic_broad_h_signal)
    );

    logic systolic_drain_signal;
    systolic #(
        .WIDTH (SYSTOLIC_WIDTH),
        .HEIGHT(SYSTOLIC_HEIGHT),
        .UNIT_WIDTH(SYSTOLIC_UNITWIDTH)
    ) array (
        .clk                  (clk),
        .rst_n                (rst_n),
        .vertical_bar         (systolic_vertical_bar),
        .horizontal_bar       (systolic_horizontal_bar),
        .horizontal_drain_bar (systolic_drain_bar),
        .result_saturation    (4'd0),
        .add                  (systolic_add_signal),
        .flow_v               (systolic_flow_v_signal),
        .flow_h               (systolic_flow_h_signal),
        .drain                (systolic_drain_signal),
        .broad_v              (systolic_broad_v_signal),
        .broad_h              (systolic_broad_h_signal)
    );

    logic launcher_busy_d;
    logic [3:0] drain_step_index;
    logic drain_pending;

    // systolic publishes a drained value one clock after drain is asserted.
    // C is always available, so drain does not depend on dev_data_out_ready.
    assign drain_capture_valid = drain_active && drain_pending;
    assign drain_request_valid = drain_active
        && (!drain_pending || (drain_step_index < LAST_DRAIN_STEP));
    assign systolic_drain_signal = drain_request_valid;
    // The systolic drain exposes the bottom row first.  Reverse the physical
    // write addresses so C/DMA observe the logical output-row order.
    assign c_write_addr = c_mat_base_offset
        + ADDR_WIDTH'(SYSTOLIC_HEIGHT - 1 - drain_step_index);

    always_comb begin
        for (int i = 0; i < BANKS; i++) begin
            c_write_data[i] = '0;
            if (i < SYSTOLIC_WIDTH) begin
                c_write_data[i][SYSTOLIC_UNITWIDTH-1:0]
                    = systolic_drain_bar[i];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            launcher_busy_d <= 1'b0;
            drain_active <= 1'b0;
            drain_step_index <= '0;
            drain_pending <= 1'b0;
        end else begin
            launcher_busy_d <= launcher_busy;

            if (!drain_active) begin
                if (launcher_busy_d && !launcher_busy) begin
                    drain_active <= 1'b1;
                    drain_step_index <= '0;
                    drain_pending <= 1'b0;
                end
            end else begin
                if (drain_capture_valid
                    && (drain_step_index == LAST_DRAIN_STEP)) begin
                    drain_active <= 1'b0;
                    drain_pending <= 1'b0;
                    drain_step_index <= '0;
                end else if (drain_capture_valid) begin
                    drain_step_index <= drain_step_index + 1'b1;
                end

                if (drain_request_valid) begin
                    drain_pending <= 1'b1;
                end
            end
        end
    end

    initial begin
        if (DATA_WIDTH < SYSTOLIC_WIDTH * SYSTOLIC_UNITWIDTH) begin
            $error("DATA_WIDTH is too small to pack one systolic result row");
        end
        if (BANKS != SYSTOLIC_WIDTH || BANKS != SYSTOLIC_HEIGHT) begin
            $warning("core assumes eight banks for the 8x8 launcher/array");
        end
    end

endmodule
