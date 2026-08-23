// Standalone BRAM-backed mesh endpoint with an internal DMA engine.
//
// Connect mesh_addr/data/valid_in to a router's local output and connect
// mesh_addr/data/valid_out to the router's local input. Channel 0 carries
// requests and DMA writes; channel 1 carries direct-read responses.

module global_scratchpad #(
    parameter int ADDR_WIDTH = 40,
    parameter int DATA_WIDTH = 64,
    parameter int CHANNELS = 2,
    parameter int MESH_X = 16,
    parameter int MESH_Y = 16,
    parameter int X_COORD = 0,
    parameter int Y_COORD = 0,
    parameter int unsigned CAPACITY_BYTES = 4096
)(
    input logic clk,
    input logic rst_n,

    input  logic [ADDR_WIDTH-1:0] mesh_addr_in [0:CHANNELS-1],
    input  logic [DATA_WIDTH-1:0] mesh_data_in [0:CHANNELS-1],
    input  logic                  mesh_valid_in [0:CHANNELS-1],
    output logic                  mesh_ready_out [0:CHANNELS-1],

    output logic [ADDR_WIDTH-1:0] mesh_addr_out [0:CHANNELS-1],
    output logic [DATA_WIDTH-1:0] mesh_data_out [0:CHANNELS-1],
    output logic                  mesh_valid_out [0:CHANNELS-1],
    input  logic                  mesh_ready_in [0:CHANNELS-1],

    output logic dma_busy,
    output logic dma_error
);
    localparam int X_BITS = (MESH_X > 1) ? $clog2(MESH_X) : 1;
    localparam int Y_BITS = (MESH_Y > 1) ? $clog2(MESH_Y) : 1;
    localparam int LOCAL_WIDTH = ADDR_WIDTH - X_BITS - Y_BITS;
    localparam int WORD_BYTES = DATA_WIDTH / 8;
    localparam int WORD_DEPTH = CAPACITY_BYTES / WORD_BYTES;
    localparam int MEM_ADDR_WIDTH = (WORD_DEPTH > 1) ? $clog2(WORD_DEPTH) : 1;
    localparam int LENGTH_WIDTH = MEM_ADDR_WIDTH + 1;
    localparam int READ_METADATA_WIDTH
        = LOCAL_WIDTH - 4 - X_BITS - Y_BITS;

    localparam logic [3:0] OP_WRITE   = 4'h0;
    localparam logic [3:0] OP_READ    = 4'h1;
    localparam logic [3:0] OP_RESPONSE = 4'h2;
    localparam logic [3:0] OP_CONTROL = 4'hf;

    localparam logic [31:0] DMA_COMMAND_REG     = 32'hf000_0000;
    localparam logic [31:0] DMA_SOURCE_REG      = 32'hf000_0008;
    localparam logic [31:0] DMA_LENGTH_REG      = 32'hf000_0010;
    localparam logic [31:0] DMA_DESTINATION_REG = 32'hf000_0018;
    localparam logic [31:0] DMA_STRIDE_REG      = 32'hf000_0020;

    (* ram_style = "block" *)
    logic [DATA_WIDTH-1:0] memory [0:WORD_DEPTH-1];

    logic [LOCAL_WIDTH-1:0] request_local_addr;
    logic [3:0] request_opcode;
    logic [MEM_ADDR_WIDTH-1:0] request_word_addr;
    logic request_fire;
    logic direct_write_fire;
    logic direct_read_fire;
    logic control_fire;

    logic [X_BITS-1:0] read_return_x;
    logic [Y_BITS-1:0] read_return_y;
    logic [READ_METADATA_WIDTH-1:0] read_metadata;

    logic [DATA_WIDTH-1:0] direct_read_data;
    logic [ADDR_WIDTH-1:0] direct_response_addr_pending;
    logic direct_read_pending;
    logic [ADDR_WIDTH-1:0] direct_response_addr;
    logic [DATA_WIDTH-1:0] direct_response_data;
    logic direct_response_valid;

    logic [MEM_ADDR_WIDTH-1:0] dma_source_config;
    logic [LENGTH_WIDTH-1:0] dma_length_config;
    logic [ADDR_WIDTH-1:0] dma_destination_config;
    logic [ADDR_WIDTH-1:0] dma_stride_config;

    logic [MEM_ADDR_WIDTH-1:0] dma_source_current;
    logic [LENGTH_WIDTH-1:0] dma_transfer_index;
    logic [LENGTH_WIDTH-1:0] dma_length_q;
    logic [ADDR_WIDTH-1:0] dma_destination_current;
    logic [ADDR_WIDTH-1:0] dma_stride_q;
    logic [DATA_WIDTH-1:0] dma_read_data;
    logic dma_read_pending;
    logic dma_read_issue;
    logic [ADDR_WIDTH-1:0] dma_output_addr;
    logic [DATA_WIDTH-1:0] dma_output_data;
    logic dma_output_valid;
    logic dma_output_fire;

    assign request_local_addr = mesh_addr_in[0][LOCAL_WIDTH-1:0];
    assign request_opcode = request_local_addr[LOCAL_WIDTH-1 -: 4];
    assign request_word_addr = request_local_addr[MEM_ADDR_WIDTH-1:0];
    assign read_return_x = request_local_addr[LOCAL_WIDTH-5 -: X_BITS];
    assign read_return_y
        = request_local_addr[LOCAL_WIDTH-5-X_BITS -: Y_BITS];
    assign read_metadata = request_local_addr[READ_METADATA_WIDTH-1:0];

    // Direct accesses and configuration are paused for the duration of a DMA.
    // A read is accepted only when its single response slot is available.
    always_comb begin
        mesh_ready_out[0] = 1'b0;
        mesh_ready_out[1] = 1'b0;
        if (!dma_busy && !direct_read_pending) begin
            if (request_opcode == OP_READ) begin
                mesh_ready_out[0] = !direct_response_valid;
            end else begin
                mesh_ready_out[0] = 1'b1;
            end
        end
    end

    assign request_fire = mesh_valid_in[0] && mesh_ready_out[0];
    assign direct_write_fire = request_fire
        && (request_opcode == OP_WRITE);
    assign direct_read_fire = request_fire
        && (request_opcode == OP_READ);
    assign control_fire = request_fire
        && (request_opcode == OP_CONTROL);

    assign dma_read_issue = dma_busy
        && !dma_read_pending
        && !dma_output_valid;
    assign dma_output_fire = dma_output_valid && mesh_ready_in[0];

    always_comb begin
        for (int channel = 0; channel < CHANNELS; channel++) begin
            mesh_addr_out[channel] = '0;
            mesh_data_out[channel] = '0;
            mesh_valid_out[channel] = 1'b0;
        end

        mesh_addr_out[0] = dma_output_addr;
        mesh_data_out[0] = dma_output_data;
        mesh_valid_out[0] = dma_output_valid;

        mesh_addr_out[1] = direct_response_addr;
        mesh_data_out[1] = direct_response_data;
        mesh_valid_out[1] = direct_response_valid;
    end

    // One BRAM port is shared by direct accesses and DMA reads. They cannot
    // collide because direct requests are backpressured while dma_busy is set.
    always_ff @(posedge clk) begin
        if (direct_write_fire) begin
            memory[request_word_addr] <= mesh_data_in[0];
        end
        if (direct_read_fire) begin
            direct_read_data <= memory[request_word_addr];
        end else if (dma_read_issue) begin
            dma_read_data <= memory[dma_source_current];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            direct_response_addr_pending <= '0;
            direct_read_pending <= 1'b0;
            direct_response_addr <= '0;
            direct_response_data <= '0;
            direct_response_valid <= 1'b0;
        end else begin
            if (direct_response_valid && mesh_ready_in[1]) begin
                direct_response_valid <= 1'b0;
            end

            if (direct_read_pending) begin
                direct_response_addr <= direct_response_addr_pending;
                direct_response_data <= direct_read_data;
                direct_response_valid <= 1'b1;
            end
            direct_read_pending <= direct_read_fire;

            if (direct_read_fire) begin
                direct_response_addr_pending <= {
                    read_return_x,
                    read_return_y,
                    OP_RESPONSE,
                    X_BITS'(X_COORD),
                    Y_BITS'(Y_COORD),
                    read_metadata
                };
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dma_source_config <= '0;
            dma_length_config <= '0;
            dma_destination_config <= '0;
            dma_stride_config <= ADDR_WIDTH'(1);
            dma_source_current <= '0;
            dma_transfer_index <= '0;
            dma_length_q <= '0;
            dma_destination_current <= '0;
            dma_stride_q <= ADDR_WIDTH'(1);
            dma_busy <= 1'b0;
            dma_error <= 1'b0;
            dma_read_pending <= 1'b0;
            dma_output_addr <= '0;
            dma_output_data <= '0;
            dma_output_valid <= 1'b0;
        end else begin
            dma_read_pending <= dma_read_issue;

            if (dma_read_pending) begin
                dma_output_addr <= dma_destination_current;
                dma_output_data <= dma_read_data;
                dma_output_valid <= 1'b1;
            end

            if (dma_output_fire) begin
                dma_output_valid <= 1'b0;
                if (dma_transfer_index == dma_length_q - 1'b1) begin
                    dma_busy <= 1'b0;
                    dma_transfer_index <= '0;
                end else begin
                    dma_transfer_index <= dma_transfer_index + 1'b1;
                    dma_source_current <= dma_source_current + 1'b1;
                    dma_destination_current
                        <= dma_destination_current + dma_stride_q;
                end
            end

            if (control_fire) begin
                case (request_local_addr[31:0])
                    DMA_SOURCE_REG:
                        dma_source_config
                            <= mesh_data_in[0][MEM_ADDR_WIDTH-1:0];
                    DMA_LENGTH_REG:
                        dma_length_config
                            <= mesh_data_in[0][LENGTH_WIDTH-1:0];
                    DMA_DESTINATION_REG:
                        dma_destination_config
                            <= mesh_data_in[0][ADDR_WIDTH-1:0];
                    DMA_STRIDE_REG:
                        dma_stride_config
                            <= mesh_data_in[0][ADDR_WIDTH-1:0];
                    DMA_COMMAND_REG: begin
                        dma_error <= 1'b0;
                        if (mesh_data_in[0][0]) begin
                            if ((dma_length_config == 0)
                                || ({1'b0, dma_source_config}
                                    + dma_length_config
                                    > LENGTH_WIDTH'(WORD_DEPTH))) begin
                                dma_error <= 1'b1;
                            end else begin
                                dma_busy <= 1'b1;
                                dma_source_current <= dma_source_config;
                                dma_transfer_index <= '0;
                                dma_length_q <= dma_length_config;
                                dma_destination_current
                                    <= dma_destination_config;
                                dma_stride_q <= dma_stride_config;
                                dma_read_pending <= 1'b0;
                                dma_output_valid <= 1'b0;
                            end
                        end
                    end
                    default: begin
                    end
                endcase
            end
        end
    end

    initial begin
        if (CHANNELS != 2) begin
            $error("global_scratchpad requires exactly two mesh channels");
        end
        if ((DATA_WIDTH < ADDR_WIDTH) || ((DATA_WIDTH % 8) != 0)) begin
            $error("DATA_WIDTH must contain an address and whole bytes");
        end
        if ((CAPACITY_BYTES < WORD_BYTES)
            || ((CAPACITY_BYTES % WORD_BYTES) != 0)
            || ((WORD_DEPTH & (WORD_DEPTH - 1)) != 0)) begin
            $error("CAPACITY_BYTES must describe a power-of-two word depth");
        end
        if ((LOCAL_WIDTH < 32)
            || (READ_METADATA_WIDTH < MEM_ADDR_WIDTH)) begin
            $error("mesh address has insufficient local scratchpad bits");
        end
    end

endmodule
