module axi4_mesh_bridge_tb;
    localparam int AXI_ID_WIDTH = 4;
    localparam int ADDR_WIDTH = 40;
    localparam int DATA_WIDTH = 64;
    localparam int CHANNELS = 2;
    localparam int MESH_X = 4;
    localparam int MESH_Y = 4;
    localparam int X_BITS = $clog2(MESH_X);
    localparam int Y_BITS = $clog2(MESH_Y);
    localparam int NODES = MESH_X * MESH_Y;
    localparam int SP_NODE = 0;
    localparam int BRIDGE_NODE = 5;
    localparam int COMPUTE_NODE = 6;
    localparam logic [NODES-1:0] ENABLE_MASK
        = NODES'((1 << SP_NODE) | (1 << BRIDGE_NODE)
                 | (1 << COMPUTE_NODE));

    logic clk;
    logic rst_n;

    logic [AXI_ID_WIDTH-1:0] s_axi_awid;
    logic [ADDR_WIDTH-1:0] s_axi_awaddr;
    logic [7:0] s_axi_awlen;
    logic [2:0] s_axi_awsize;
    logic [1:0] s_axi_awburst;
    logic s_axi_awlock;
    logic [3:0] s_axi_awcache;
    logic [2:0] s_axi_awprot;
    logic [3:0] s_axi_awqos;
    logic s_axi_awvalid;
    logic s_axi_awready;
    logic [DATA_WIDTH-1:0] s_axi_wdata;
    logic [DATA_WIDTH/8-1:0] s_axi_wstrb;
    logic s_axi_wlast;
    logic s_axi_wvalid;
    logic s_axi_wready;
    logic [AXI_ID_WIDTH-1:0] s_axi_bid;
    logic [1:0] s_axi_bresp;
    logic s_axi_bvalid;
    logic s_axi_bready;
    logic [AXI_ID_WIDTH-1:0] s_axi_arid;
    logic [ADDR_WIDTH-1:0] s_axi_araddr;
    logic [7:0] s_axi_arlen;
    logic [2:0] s_axi_arsize;
    logic [1:0] s_axi_arburst;
    logic s_axi_arlock;
    logic [3:0] s_axi_arcache;
    logic [2:0] s_axi_arprot;
    logic [3:0] s_axi_arqos;
    logic s_axi_arvalid;
    logic s_axi_arready;
    logic [AXI_ID_WIDTH-1:0] s_axi_rid;
    logic [DATA_WIDTH-1:0] s_axi_rdata;
    logic [1:0] s_axi_rresp;
    logic s_axi_rlast;
    logic s_axi_rvalid;
    logic s_axi_rready;

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

    logic scratchpad_dma_busy;
    logic scratchpad_dma_error;
    integer compute_count;
    logic [ADDR_WIDTH-1:0] compute_addr;
    logic [DATA_WIDTH-1:0] compute_data;

    torus_mesh #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .CHANNELS(CHANNELS), .MESH_X(MESH_X), .MESH_Y(MESH_Y),
        .NODE_ENABLE_MASK(ENABLE_MASK)
    ) mesh (
        .clk(clk), .rst_n(rst_n),
        .local_addr_in(local_addr_in), .local_data_in(local_data_in),
        .local_valid_in(local_valid_in), .local_ready_out(local_ready_out),
        .local_addr_out(local_addr_out), .local_data_out(local_data_out),
        .local_valid_out(local_valid_out), .local_ready_in(local_ready_in)
    );

    global_scratchpad #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .CHANNELS(CHANNELS), .MESH_X(MESH_X), .MESH_Y(MESH_Y),
        .X_COORD(0), .Y_COORD(0), .CAPACITY_BYTES(8192)
    ) scratchpad (
        .clk(clk), .rst_n(rst_n),
        .mesh_addr_in(local_addr_out[SP_NODE]),
        .mesh_data_in(local_data_out[SP_NODE]),
        .mesh_valid_in(local_valid_out[SP_NODE]),
        .mesh_ready_out(local_ready_in[SP_NODE]),
        .mesh_addr_out(local_addr_in[SP_NODE]),
        .mesh_data_out(local_data_in[SP_NODE]),
        .mesh_valid_out(local_valid_in[SP_NODE]),
        .mesh_ready_in(local_ready_out[SP_NODE]),
        .dma_busy(scratchpad_dma_busy), .dma_error(scratchpad_dma_error)
    );

    axi4_mesh_bridge #(
        .AXI_ID_WIDTH(AXI_ID_WIDTH), .AXI_ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH), .CHANNELS(CHANNELS),
        .MESH_X(MESH_X), .MESH_Y(MESH_Y), .X_COORD(1), .Y_COORD(1)
    ) bridge (
        .s_axi_aclk(clk), .s_axi_aresetn(rst_n),
        .s_axi_awid(s_axi_awid), .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awlen(s_axi_awlen), .s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst), .s_axi_awlock(s_axi_awlock),
        .s_axi_awcache(s_axi_awcache), .s_axi_awprot(s_axi_awprot),
        .s_axi_awqos(s_axi_awqos), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_wlast(s_axi_wlast),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid), .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid), .s_axi_araddr(s_axi_araddr),
        .s_axi_arlen(s_axi_arlen), .s_axi_arsize(s_axi_arsize),
        .s_axi_arburst(s_axi_arburst), .s_axi_arlock(s_axi_arlock),
        .s_axi_arcache(s_axi_arcache), .s_axi_arprot(s_axi_arprot),
        .s_axi_arqos(s_axi_arqos), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready), .s_axi_rid(s_axi_rid),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rlast(s_axi_rlast), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .mesh_addr_in(local_addr_out[BRIDGE_NODE]),
        .mesh_data_in(local_data_out[BRIDGE_NODE]),
        .mesh_valid_in(local_valid_out[BRIDGE_NODE]),
        .mesh_ready_out(local_ready_in[BRIDGE_NODE]),
        .mesh_addr_out(local_addr_in[BRIDGE_NODE]),
        .mesh_data_out(local_data_in[BRIDGE_NODE]),
        .mesh_valid_out(local_valid_in[BRIDGE_NODE]),
        .mesh_ready_in(local_ready_out[BRIDGE_NODE])
    );

    always #5 clk = ~clk;

    function automatic logic [ADDR_WIDTH-1:0] mesh_address(
        input logic [X_BITS-1:0] x,
        input logic [Y_BITS-1:0] y,
        input logic [3:0] local_opcode,
        input logic [31:0] local_address
    );
        mesh_address = {x, y, local_opcode, local_address};
    endfunction

    task automatic axi_write_two(
        input logic [ADDR_WIDTH-1:0] address,
        input logic [DATA_WIDTH-1:0] data_0,
        input logic [DATA_WIDTH-1:0] data_1
    );
        begin
            @(negedge clk);
            s_axi_awid = 4'ha;
            s_axi_awaddr = address;
            s_axi_awlen = 1;
            s_axi_awsize = 3;
            s_axi_awburst = 2'b01;
            s_axi_awvalid = 1'b1;
            while (!s_axi_awready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            s_axi_awvalid = 1'b0;

            for (int beat = 0; beat < 2; beat++) begin
                s_axi_wdata = (beat == 0) ? data_0 : data_1;
                s_axi_wstrb = '1;
                s_axi_wlast = (beat == 1);
                s_axi_wvalid = 1'b1;
                while (!s_axi_wready) @(negedge clk);
                @(posedge clk);
                @(negedge clk);
                s_axi_wvalid = 1'b0;
            end

            while (!s_axi_bvalid) @(negedge clk);
            if (s_axi_bresp != 2'b00 || s_axi_bid != 4'ha)
                $fatal(1, "AXI write response error");
            @(posedge clk);
        end
    endtask

    task automatic axi_read_two(
        input logic [ADDR_WIDTH-1:0] address,
        input logic [DATA_WIDTH-1:0] expected_0,
        input logic [DATA_WIDTH-1:0] expected_1
    );
        logic [DATA_WIDTH-1:0] held_data;
        begin
            @(negedge clk);
            s_axi_arid = 4'h6;
            s_axi_araddr = address;
            s_axi_arlen = 1;
            s_axi_arsize = 3;
            s_axi_arburst = 2'b01;
            s_axi_arvalid = 1'b1;
            while (!s_axi_arready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            s_axi_arvalid = 1'b0;

            for (int beat = 0; beat < 2; beat++) begin
                s_axi_rready = 1'b0;
                while (!s_axi_rvalid) @(negedge clk);
                held_data = s_axi_rdata;
                repeat (2) begin
                    @(negedge clk);
                    if (!s_axi_rvalid || s_axi_rdata != held_data)
                        $fatal(1, "AXI R channel changed under backpressure");
                end
                if (s_axi_rid != 4'h6 || s_axi_rresp != 2'b00
                    || s_axi_rlast != (beat == 1)
                    || s_axi_rdata != ((beat == 0) ? expected_0 : expected_1))
                    $fatal(1, "AXI read beat mismatch");
                s_axi_rready = 1'b1;
                @(posedge clk);
                @(negedge clk);
                s_axi_rready = 1'b0;
            end
        end
    endtask

    task automatic axi_write_single(
        input logic [ADDR_WIDTH-1:0] address,
        input logic [DATA_WIDTH-1:0] data
    );
        begin
            @(negedge clk);
            s_axi_awid = 4'hb;
            s_axi_awaddr = address;
            s_axi_awlen = 0;
            s_axi_awsize = 3;
            s_axi_awburst = 2'b01;
            s_axi_awvalid = 1'b1;
            while (!s_axi_awready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            s_axi_awvalid = 1'b0;

            s_axi_wdata = data;
            s_axi_wstrb = '1;
            s_axi_wlast = 1'b1;
            s_axi_wvalid = 1'b1;
            while (!s_axi_wready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            s_axi_wvalid = 1'b0;

            while (!s_axi_bvalid) @(negedge clk);
            if (s_axi_bresp != 2'b00 || s_axi_bid != 4'hb)
                $fatal(1, "AXI single-write response error");
            @(posedge clk);
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            compute_count <= 0;
            compute_addr <= '0;
            compute_data <= '0;
        end else if (local_valid_out[COMPUTE_NODE][0]
                     && local_ready_in[COMPUTE_NODE][0]) begin
            compute_count <= compute_count + 1;
            compute_addr <= local_addr_out[COMPUTE_NODE][0];
            compute_data <= local_data_out[COMPUTE_NODE][0];
        end
    end

    initial begin
        logic [ADDR_WIDTH-1:0] scratchpad_base;
        logic [ADDR_WIDTH-1:0] compute_command;
        integer timeout;

        clk = 1'b0;
        rst_n = 1'b0;
        s_axi_awid = '0; s_axi_awaddr = '0; s_axi_awlen = '0;
        s_axi_awsize = 3; s_axi_awburst = 2'b01;
        s_axi_awlock = 0; s_axi_awcache = 0; s_axi_awprot = 0;
        s_axi_awqos = 0; s_axi_awvalid = 0;
        s_axi_wdata = '0; s_axi_wstrb = '0; s_axi_wlast = 0;
        s_axi_wvalid = 0; s_axi_bready = 1;
        s_axi_arid = '0; s_axi_araddr = '0; s_axi_arlen = '0;
        s_axi_arsize = 3; s_axi_arburst = 2'b01;
        s_axi_arlock = 0; s_axi_arcache = 0; s_axi_arprot = 0;
        s_axi_arqos = 0; s_axi_arvalid = 0; s_axi_rready = 0;

        for (int node = 0; node < NODES; node++) begin
            if ((node != SP_NODE) && (node != BRIDGE_NODE)) begin
                for (int channel = 0; channel < CHANNELS; channel++) begin
                    local_addr_in[node][channel] = '0;
                    local_data_in[node][channel] = '0;
                    local_valid_in[node][channel] = 1'b0;
                    local_ready_in[node][channel] = 1'b0;
                end
            end
        end
        local_ready_in[COMPUTE_NODE][0] = 1'b1;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        scratchpad_base = mesh_address(
            X_BITS'(0), Y_BITS'(0), 4'h0, 32'd8);
        axi_write_two(scratchpad_base,
                      64'h0123_4567_89ab_cdef,
                      64'hfeed_face_cafe_beef);
        repeat (20) @(posedge clk);
        axi_read_two(scratchpad_base,
                     64'h0123_4567_89ab_cdef,
                     64'hfeed_face_cafe_beef);

        // A single AXI write can carry a compute command/register packet.
        compute_command = mesh_address(
            X_BITS'(2), Y_BITS'(1), 4'hf, 32'hf000_0000);
        axi_write_single(compute_command, 64'h3);

        timeout = 0;
        while (compute_count < 1) begin
            @(negedge clk);
            timeout++;
            if (timeout > 300) $fatal(1, "compute command timeout");
        end
        if (compute_addr != compute_command || compute_data != 64'h3)
            $fatal(1, "compute command address/data mismatch");
        if (scratchpad_dma_busy || scratchpad_dma_error)
            $fatal(1, "unexpected scratchpad DMA state");

        $display("[PASS] AXI4 Full slave to mesh integration test");
        $finish;
    end

endmodule
