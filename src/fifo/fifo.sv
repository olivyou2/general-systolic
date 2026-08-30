// Synchronous-read BRAM FIFO with a two-entry output skid buffer.

module fifo #(
    parameter int DATA_WIDTH = 64,
    parameter int FIFO_DEPTH = 512  // 64-bit x 512 = 4 KiB
)(
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic [DATA_WIDTH-1:0] data_in,
    input  logic                  data_in_valid,
    output logic                  data_in_ready,

    output logic [DATA_WIDTH-1:0] data_out,
    output logic                  data_out_valid,
    input  logic                  data_out_ready
);

    localparam int PTR_WIDTH   = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
    localparam int COUNT_WIDTH = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH + 1) : 1;
    localparam logic [PTR_WIDTH-1:0] LAST_ADDRESS = PTR_WIDTH'(FIFO_DEPTH - 1);
    localparam logic [COUNT_WIDTH-1:0] DEPTH_COUNT = COUNT_WIDTH'(FIFO_DEPTH);

    // A synchronous read port and a synchronous write port infer a simple
    // dual-port block RAM on common FPGA synthesis tools.
    (* ram_style = "block" *)
    logic [DATA_WIDTH-1:0] memory [0:FIFO_DEPTH-1];

    logic [PTR_WIDTH-1:0] write_pointer;
    logic [PTR_WIDTH-1:0] read_pointer;

    // total_count includes words in BRAM, an outstanding BRAM read, and both
    // output-buffer entries. ram_count includes only words whose BRAM read has
    // not yet been requested.
    logic [COUNT_WIDTH-1:0] total_count;
    logic [COUNT_WIDTH-1:0] ram_count;

    logic [DATA_WIDTH-1:0] ram_read_data;
    logic                  read_pending;
    logic                  read_issue;

    logic [DATA_WIDTH-1:0] head_data;
    logic [DATA_WIDTH-1:0] skid_data;
    logic [1:0]            output_count;

    logic push;
    logic pop;
    logic read_response;

    initial begin
        if (FIFO_DEPTH < 1) begin
            $error("FIFO_DEPTH must be at least one");
        end
    end

    assign data_in_ready  = (total_count < DEPTH_COUNT);
    assign data_out       = head_data;
    assign data_out_valid = (output_count != 0);

    assign push          = data_in_valid && data_in_ready;
    assign pop           = data_out_valid && data_out_ready;
    assign read_response = read_pending;

    // read_pending reserves one output-buffer entry. A pop frees an entry on
    // this edge, so another BRAM read may be launched on the same edge.
    // data_in_ready is deliberately absent from this downstream ready path.
    always_comb begin
        read_issue = 1'b0;
        if (ram_count != 0) begin
            case ({read_pending, pop})
                2'b00: read_issue = (output_count < 2);
                2'b01: read_issue = 1'b1;
                2'b10: read_issue = (output_count < 1);
                2'b11: read_issue = (output_count < 2);
                default: read_issue = 1'b0;
            endcase
        end
    end

    // BRAM write and synchronous read ports.
    always_ff @(posedge clk) begin
        if (push) begin
            memory[write_pointer] <= data_in;
        end

        if (read_issue) begin
            ram_read_data <= memory[read_pointer];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_pointer <= '0;
            read_pointer  <= '0;
            total_count   <= '0;
            ram_count     <= '0;
            read_pending  <= 1'b0;
            head_data     <= '0;
            skid_data     <= '0;
            output_count  <= '0;
        end else begin
            if (push) begin
                if (write_pointer == LAST_ADDRESS) begin
                    write_pointer <= '0;
                end else begin
                    write_pointer <= write_pointer + 1'b1;
                end
            end

            if (read_issue) begin
                if (read_pointer == LAST_ADDRESS) begin
                    read_pointer <= '0;
                end else begin
                    read_pointer <= read_pointer + 1'b1;
                end
            end

            case ({push, pop})
                2'b10: total_count <= total_count + 1'b1;
                2'b01: total_count <= total_count - 1'b1;
                default: total_count <= total_count;
            endcase

            case ({push, read_issue})
                2'b10: ram_count <= ram_count + 1'b1;
                2'b01: ram_count <= ram_count - 1'b1;
                default: ram_count <= ram_count;
            endcase

            read_pending <= read_issue;

            // Two-entry head+skid queue. The head remains stable throughout a
            // downstream stall, including while one BRAM read is outstanding.
            case ({pop, read_response})
                2'b01: begin
                    if (output_count == 0) begin
                        head_data <= ram_read_data;
                    end else begin
                        skid_data <= ram_read_data;
                    end
                    output_count <= output_count + 1'b1;
                end

                2'b10: begin
                    if (output_count == 2) begin
                        head_data <= skid_data;
                    end
                    output_count <= output_count - 1'b1;
                end

                2'b11: begin
                    if (output_count == 1) begin
                        head_data <= ram_read_data;
                    end else begin
                        head_data <= skid_data;
                        skid_data <= ram_read_data;
                    end
                    output_count <= output_count;
                end

                default: output_count <= output_count;
            endcase
        end
    end

endmodule
