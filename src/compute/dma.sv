// One-word-per-cycle (after BRAM latency) DMA engine for the C result banks.
//
// A transfer reads the same address from all C banks, packs their low-byte
// lanes into one DATA_WIDTH word, and either presents that word on the device
// stream or writes it to one selected A/B bank.  The output handshake is
// independent of the BRAM read request, so a stalled device bus cannot lose a
// result or advance the source address.

module compute_dma #(
    parameter int DATA_WIDTH = 64,
    parameter int ADDR_WIDTH = 9,
    parameter int BANKS = 8,
    parameter int LANE_WIDTH = 8
)(
    input  logic clk,
    input  logic rst_n,

    input  logic request,
    input  logic [1:0] destination,
    input  logic [(BANKS > 1 ? $clog2(BANKS) : 1)-1:0] destination_bank,
    input  logic [ADDR_WIDTH-1:0] source_base,
    input  logic [ADDR_WIDTH-1:0] destination_base,
    input  logic [ADDR_WIDTH:0] transfer_length,
    output logic busy,

    output logic [ADDR_WIDTH-1:0] c_read_addr,
    input  logic [DATA_WIDTH-1:0] c_data [0:BANKS-1],

    output logic a_write_enable,
    output logic b_write_enable,
    output logic [(BANKS > 1 ? $clog2(BANKS) : 1)-1:0] write_bank,
    output logic [ADDR_WIDTH-1:0] write_addr,
    output logic [DATA_WIDTH-1:0] write_data,

    output logic [DATA_WIDTH-1:0] data_out,
    output logic data_out_valid,
    input logic data_out_ready
);

    localparam int BANK_SEL_WIDTH = (BANKS > 1) ? $clog2(BANKS) : 1;
    localparam logic [1:0] DEST_EXTERNAL = 2'd0;

    logic [1:0] destination_q;
    logic [BANK_SEL_WIDTH-1:0] destination_bank_q;
    logic [ADDR_WIDTH-1:0] source_base_q;
    logic [ADDR_WIDTH-1:0] destination_base_q;
    logic [ADDR_WIDTH:0] transfer_length_q;
    logic [ADDR_WIDTH:0] transfer_index;
    logic response_pending;

    logic [DATA_WIDTH-1:0] packed_c_data;

    assign c_read_addr = source_base_q + ADDR_WIDTH'(transfer_index);

    // One packed C row becomes one A/B bank word.  The configured bank is the
    // starting bank; subsequent rows advance through the banks and wrap at
    // BANKS, which makes a complete 8x8 result directly launchable as A data.
    integer write_bank_index;
    always_comb begin
        write_bank_index = int'(destination_bank_q) + int'(transfer_index);
        write_bank = BANK_SEL_WIDTH'(write_bank_index % BANKS);
    end
    assign write_addr = destination_base_q + ADDR_WIDTH'(transfer_index);
    assign a_write_enable = busy && (destination_q == 2'd1) && response_pending;
    assign b_write_enable = busy && (destination_q == 2'd2) && response_pending;
    assign write_data = packed_c_data;

    always_comb begin
        packed_c_data = '0;
        for (int bank = 0; bank < BANKS; bank++) begin
            packed_c_data[bank*LANE_WIDTH +: LANE_WIDTH]
                = c_data[bank][LANE_WIDTH-1:0];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            destination_q <= DEST_EXTERNAL;
            destination_bank_q <= '0;
            source_base_q <= '0;
            destination_base_q <= '0;
            transfer_length_q <= '0;
            transfer_index <= '0;
            response_pending <= 1'b0;
            data_out <= '0;
            data_out_valid <= 1'b0;
        end else begin
            if (!busy) begin
                response_pending <= 1'b0;
                data_out_valid <= 1'b0;

                if (request && (transfer_length != 0)) begin
                    busy <= 1'b1;
                    destination_q <= destination;
                    destination_bank_q <= destination_bank;
                    source_base_q <= source_base;
                    destination_base_q <= destination_base;
                    transfer_length_q <= transfer_length;
                    transfer_index <= '0;
                end
            end else if (destination_q == DEST_EXTERNAL) begin
                // A response is consumed only after the external bus accepts
                // it.  data_out therefore remains stable during a stall.
                if (data_out_valid && data_out_ready) begin
                    data_out_valid <= 1'b0;
                    if (transfer_index == transfer_length_q - 1'b1) begin
                        busy <= 1'b0;
                    end else begin
                        transfer_index <= transfer_index + 1'b1;
                    end
                end

                if (response_pending) begin
                    data_out <= packed_c_data;
                    data_out_valid <= 1'b1;
                    response_pending <= 1'b0;
                end else if (busy && !response_pending && !data_out_valid) begin
                    response_pending <= 1'b1;
                end
            end else begin
                // For A/B destinations, the BRAM write port consumes the
                // pending response on this edge.
                if (response_pending) begin
                    response_pending <= 1'b0;
                    if (transfer_index == transfer_length_q - 1'b1) begin
                        busy <= 1'b0;
                    end else begin
                        transfer_index <= transfer_index + 1'b1;
                    end
                end else if (busy && !response_pending) begin
                    response_pending <= 1'b1;
                end
            end
        end
    end

    initial begin
        if (DATA_WIDTH < BANKS * LANE_WIDTH) begin
            $error("DMA DATA_WIDTH is too small for all C-bank lanes");
        end
    end

endmodule
