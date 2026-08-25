// AXI4 Full slave to two-channel mesh endpoint bridge.
//
// The bridge accepts one AXI transaction at a time. AXI writes become posted
// mesh channel-0 packets. AXI reads become scratchpad read packets on channel
// 0, and the corresponding channel-1 packet supplies AXI RDATA.

module axi4_mesh_bridge #(
    parameter int AXI_ID_WIDTH = 4,
    parameter int AXI_ADDR_WIDTH = 40,
    parameter int DATA_WIDTH = 64,
    parameter int CHANNELS = 2,
    parameter int MESH_X = 16,
    parameter int MESH_Y = 16,
    parameter int X_COORD = 0,
    parameter int Y_COORD = 0,
    // Mesh storage addresses are word-indexed. One AXI burst beat therefore
    // advances the mesh address by one by default, while AxSIZE remains 8 B.
    parameter int unsigned MESH_ADDR_STRIDE = 1
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn" *)
    input logic s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input logic s_axi_aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWID" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1" *)
    input  logic [AXI_ID_WIDTH-1:0] s_axi_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    input  logic [AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWLEN" *)
    input  logic [7:0] s_axi_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWSIZE" *)
    input  logic [2:0] s_axi_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWBURST" *)
    input  logic [1:0] s_axi_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWLOCK" *)
    input  logic s_axi_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWCACHE" *)
    input  logic [3:0] s_axi_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input  logic [2:0] s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWQOS" *)
    input  logic [3:0] s_axi_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  logic s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output logic s_axi_awready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  logic [DATA_WIDTH-1:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WLAST" *)
    input  logic s_axi_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  logic s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output logic s_axi_wready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BID" *)
    output logic [AXI_ID_WIDTH-1:0] s_axi_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output logic [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output logic s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  logic s_axi_bready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARID" *)
    input  logic [AXI_ID_WIDTH-1:0] s_axi_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  logic [AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARLEN" *)
    input  logic [7:0] s_axi_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARSIZE" *)
    input  logic [2:0] s_axi_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARBURST" *)
    input  logic [1:0] s_axi_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARLOCK" *)
    input  logic s_axi_arlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARCACHE" *)
    input  logic [3:0] s_axi_arcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input  logic [2:0] s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARQOS" *)
    input  logic [3:0] s_axi_arqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  logic s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output logic s_axi_arready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RID" *)
    output logic [AXI_ID_WIDTH-1:0] s_axi_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output logic [DATA_WIDTH-1:0] s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output logic [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RLAST" *)
    output logic s_axi_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output logic s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  logic s_axi_rready,

    input  logic [AXI_ADDR_WIDTH-1:0] mesh_addr_in [0:CHANNELS-1],
    input  logic [DATA_WIDTH-1:0] mesh_data_in [0:CHANNELS-1],
    input  logic mesh_valid_in [0:CHANNELS-1],
    output logic mesh_ready_out [0:CHANNELS-1],

    output logic [AXI_ADDR_WIDTH-1:0] mesh_addr_out [0:CHANNELS-1],
    output logic [DATA_WIDTH-1:0] mesh_data_out [0:CHANNELS-1],
    output logic mesh_valid_out [0:CHANNELS-1],
    input  logic mesh_ready_in [0:CHANNELS-1]
);
    localparam int X_BITS = (MESH_X > 1) ? $clog2(MESH_X) : 1;
    localparam int Y_BITS = (MESH_Y > 1) ? $clog2(MESH_Y) : 1;
    localparam int LOCAL_WIDTH = AXI_ADDR_WIDTH - X_BITS - Y_BITS;
    localparam int READ_METADATA_WIDTH
        = LOCAL_WIDTH - 4 - X_BITS - Y_BITS;
    localparam int BYTE_LANES = DATA_WIDTH / 8;
    localparam logic [2:0] EXPECTED_AXSIZE = 3'($clog2(BYTE_LANES));
    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;
    localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;
    localparam logic [1:0] AXI_BURST_FIXED = 2'b00;
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_WRITE_DATA,
        STATE_WRITE_RESPONSE,
        STATE_READ_SEND,
        STATE_READ_WAIT,
        STATE_READ_RESPONSE
    } state_t;

    state_t state;
    logic [AXI_ID_WIDTH-1:0] transaction_id;
    logic [7:0] burst_length;
    logic [7:0] beat_index;
    logic [1:0] burst_type;
    logic [AXI_ADDR_WIDTH-1:0] current_mesh_addr;
    logic write_error;
    logic read_error;

    logic write_full_strobe;
    logic write_expected_last;
    logic write_beat_error;
    logic write_fire;
    logic read_request_fire;
    logic read_response_fire;

    // Reference optional AXI sidebands without assigning behavior to them.
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_axi_sidebands;
    assign unused_axi_sidebands = ^{
        s_axi_awlock, s_axi_awcache, s_axi_awprot, s_axi_awqos,
        s_axi_arlock, s_axi_arcache, s_axi_arprot, s_axi_arqos,
        mesh_addr_in[0], mesh_data_in[0], mesh_valid_in[0]
    };
    /* verilator lint_on UNUSEDSIGNAL */

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [AXI_ADDR_WIDTH-1:0] make_read_request(
        input logic [AXI_ADDR_WIDTH-1:0] address
    );
        logic [READ_METADATA_WIDTH-1:0] metadata;
        begin
            metadata = address[READ_METADATA_WIDTH-1:0];
            make_read_request = {
                address[AXI_ADDR_WIDTH-1 -: X_BITS],
                address[AXI_ADDR_WIDTH-X_BITS-1 -: Y_BITS],
                4'h1,
                X_BITS'(X_COORD),
                Y_BITS'(Y_COORD),
                metadata
            };
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    assign write_full_strobe = &s_axi_wstrb;
    assign write_expected_last = (beat_index == burst_length);
    assign write_beat_error = write_error
        || !write_full_strobe
        || (s_axi_wlast != write_expected_last);

    always_comb begin
        s_axi_awready = (state == STATE_IDLE);
        s_axi_arready = (state == STATE_IDLE) && !s_axi_awvalid;
        s_axi_wready = 1'b0;

        for (int channel = 0; channel < CHANNELS; channel++) begin
            mesh_addr_out[channel] = '0;
            mesh_data_out[channel] = '0;
            mesh_valid_out[channel] = 1'b0;
            mesh_ready_out[channel] = 1'b0;
        end

        if (state == STATE_WRITE_DATA) begin
            mesh_addr_out[0] = current_mesh_addr;
            mesh_data_out[0] = s_axi_wdata;
            mesh_valid_out[0] = s_axi_wvalid
                && !write_error
                && write_full_strobe;
            if (write_error || !write_full_strobe) begin
                s_axi_wready = 1'b1;
            end else begin
                s_axi_wready = mesh_ready_in[0];
            end
        end else if (state == STATE_READ_SEND) begin
            mesh_addr_out[0] = make_read_request(current_mesh_addr);
            mesh_data_out[0] = '0;
            mesh_valid_out[0] = 1'b1;
        end

        if (state == STATE_READ_WAIT) begin
            mesh_ready_out[1] = !s_axi_rvalid;
        end
    end

    assign write_fire = s_axi_wvalid && s_axi_wready;
    assign read_request_fire = (state == STATE_READ_SEND)
        && mesh_ready_in[0];
    assign read_response_fire = (state == STATE_READ_WAIT)
        && mesh_valid_in[1]
        && mesh_ready_out[1];

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            state <= STATE_IDLE;
            transaction_id <= '0;
            burst_length <= '0;
            beat_index <= '0;
            burst_type <= AXI_BURST_INCR;
            current_mesh_addr <= '0;
            write_error <= 1'b0;
            read_error <= 1'b0;
            s_axi_bid <= '0;
            s_axi_bresp <= AXI_RESP_OKAY;
            s_axi_bvalid <= 1'b0;
            s_axi_rid <= '0;
            s_axi_rdata <= '0;
            s_axi_rresp <= AXI_RESP_OKAY;
            s_axi_rlast <= 1'b0;
            s_axi_rvalid <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    s_axi_bvalid <= 1'b0;
                    s_axi_rvalid <= 1'b0;
                    beat_index <= '0;

                    if (s_axi_awvalid && s_axi_awready) begin
                        state <= STATE_WRITE_DATA;
                        transaction_id <= s_axi_awid;
                        burst_length <= s_axi_awlen;
                        burst_type <= s_axi_awburst;
                        current_mesh_addr <= s_axi_awaddr;
                        write_error <= (s_axi_awsize != EXPECTED_AXSIZE)
                            || ((s_axi_awburst != AXI_BURST_FIXED)
                                && (s_axi_awburst != AXI_BURST_INCR));
                    end else if (s_axi_arvalid && s_axi_arready) begin
                        transaction_id <= s_axi_arid;
                        burst_length <= s_axi_arlen;
                        burst_type <= s_axi_arburst;
                        current_mesh_addr <= s_axi_araddr;
                        read_error <= (s_axi_arsize != EXPECTED_AXSIZE)
                            || ((s_axi_arburst != AXI_BURST_FIXED)
                                && (s_axi_arburst != AXI_BURST_INCR));
                        s_axi_rid <= s_axi_arid;
                        s_axi_rdata <= '0;
                        s_axi_rresp <= AXI_RESP_SLVERR;
                        s_axi_rlast <= (s_axi_arlen == 0);
                        if ((s_axi_arsize != EXPECTED_AXSIZE)
                            || ((s_axi_arburst != AXI_BURST_FIXED)
                                && (s_axi_arburst != AXI_BURST_INCR))) begin
                            s_axi_rvalid <= 1'b1;
                            state <= STATE_READ_RESPONSE;
                        end else begin
                            state <= STATE_READ_SEND;
                        end
                    end
                end

                STATE_WRITE_DATA: begin
                    if (write_fire) begin
                        write_error <= write_beat_error;
                        if (write_expected_last) begin
                            s_axi_bid <= transaction_id;
                            s_axi_bresp <= write_beat_error
                                ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
                            s_axi_bvalid <= 1'b1;
                            state <= STATE_WRITE_RESPONSE;
                        end else begin
                            beat_index <= beat_index + 1'b1;
                            if (burst_type == AXI_BURST_INCR) begin
                                current_mesh_addr <= current_mesh_addr
                                    + AXI_ADDR_WIDTH'(MESH_ADDR_STRIDE);
                            end
                        end
                    end
                end

                STATE_WRITE_RESPONSE: begin
                    if (s_axi_bvalid && s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        state <= STATE_IDLE;
                    end
                end

                STATE_READ_SEND: begin
                    if (read_request_fire) begin
                        state <= STATE_READ_WAIT;
                    end
                end

                STATE_READ_WAIT: begin
                    if (read_response_fire) begin
                        s_axi_rid <= transaction_id;
                        s_axi_rdata <= mesh_data_in[1];
                        s_axi_rresp <= AXI_RESP_OKAY;
                        s_axi_rlast <= (beat_index == burst_length);
                        s_axi_rvalid <= 1'b1;
                        state <= STATE_READ_RESPONSE;
                    end
                end

                STATE_READ_RESPONSE: begin
                    if (s_axi_rvalid && s_axi_rready) begin
                        if (s_axi_rlast) begin
                            s_axi_rvalid <= 1'b0;
                            state <= STATE_IDLE;
                        end else begin
                            beat_index <= beat_index + 1'b1;
                            if (burst_type == AXI_BURST_INCR) begin
                                current_mesh_addr <= current_mesh_addr
                                    + AXI_ADDR_WIDTH'(MESH_ADDR_STRIDE);
                            end

                            if (read_error) begin
                                s_axi_rdata <= '0;
                                s_axi_rresp <= AXI_RESP_SLVERR;
                                s_axi_rlast
                                    <= (beat_index + 1'b1 == burst_length);
                                s_axi_rvalid <= 1'b1;
                            end else begin
                                s_axi_rvalid <= 1'b0;
                                state <= STATE_READ_SEND;
                            end
                        end
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

    initial begin
        if ((AXI_ADDR_WIDTH != 40) || (DATA_WIDTH != 64)
            || (CHANNELS != 2)) begin
            $error("bridge currently targets the 40-bit/64-bit/two-channel mesh");
        end
        if ((BYTE_LANES & (BYTE_LANES - 1)) != 0
            || (READ_METADATA_WIDTH < 1)) begin
            $error("invalid AXI data or mesh address width");
        end
    end

endmodule
