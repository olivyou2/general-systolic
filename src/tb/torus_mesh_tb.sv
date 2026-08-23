module torus_mesh_tb;

    localparam int ADDR_WIDTH = 40;
    localparam int DATA_WIDTH = 64;
    localparam int CHANNELS = 2;
    localparam int MESH_X = 16;
    localparam int MESH_Y = 16;
    localparam int NODES = MESH_X * MESH_Y;
    localparam int TIMEOUT_CYCLES = 5000;

    localparam int NODE_0_0  = 0;
    localparam int NODE_1_0  = 1;
    localparam int NODE_2_0  = 2;
    localparam int NODE_2_1  = 18;
    localparam int NODE_5_3  = 53;
    localparam int NODE_2_15 = 242;
    localparam int NODE_15_15 = 255;
    localparam int DISABLED_NODE = 3;

    function automatic logic [NODES-1:0] make_enable_mask();
        logic [NODES-1:0] mask;
        begin
            mask = '0;
            mask[NODE_0_0] = 1'b1;
            mask[NODE_1_0] = 1'b1;
            mask[NODE_2_0] = 1'b1;
            mask[NODE_2_1] = 1'b1;
            mask[NODE_5_3] = 1'b1;
            mask[NODE_2_15] = 1'b1;
            mask[NODE_15_15] = 1'b1;
            make_enable_mask = mask;
        end
    endfunction

    localparam logic [NODES-1:0] ENABLE_MASK = make_enable_mask();

    logic clk;
    logic rst_n = 1'b0;

    logic [ADDR_WIDTH-1:0] local_addr_in [0:NODES-1][0:CHANNELS-1];
    logic [DATA_WIDTH-1:0] local_data_in [0:NODES-1][0:CHANNELS-1];
    logic local_valid_in [0:NODES-1][0:CHANNELS-1];
    logic local_ready_out [0:NODES-1][0:CHANNELS-1];

    logic [ADDR_WIDTH-1:0] local_addr_out [0:NODES-1][0:CHANNELS-1];
    logic [DATA_WIDTH-1:0] local_data_out [0:NODES-1][0:CHANNELS-1];
    logic local_valid_out [0:NODES-1][0:CHANNELS-1];
    logic local_ready_in [0:NODES-1][0:CHANNELS-1];

    integer error_count = 0;

    torus_mesh #(
        .ADDR_WIDTH      (ADDR_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .CHANNELS        (CHANNELS),
        .MESH_X          (MESH_X),
        .MESH_Y          (MESH_Y),
        .NODE_ENABLE_MASK(ENABLE_MASK)
    ) dut (
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

    always #5 clk = ~clk;

    function automatic logic [ADDR_WIDTH-1:0] packet_address(
        input logic [3:0] destination_x,
        input logic [3:0] destination_y,
        input logic [31:0] endpoint_address
    );
        begin
            packet_address = {
                destination_x,
                destination_y,
                endpoint_address
            };
        end
    endfunction

    task automatic reset_dut();
        begin
            for (int node = 0; node < NODES; node++) begin
                for (int channel = 0; channel < CHANNELS; channel++) begin
                    local_addr_in[node][channel] = '0;
                    local_data_in[node][channel] = '0;
                    local_valid_in[node][channel] = 1'b0;
                    local_ready_in[node][channel] = 1'b0;
                end
            end
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic send_packet(
        input integer source_node,
        input integer channel,
        input logic [ADDR_WIDTH-1:0] address,
        input logic [DATA_WIDTH-1:0] data
    );
        integer wait_cycles;
        begin
            @(negedge clk);
            local_addr_in[source_node][channel] = address;
            local_data_in[source_node][channel] = data;
            local_valid_in[source_node][channel] = 1'b1;

            wait_cycles = 0;
            while (!local_ready_out[source_node][channel]) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
                if (wait_cycles >= TIMEOUT_CYCLES) begin
                    $fatal(1,
                           "Injection timeout: node=%0d channel=%0d addr=%h",
                           source_node, channel, address);
                end
            end

            @(posedge clk);
            @(negedge clk);
            local_valid_in[source_node][channel] = 1'b0;
        end
    endtask

    task automatic receive_packet(
        input integer destination_node,
        input integer channel,
        input logic [ADDR_WIDTH-1:0] expected_address,
        input logic [DATA_WIDTH-1:0] expected_data,
        input integer stall_cycles
    );
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!local_valid_out[destination_node][channel]) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
                if (wait_cycles >= TIMEOUT_CYCLES) begin
                    $fatal(1,
                           "Receive timeout: node=%0d channel=%0d addr=%h",
                           destination_node, channel, expected_address);
                end
            end

            if (local_addr_out[destination_node][channel]
                !== expected_address) begin
                $error("Address mismatch: node=%0d channel=%0d expected=%h got=%h",
                       destination_node, channel, expected_address,
                       local_addr_out[destination_node][channel]);
                error_count = error_count + 1;
            end
            if (local_data_out[destination_node][channel] !== expected_data) begin
                $error("Data mismatch: node=%0d channel=%0d expected=%h got=%h",
                       destination_node, channel, expected_data,
                       local_data_out[destination_node][channel]);
                error_count = error_count + 1;
            end

            // Check that valid/address/data remain stable under backpressure.
            repeat (stall_cycles) begin
                @(posedge clk);
                #1;
                if (!local_valid_out[destination_node][channel]
                    || (local_addr_out[destination_node][channel]
                        !== expected_address)
                    || (local_data_out[destination_node][channel]
                        !== expected_data)) begin
                    $error("Output changed during stall: node=%0d channel=%0d",
                           destination_node, channel);
                    error_count = error_count + 1;
                end
            end

            @(negedge clk);
            local_ready_in[destination_node][channel] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            local_ready_in[destination_node][channel] = 1'b0;
        end
    endtask

    task automatic receive_capture(
        input integer destination_node,
        input integer channel,
        output logic [DATA_WIDTH-1:0] captured_data
    );
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!local_valid_out[destination_node][channel]) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
                if (wait_cycles >= TIMEOUT_CYCLES) begin
                    $fatal(1,
                           "Contention receive timeout: node=%0d channel=%0d",
                           destination_node, channel);
                end
            end
            captured_data = local_data_out[destination_node][channel];
            @(negedge clk);
            local_ready_in[destination_node][channel] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            local_ready_in[destination_node][channel] = 1'b0;
        end
    endtask

    initial begin
        logic [ADDR_WIDTH-1:0] address_a;
        logic [ADDR_WIDTH-1:0] address_b;
        logic [DATA_WIDTH-1:0] captured_first;
        logic [DATA_WIDTH-1:0] captured_second;

        clk = 1'b0;
        reset_dut();

        // Compile-time-disabled endpoints expose no local injection port.
        if (local_ready_out[DISABLED_NODE][0] !== 1'b0
            || local_ready_out[DISABLED_NODE][1] !== 1'b0) begin
            $error("Disabled node unexpectedly accepted local traffic");
            error_count = error_count + 1;
        end

        // Route across several disabled coordinates, first east and then south.
        address_a = packet_address(5, 3, 32'h0000_1000);
        send_packet(NODE_0_0, 0, address_a, 64'h1111_2222_3333_4444);
        receive_packet(NODE_5_3, 0, address_a,
                       64'h1111_2222_3333_4444, 0);

        // Both directional channels operate independently and concurrently.
        address_a = packet_address(2, 1, 32'h0000_2000);
        address_b = packet_address(2, 1, 32'h0000_2008);
        fork
            send_packet(NODE_0_0, 0, address_a,
                        64'haaaa_0000_0000_0001);
            send_packet(NODE_0_0, 1, address_b,
                        64'hbbbb_0000_0000_0002);
        join
        fork
            receive_packet(NODE_2_1, 0, address_a,
                           64'haaaa_0000_0000_0001, 0);
            receive_packet(NODE_2_1, 1, address_b,
                           64'hbbbb_0000_0000_0002, 0);
        join

        // East wraps x=15 -> 0, then south wraps y=15 -> 0.
        address_a = packet_address(0, 0, 32'h0000_3000);
        send_packet(NODE_15_15, 1, address_a,
                    64'hcafe_f00d_0000_0003);
        receive_packet(NODE_0_0, 1, address_a,
                       64'hcafe_f00d_0000_0003, 0);

        // Hold an endpoint stalled and verify output stability.
        address_a = packet_address(5, 3, 32'h0000_4000);
        send_packet(NODE_0_0, 0, address_a,
                    64'hdead_beef_0000_0004);
        receive_packet(NODE_5_3, 0, address_a,
                       64'hdead_beef_0000_0004, 6);

        // A packet for a disabled endpoint is dropped and cannot block the
        // following packet on the same channel.
        address_a = packet_address(3, 0, 32'h0000_5000);
        send_packet(NODE_0_0, 0, address_a,
                    64'hdddd_0000_0000_0005);
        repeat (10) @(posedge clk);
        address_b = packet_address(5, 3, 32'h0000_5008);
        send_packet(NODE_0_0, 0, address_b,
                    64'heeee_0000_0000_0006);
        receive_packet(NODE_5_3, 0, address_b,
                       64'heeee_0000_0000_0006, 0);

        // West and north inputs reach the same local output together.  Both
        // must eventually complete; order is intentionally not assumed.
        address_a = packet_address(2, 0, 32'h0000_6000);
        address_b = packet_address(2, 0, 32'h0000_6008);
        fork
            send_packet(NODE_1_0, 0, address_a,
                        64'h1111_0000_0000_0007);
            send_packet(NODE_2_15, 0, address_b,
                        64'h2222_0000_0000_0008);
        join
        receive_capture(NODE_2_0, 0, captured_first);
        receive_capture(NODE_2_0, 0, captured_second);
        if (!((captured_first == 64'h1111_0000_0000_0007
               && captured_second == 64'h2222_0000_0000_0008)
              || (captured_first == 64'h2222_0000_0000_0008
                  && captured_second == 64'h1111_0000_0000_0007))) begin
            $error("Contention arbitration lost or duplicated a packet: %h %h",
                   captured_first, captured_second);
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("[PASS] 16x16 two-channel torus mesh integration test");
        end else begin
            $fatal(1, "[FAIL] torus mesh found %0d error(s)", error_count);
        end
        $finish;
    end

endmodule
