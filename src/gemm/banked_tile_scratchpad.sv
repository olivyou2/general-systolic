module banked_tile_scratchpad #(
    parameter lanes = 8,
    parameter element_width = 8,
    parameter words_per_tile = 32,
    parameter tile_slots = 2
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [$clog2(tile_slots > 1 ? tile_slots : 2)-1:0] write_slot,
    input  logic [lanes*element_width-1:0] stream_data_in,
    input  logic stream_valid_in,
    output wire stream_ready_out,

    input  logic release_valid,
    input  logic [$clog2(tile_slots > 1 ? tile_slots : 2)-1:0] release_slot,
    output wire [tile_slots-1:0] tile_ready_out,

    input  logic read_request_valid,
    output wire read_request_ready,
    input  logic [$clog2(tile_slots*words_per_tile > 1
                         ? tile_slots*words_per_tile : 2)-1:0] read_request_address,
    input  logic read_request_last,
    output wire [lanes*element_width-1:0] read_data_out,
    output wire read_data_valid_out,
    input  logic read_data_ready_in,
    output wire read_data_last_out
);
    localparam int total_words = tile_slots * words_per_tile;
    localparam int count_width = $clog2(words_per_tile + 1);

    logic [element_width-1:0] banks [0:lanes-1][0:total_words-1];
    logic [count_width-1:0] write_count [0:tile_slots-1];
    logic [tile_slots-1:0] tile_ready_reg;

    logic [lanes*element_width-1:0] read_data_reg;
    logic read_data_valid_reg;
    logic read_data_last_reg;

    assign tile_ready_out = tile_ready_reg;
    assign stream_ready_out
        = !tile_ready_reg[write_slot]
        && (write_count[write_slot] < words_per_tile);
    assign read_request_ready = !read_data_valid_reg || read_data_ready_in;
    assign read_data_out = read_data_reg;
    assign read_data_valid_out = read_data_valid_reg;
    assign read_data_last_out = read_data_last_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tile_ready_reg <= '0;
            read_data_reg <= '0;
            read_data_valid_reg <= 1'b0;
            read_data_last_reg <= 1'b0;
            for (int slot = 0; slot < tile_slots; slot++) begin
                write_count[slot] <= '0;
            end
        end else begin
            if (release_valid) begin
                tile_ready_reg[release_slot] <= 1'b0;
                write_count[release_slot] <= '0;
            end

            if (stream_valid_in && stream_ready_out) begin
                for (int lane = 0; lane < lanes; lane++) begin
                    banks[lane][write_slot * words_per_tile
                                + write_count[write_slot]]
                        <= stream_data_in[lane*element_width +: element_width];
                end

                if (write_count[write_slot] == words_per_tile - 1) begin
                    tile_ready_reg[write_slot] <= 1'b1;
                    write_count[write_slot] <= words_per_tile;
                end else begin
                    write_count[write_slot] <= write_count[write_slot] + 1'b1;
                end
            end

            if (read_request_valid && read_request_ready) begin
                for (int lane = 0; lane < lanes; lane++) begin
                    read_data_reg[lane*element_width +: element_width]
                        <= banks[lane][read_request_address];
                end
                read_data_valid_reg <= 1'b1;
                read_data_last_reg <= read_request_last;
            end else if (read_data_valid_reg && read_data_ready_in) begin
                read_data_valid_reg <= 1'b0;
                read_data_last_reg <= 1'b0;
            end
        end
    end

endmodule
