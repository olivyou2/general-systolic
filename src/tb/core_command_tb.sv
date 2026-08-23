// Command-file driven testbench for the packetized compute core.
//
// Usage:
//   simulator --binary --timing -I./src \
//     --top-module core_command_tb \
//     src/fifo/fifo.sv src/bram_sim/bram.sv src/compute/dma.sv \
//     src/compute/launcher.sv src/compute/systolic.sv src/compute/core.sv \
//     src/tb/core_command_tb.sv
//   ./obj_dir/Vcore_command_tb +CMD_FILE=src/tb/commands/core_cnn_smoke.cmd
//
// Command syntax (one command per line; blank lines and '#' comments are
// ignored):
//   WRITE <32-bit address, hex> <64-bit data, hex>
//   WAIT <number of clock cycles, decimal>
//   READY <0|1>                 // dev_data_out_ready
//   EXPECT <64-bit data, hex>   // waits for and consumes one output word
//   EXPECT_NONE <cycles>        // asserts no output for this many cycles
//   END
//
// WRITE applies the packet stream handshake, so the command file also tests
// ingress backpressure when the core is busy. EXPECT keeps output ready high
// unless READY 0 was explicitly requested.

module core_command_tb #(
    parameter int DATA_WIDTH = 64
)();

    localparam int MAX_WAIT_CYCLES = 100000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic [DATA_WIDTH-1:0] dev_data_in = '0;
    logic [31:0]           dev_addr_in = '0;
    logic                  dev_data_in_valid = 1'b0;
    logic                  dev_data_in_ready;

    logic [DATA_WIDTH-1:0] dev_data_out;
    logic                  dev_data_out_valid;
    logic                  dev_data_out_ready = 1'b1;

    core #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .dev_data_in       (dev_data_in),
        .dev_addr_in       (dev_addr_in),
        .dev_data_in_valid (dev_data_in_valid),
        .dev_data_in_ready (dev_data_in_ready),
        .dev_data_out      (dev_data_out),
        .dev_data_out_valid(dev_data_out_valid),
        .dev_data_out_ready(dev_data_out_ready)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        #1;
        if (trace_enabled && rst_n) begin
            $display("[TRACE] t=%0t rst=%b in_rdy=%b iv=%b ip=%b pa=%h pd=%h launch_busy=%b drain=%b dma=%b cnn_k=%0d iw=%0d ih=%0d ic=%0d kw=%0d kh=%0d outw=%0d out_v=%b out=%h",
                     $time(), rst_n, dev_data_in_ready, dut.ingress_valid_out,
                     dut.ingress_pop,
                     dut.packet_addr, dut.packet_data,
                     dut.launcher_busy, dut.drain_active, dut.dma_busy,
                     dut.cnn_k_total,
                     dut.cnn_input_width, dut.cnn_input_height,
                     dut.cnn_input_channels, dut.cnn_kernel_width,
                     dut.cnn_kernel_height, dut.cnn_output_width,
                     dev_data_out_valid, dev_data_out);
        end
    end

    integer error_count = 0;
    integer command_count = 0;
    bit trace_enabled = 1'b0;

    task automatic tick();
        @(posedge clk);
        #1;
    endtask

    task automatic reset_dut();
        dev_data_in       = '0;
        dev_addr_in       = '0;
        dev_data_in_valid = 1'b0;
        dev_data_out_ready = 1'b1;
        rst_n = 1'b0;
        repeat (3) tick();
        rst_n = 1'b1;
        repeat (2) tick();
    endtask

    task automatic send_packet(
        input logic [31:0]           address,
        input logic [DATA_WIDTH-1:0] data
    );
        integer wait_cycles;
        begin
            // Change packet fields away from the active clock edge.  This
            // keeps the driver race-free with both RTL and cycle simulators.
            @(negedge clk);
            dev_addr_in       = address;
            dev_data_in       = data;
            dev_data_in_valid = 1'b1;
            if (trace_enabled) begin
                $display("[CMD WRITE] addr=%h data=%h", address, data);
            end
            wait_cycles = 0;
            do begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
                if (wait_cycles >= MAX_WAIT_CYCLES) begin
                    $fatal(1, "WRITE timeout: addr=%h data=%h", address, data);
                end
            end while (!dev_data_in_ready);
            @(negedge clk);
            dev_data_in_valid = 1'b0;
        end
    endtask

    task automatic wait_output(
        input logic [DATA_WIDTH-1:0] expected
    );
        integer wait_cycles;
        begin
            // An EXPECT is a consuming read.  This makes command files
            // deterministic even if READY 0 was used for a prior stall test.
            dev_data_out_ready = 1'b1;
            wait_cycles = 0;
            while (!dev_data_out_valid) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
                if (wait_cycles >= MAX_WAIT_CYCLES) begin
                    $fatal(1, "EXPECT timeout: expected=%h", expected);
                end
            end
            if (dev_data_out !== expected) begin
                $error("EXPECT mismatch: expected=%h got=%h", expected,
                       dev_data_out);
                error_count = error_count + 1;
            end
            // Consume the currently presented word.  READY has been high for
            // the whole cycle in which it was observed.
            @(posedge clk);
            #1;
        end
    endtask

    task automatic expect_no_output(input integer cycles);
        begin
            for (integer i = 0; i < cycles; i++) begin
                @(posedge clk);
                #1;
                if (dev_data_out_valid) begin
                    $error("Unexpected output at cycle %0d: %h", i,
                           dev_data_out);
                    error_count = error_count + 1;
                end
            end
        end
    endtask

    task automatic execute_command(input string line, input integer line_no);
        string op;
        logic [31:0] address;
        logic [DATA_WIDTH-1:0] data;
        integer value;
        integer parsed;
        begin
            op = "";
            if ($sscanf(line, "%s", op) != 1) begin
                return;
            end
            // Only '#' comments are specified, but accepting '//' here is
            // convenient when command files are edited beside RTL.
            if ((op.len() != 0) && ((op.getc(0) == "#")
                                    || (op == "//"))) begin
                return;
            end

            if (op == "WRITE") begin
                address = '0;
                data = '0;
                parsed = $sscanf(line, "%s %h %h", op, address, data);
                if (parsed != 3) begin
                    $fatal(1, "Malformed WRITE at line %0d: %s",
                           line_no, line);
                end
                send_packet(address, data);
            end else if (op == "WAIT") begin
                value = 0;
                parsed = $sscanf(line, "%s %d", op, value);
                if (parsed != 2 || value < 0) begin
                    $fatal(1, "Malformed WAIT at line %0d: %s",
                           line_no, line);
                end
                repeat (value) tick();
            end else if (op == "READY") begin
                value = 0;
                parsed = $sscanf(line, "%s %d", op, value);
                if (parsed != 2 || (value != 0 && value != 1)) begin
                    $fatal(1, "Malformed READY at line %0d: %s",
                           line_no, line);
                end
                dev_data_out_ready = value[0];
            end else if (op == "EXPECT") begin
                data = '0;
                parsed = $sscanf(line, "%s %h", op, data);
                if (parsed != 2) begin
                    $fatal(1, "Malformed EXPECT at line %0d: %s",
                           line_no, line);
                end
                if (trace_enabled) begin
                    $display("[CMD EXPECT] data=%h", data);
                end
                wait_output(data);
            end else if (op == "EXPECT_NONE") begin
                value = 0;
                parsed = $sscanf(line, "%s %d", op, value);
                if (parsed != 2 || value < 0) begin
                    $fatal(1, "Malformed EXPECT_NONE at line %0d: %s",
                           line_no, line);
                end
                expect_no_output(value);
            end else if (op == "END") begin
                return;
            end else begin
                $fatal(1, "Unknown command at line %0d: %s", line_no, line);
            end
            command_count = command_count + 1;
        end
    endtask

    initial begin
        string command_file;
        string line;
        integer fd;
        integer line_no;
        integer status;
        bit saw_end;

        if (!$value$plusargs("CMD_FILE=%s", command_file)) begin
            command_file = "src/tb/commands/core_cnn_smoke.cmd";
        end
        trace_enabled = $test$plusargs("TRACE");
        fd = $fopen(command_file, "r");
        if (fd == 0) begin
            $fatal(1, "Cannot open command file: %s", command_file);
        end

        reset_dut();
        line_no = 0;
        saw_end = 1'b0;
        while (!$feof(fd)) begin
            status = $fgets(line, fd);
            if (status != 0) begin
                line_no = line_no + 1;
                if ($sscanf(line, "%s", command_file) == 1
                    && command_file == "END") begin
                    saw_end = 1'b1;
                    break;
                end
                execute_command(line, line_no);
            end
        end
        $fclose(fd);

        if (!saw_end) begin
            $error("Command file ended without END");
            error_count = error_count + 1;
        end
        if (error_count == 0) begin
            $display("[PASS] command TB completed: %0d commands", command_count);
        end else begin
            $fatal(1, "[FAIL] command TB found %0d error(s)", error_count);
        end
        $finish;
    end

endmodule
