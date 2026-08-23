module torus_mesh_scratchpad_tb;
    localparam int ADDR_WIDTH = 40;
    localparam int DATA_WIDTH = 64;
    localparam int CHANNELS = 2;
    localparam int MESH_X = 4;
    localparam int MESH_Y = 4;
    localparam int X_BITS = $clog2(MESH_X);
    localparam int Y_BITS = $clog2(MESH_Y);
    localparam int LOCAL_WIDTH = ADDR_WIDTH - X_BITS - Y_BITS;
    localparam int METADATA_WIDTH = LOCAL_WIDTH - 4 - X_BITS - Y_BITS;
    localparam int NODES = MESH_X * MESH_Y;

    localparam int SP0_NODE = 0;       // (0,0)
    localparam int SP1_NODE = 3;       // (3,0)
    localparam int HOST_NODE = 5;      // (1,1)
    localparam int COMPUTE_NODE = 6;   // (2,1)
    localparam int SP_CAPACITY_BYTES = 8192;

    localparam logic [NODES-1:0] ENABLE_MASK
        = NODES'((1 << SP0_NODE) | (1 << SP1_NODE)
                 | (1 << HOST_NODE) | (1 << COMPUTE_NODE));

    localparam logic [31:0] DMA_COMMAND_REG     = 32'hf000_0000;
    localparam logic [31:0] DMA_SOURCE_REG      = 32'hf000_0008;
    localparam logic [31:0] DMA_LENGTH_REG      = 32'hf000_0010;
    localparam logic [31:0] DMA_DESTINATION_REG = 32'hf000_0018;
    localparam logic [31:0] DMA_STRIDE_REG      = 32'hf000_0020;

    logic clk;
    logic rst_n = 1'b0;

    logic [ADDR_WIDTH-1:0] local_addr_in [0:NODES-1][0:CHANNELS-1];
    logic [DATA_WIDTH-1:0] local_data_in [0:NODES-1][0:CHANNELS-1];
    logic local_valid_in [0:NODES-1][0:CHANNELS-1];
    logic local_ready_out [0:NODES-1][0:CHANNELS-1];
    logic [ADDR_WIDTH-1:0] local_addr_out [0:NODES-1][0:CHANNELS-1];
    logic [DATA_WIDTH-1:0] local_data_out [0:NODES-1][0:CHANNELS-1];
    logic local_valid_out [0:NODES-1][0:CHANNELS-1];
    /* verilator lint_off UNOPTFLAT */
    logic local_ready_in [0:NODES-1][0:CHANNELS-1];
    /* verilator lint_on UNOPTFLAT */

    logic sp0_busy;
    logic sp0_error;
    logic sp1_busy;
    logic sp1_error;
    integer compute_receive_count;
    logic [ADDR_WIDTH-1:0] compute_received_addr [0:1];
    logic [DATA_WIDTH-1:0] compute_received_data [0:1];

    torus_mesh #(
        .ADDR_WIDTH      (ADDR_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .CHANNELS        (CHANNELS),
        .MESH_X          (MESH_X),
        .MESH_Y          (MESH_Y),
        .NODE_ENABLE_MASK(ENABLE_MASK)
    ) mesh (
        .clk            (clk),
        .rst_n          (rst_n),
        .local_addr_in  (local_addr_in),
        .local_data_in  (local_data_in),
        .local_valid_in (local_valid_in),
        .local_ready_out(local_ready_out),
        .local_addr_out (local_addr_out),
        .local_data_out (local_data_out),
        .local_valid_out(local_valid_out),
        .local_ready_in (local_ready_in)
    );

    global_scratchpad #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .CHANNELS      (CHANNELS),
        .MESH_X        (MESH_X),
        .MESH_Y        (MESH_Y),
        .X_COORD       (0),
        .Y_COORD       (0),
        .CAPACITY_BYTES(SP_CAPACITY_BYTES)
    ) scratchpad_0 (
        .clk           (clk),
        .rst_n         (rst_n),
        .mesh_addr_in  (local_addr_out[SP0_NODE]),
        .mesh_data_in  (local_data_out[SP0_NODE]),
        .mesh_valid_in (local_valid_out[SP0_NODE]),
        .mesh_ready_out(local_ready_in[SP0_NODE]),
        .mesh_addr_out (local_addr_in[SP0_NODE]),
        .mesh_data_out (local_data_in[SP0_NODE]),
        .mesh_valid_out(local_valid_in[SP0_NODE]),
        .mesh_ready_in (local_ready_out[SP0_NODE]),
        .dma_busy      (sp0_busy),
        .dma_error     (sp0_error)
    );

    global_scratchpad #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .CHANNELS      (CHANNELS),
        .MESH_X        (MESH_X),
        .MESH_Y        (MESH_Y),
        .X_COORD       (3),
        .Y_COORD       (0),
        .CAPACITY_BYTES(SP_CAPACITY_BYTES)
    ) scratchpad_1 (
        .clk           (clk),
        .rst_n         (rst_n),
        .mesh_addr_in  (local_addr_out[SP1_NODE]),
        .mesh_data_in  (local_data_out[SP1_NODE]),
        .mesh_valid_in (local_valid_out[SP1_NODE]),
        .mesh_ready_out(local_ready_in[SP1_NODE]),
        .mesh_addr_out (local_addr_in[SP1_NODE]),
        .mesh_data_out (local_data_in[SP1_NODE]),
        .mesh_valid_out(local_valid_in[SP1_NODE]),
        .mesh_ready_in (local_ready_out[SP1_NODE]),
        .dma_busy      (sp1_busy),
        .dma_error     (sp1_error)
    );

    always #5 clk = ~clk;

    function automatic logic [ADDR_WIDTH-1:0] endpoint_address(
        input logic [X_BITS-1:0] destination_x,
        input logic [Y_BITS-1:0] destination_y,
        input logic [3:0] opcode,
        input logic [31:0] address
    );
        endpoint_address = {destination_x, destination_y, opcode, address};
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] read_address(
        input logic [X_BITS-1:0] destination_x,
        input logic [Y_BITS-1:0] destination_y,
        input logic [X_BITS-1:0] return_x,
        input logic [Y_BITS-1:0] return_y,
        input logic [METADATA_WIDTH-1:0] metadata
    );
        read_address = {
            destination_x, destination_y, 4'h1,
            return_x, return_y, metadata
        };
    endfunction

    task automatic host_send(
        input logic [ADDR_WIDTH-1:0] address,
        input logic [DATA_WIDTH-1:0] data
    );
        integer timeout;
        begin
            @(negedge clk);
            local_addr_in[HOST_NODE][0] = address;
            local_data_in[HOST_NODE][0] = data;
            local_valid_in[HOST_NODE][0] = 1'b1;
            timeout = 0;
            while (!local_ready_out[HOST_NODE][0]) begin
                @(negedge clk);
                timeout++;
                if (timeout > 200) $fatal(1, "host injection timeout");
            end
            @(posedge clk);
            @(negedge clk);
            local_valid_in[HOST_NODE][0] = 1'b0;
        end
    endtask

    task automatic configure_dma(
        input logic [X_BITS-1:0] scratchpad_x,
        input logic [Y_BITS-1:0] scratchpad_y,
        input integer source_word,
        input integer length_words,
        input logic [ADDR_WIDTH-1:0] destination
    );
        begin
            host_send(endpoint_address(scratchpad_x, scratchpad_y,
                                       4'hf, DMA_SOURCE_REG),
                      DATA_WIDTH'(source_word));
            host_send(endpoint_address(scratchpad_x, scratchpad_y,
                                       4'hf, DMA_LENGTH_REG),
                      DATA_WIDTH'(length_words));
            host_send(endpoint_address(scratchpad_x, scratchpad_y,
                                       4'hf, DMA_DESTINATION_REG),
                      DATA_WIDTH'(destination));
            host_send(endpoint_address(scratchpad_x, scratchpad_y,
                                       4'hf, DMA_STRIDE_REG), 64'd1);
            host_send(endpoint_address(scratchpad_x, scratchpad_y,
                                       4'hf, DMA_COMMAND_REG), 64'd1);
        end
    endtask

    task automatic wait_dma_done(input integer scratchpad_index);
        integer timeout;
        begin
            timeout = 0;
            while (!(scratchpad_index == 0 ? sp0_busy : sp1_busy)) begin
                @(negedge clk);
                timeout++;
                if (timeout > 300) $fatal(1, "DMA did not start");
            end
            while (scratchpad_index == 0 ? sp0_busy : sp1_busy) begin
                @(negedge clk);
                timeout++;
                if (timeout > 1000) $fatal(1, "DMA did not finish");
            end
        end
    endtask

    task automatic read_and_expect(
        input logic [X_BITS-1:0] scratchpad_x,
        input logic [Y_BITS-1:0] scratchpad_y,
        input logic [METADATA_WIDTH-1:0] word_address,
        input logic [DATA_WIDTH-1:0] expected_data
    );
        logic [METADATA_WIDTH-1:0] metadata;
        integer timeout;
        begin
            metadata = METADATA_WIDTH'(word_address);
            host_send(read_address(scratchpad_x, scratchpad_y,
                                   X_BITS'(1), Y_BITS'(1), metadata), '0);
            timeout = 0;
            while (!local_valid_out[HOST_NODE][1]) begin
                @(negedge clk);
                timeout++;
                if (timeout > 300) $fatal(1, "read response timeout");
            end
            if (local_data_out[HOST_NODE][1] != expected_data) begin
                $fatal(1, "read mismatch: got %h expected %h",
                       local_data_out[HOST_NODE][1], expected_data);
            end
            @(posedge clk);
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            compute_receive_count <= 0;
            compute_received_addr[0] <= '0;
            compute_received_addr[1] <= '0;
            compute_received_data[0] <= '0;
            compute_received_data[1] <= '0;
        end else if (local_valid_out[COMPUTE_NODE][0]
                     && local_ready_in[COMPUTE_NODE][0]) begin
            if (compute_receive_count < 2) begin
                compute_received_addr[compute_receive_count]
                    <= local_addr_out[COMPUTE_NODE][0];
                compute_received_data[compute_receive_count]
                    <= local_data_out[COMPUTE_NODE][0];
            end
            compute_receive_count <= compute_receive_count + 1;
        end
    end

    initial begin
        logic [ADDR_WIDTH-1:0] sp1_write_base;
        logic [ADDR_WIDTH-1:0] compute_write_base;
        integer timeout;

        clk = 1'b0;
        for (int node = 0; node < NODES; node++) begin
            if ((node != SP0_NODE) && (node != SP1_NODE)) begin
                for (int channel = 0; channel < CHANNELS; channel++) begin
                    local_addr_in[node][channel] = '0;
                    local_data_in[node][channel] = '0;
                    local_valid_in[node][channel] = 1'b0;
                    local_ready_in[node][channel] = 1'b0;
                end
            end
        end
        local_ready_in[HOST_NODE][1] = 1'b1;
        local_ready_in[COMPUTE_NODE][0] = 1'b1;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Initialize SP0 through ordinary mesh write requests.
        host_send(endpoint_address(X_BITS'(0), Y_BITS'(0),
                                   4'h0, 32'd0),
                  64'h1111_2222_3333_4444);
        host_send(endpoint_address(X_BITS'(0), Y_BITS'(0),
                                   4'h0, 32'd1),
                  64'haaaa_bbbb_cccc_dddd);

        // Internal DMA: SP0 words 0..1 -> SP1 words 4..5.
        sp1_write_base = endpoint_address(
            X_BITS'(3), Y_BITS'(0), 4'h0, 32'd4);
        configure_dma(X_BITS'(0), Y_BITS'(0), 0, 2, sp1_write_base);
        wait_dma_done(0);
        if (sp0_error) $fatal(1, "SP0 DMA reported an error");
        repeat (20) @(posedge clk);

        read_and_expect(X_BITS'(3), Y_BITS'(0), 4,
                        64'h1111_2222_3333_4444);
        read_and_expect(X_BITS'(3), Y_BITS'(0), 5,
                        64'haaaa_bbbb_cccc_dddd);

        // Internal DMA: SP1 words 4..5 -> a compute-node address range.
        compute_write_base = endpoint_address(
            X_BITS'(2), Y_BITS'(1), 4'h0, 32'h1000_0020);
        configure_dma(X_BITS'(3), Y_BITS'(0), 4, 2,
                      compute_write_base);
        wait_dma_done(1);
        if (sp1_error) $fatal(1, "SP1 DMA reported an error");

        timeout = 0;
        while (compute_receive_count < 2) begin
            @(negedge clk);
            timeout++;
            if (timeout > 300) $fatal(1, "compute DMA receive timeout");
        end
        if (compute_received_addr[0] != compute_write_base
            || compute_received_addr[1] != compute_write_base + 1'b1
            || compute_received_data[0] != 64'h1111_2222_3333_4444
            || compute_received_data[1] != 64'haaaa_bbbb_cccc_dddd) begin
            $fatal(1, "scratchpad-to-compute DMA payload/address mismatch");
        end

        $display("[PASS] standalone global scratchpad mesh/DMA test");
        $finish;
    end

endmodule
