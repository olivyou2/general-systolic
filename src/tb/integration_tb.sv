// module systolic_integration_tb;

//     localparam SYSTOLIC_WIDTH  = 8;
//     localparam SYSTOLIC_HEIGHT = 8;
//     localparam ADDR_WIDTH      = 9;
//     localparam DATA_WIDTH      = 64;

//     localparam logic [ADDR_WIDTH-1:0] A_BASE_OFFSET = 9'd17;
//     localparam logic [ADDR_WIDTH-1:0] B_BASE_OFFSET = 9'd29;

//     logic clk   = 0;
//     logic rst_n = 1;

//     logic [ADDR_WIDTH-1:0] a_mat_base_offset = A_BASE_OFFSET;
//     logic [ADDR_WIDTH-1:0] b_mat_base_offset = B_BASE_OFFSET;

//     wire [ADDR_WIDTH-1:0] a_addr[SYSTOLIC_HEIGHT];
//     wire [DATA_WIDTH-1:0] a_data[SYSTOLIC_HEIGHT];

//     wire [ADDR_WIDTH-1:0] b_addr[SYSTOLIC_WIDTH];
//     wire [DATA_WIDTH-1:0] b_data[SYSTOLIC_WIDTH];

//     logic addr_gen_fire = 0;
//     wire addr_gen_busy;

//     wire [7:0] systolic_vertical_bar[SYSTOLIC_HEIGHT];
//     wire [7:0] systolic_horizontal_bar[SYSTOLIC_WIDTH];

//     wire systolic_add_signal;
//     wire systolic_flow_v_signal;
//     wire systolic_flow_h_signal;
//     wire systolic_broad_v_signal;
//     wire systolic_broad_h_signal;

//     logic systolic_drain_signal = 0;
//     wire [7:0] systolic_drain_bar[SYSTOLIC_WIDTH];

//     integer error_count = 0;

//     // One BRAM bank supplies each row of A.
//     generate
//         genvar a_bank;
//         for (a_bank=0; a_bank<SYSTOLIC_HEIGHT; a_bank++) begin: a_bram
//             bram #(
//                 .ADDR_WIDTH(ADDR_WIDTH),
//                 .DATA_WIDTH(DATA_WIDTH)
//             ) memory (
//                 .clk(clk),
//                 .addr(a_addr[a_bank]),
//                 .data_in({DATA_WIDTH{1'b0}}),
//                 .we(1'b0),
//                 .data_out(a_data[a_bank])
//             );
//         end
//     endgenerate

//     // One BRAM bank supplies each step of B.
//     generate
//         genvar b_bank;
//         for (b_bank=0; b_bank<SYSTOLIC_WIDTH; b_bank++) begin: b_bram
//             bram #(
//                 .ADDR_WIDTH(ADDR_WIDTH),
//                 .DATA_WIDTH(DATA_WIDTH)
//             ) memory (
//                 .clk(clk),
//                 .addr(b_addr[b_bank]),
//                 .data_in({DATA_WIDTH{1'b0}}),
//                 .we(1'b0),
//                 .data_out(b_data[b_bank])
//             );
//         end
//     endgenerate

//     systolic_launcher #(
//         .A_DATAWIDTH(DATA_WIDTH),
//         .A_ADDRWIDTH(ADDR_WIDTH),
//         .A_BANKS(SYSTOLIC_HEIGHT),
//         .B_DATAWIDTH(DATA_WIDTH),
//         .B_ADDRWIDTH(ADDR_WIDTH),
//         .B_BANKS(SYSTOLIC_WIDTH),
//         .SYSTOLIC_WIDTH(SYSTOLIC_WIDTH),
//         .SYSTOLIC_HEIGHT(SYSTOLIC_HEIGHT)
//     ) launcher_dut (
//         .clk(clk),
//         .rst_n(rst_n),
//         .a_mat_base_offset(a_mat_base_offset),
//         .b_mat_base_offset(b_mat_base_offset),
//         .a_addr(a_addr),
//         .a_data(a_data),
//         .b_addr(b_addr),
//         .b_data(b_data),
//         .fire(addr_gen_fire),
//         .busy(addr_gen_busy),
//         .systolic_vertical_bar(systolic_vertical_bar),
//         .systolic_horizontal_bar(systolic_horizontal_bar),
//         .systolic_add_signal(systolic_add_signal),
//         .systolic_flow_v_signal(systolic_flow_v_signal),
//         .systolic_flow_h_signal(systolic_flow_h_signal),
//         .systolic_broad_v_signal(systolic_broad_v_signal),
//         .systolic_broad_h_signal(systolic_broad_h_signal)
//     );

//     systolic #(
//         .WIDTH(SYSTOLIC_WIDTH),
//         .HEIGHT(SYSTOLIC_HEIGHT)
//     ) systolic_dut (
//         .clk(clk),
//         .rst_n(rst_n),
//         .vertical_bar(systolic_vertical_bar),
//         .horizontal_bar(systolic_horizontal_bar),
//         .horizontal_drain_bar(systolic_drain_bar),
//         .result_saturation(4'd0),
//         .add(systolic_add_signal),
//         .flow_v(systolic_flow_v_signal),
//         .flow_h(systolic_flow_h_signal),
//         .drain(systolic_drain_signal),
//         .broad_v(systolic_broad_v_signal),
//         .broad_h(systolic_broad_h_signal)
//     );

//     task automatic tick();
//         clk = 1;
//         #1;
//         clk = 0;
//         #1;
//     endtask

//     task automatic reset_chip();
//         rst_n = 0;
//         #10;
//         rst_n = 1;
//         #10;
//     endtask

//     task automatic initialize_bram();
//         // Byte k in A bank y is (y * 10) + k + 1.
//         a_bram[0].memory.data[A_BASE_OFFSET] = 64'h0807060504030201;
//         a_bram[1].memory.data[A_BASE_OFFSET] = 64'h1211100f0e0d0c0b;
//         a_bram[2].memory.data[A_BASE_OFFSET] = 64'h1c1b1a1918171615;
//         a_bram[3].memory.data[A_BASE_OFFSET] = 64'h262524232221201f;
//         a_bram[4].memory.data[A_BASE_OFFSET] = 64'h302f2e2d2c2b2a29;
//         a_bram[5].memory.data[A_BASE_OFFSET] = 64'h3a39383736353433;
//         a_bram[6].memory.data[A_BASE_OFFSET] = 64'h44434241403f3e3d;
//         a_bram[7].memory.data[A_BASE_OFFSET] = 64'h4e4d4c4b4a494847;

//         // Byte x in B bank k is k + x + 1.
//         b_bram[0].memory.data[B_BASE_OFFSET] = 64'h0807060504030201;
//         b_bram[1].memory.data[B_BASE_OFFSET] = 64'h0908070605040302;
//         b_bram[2].memory.data[B_BASE_OFFSET] = 64'h0a09080706050403;
//         b_bram[3].memory.data[B_BASE_OFFSET] = 64'h0b0a090807060504;
//         b_bram[4].memory.data[B_BASE_OFFSET] = 64'h0c0b0a0908070605;
//         b_bram[5].memory.data[B_BASE_OFFSET] = 64'h0d0c0b0a09080706;
//         b_bram[6].memory.data[B_BASE_OFFSET] = 64'h0e0d0c0b0a090807;
//         b_bram[7].memory.data[B_BASE_OFFSET] = 64'h0f0e0d0c0b0a0908;
//     endtask

//     task automatic check_equal(
//         input logic [31:0] actual,
//         input logic [31:0] expected,
//         input string name
//     );
//         if (actual !== expected) begin
//             $error("%s: expected %0d, got %0d", name, expected, actual);
//             error_count = error_count + 1;
//         end
//     endtask

//     task automatic check_launcher_step(input integer step);
//         for (integer row=0; row<SYSTOLIC_HEIGHT; row++) begin
//             check_equal(
//                 systolic_vertical_bar[row],
//                 row * 10 + step + 1,
//                 $sformatf("vertical_bar[%0d], step %0d", row, step)
//             );
//         end

//         for (integer col=0; col<SYSTOLIC_WIDTH; col++) begin
//             check_equal(
//                 systolic_horizontal_bar[col],
//                 step + col + 1,
//                 $sformatf("horizontal_bar[%0d], step %0d", col, step)
//             );
//         end
//     endtask

//     task automatic launch();
//         addr_gen_fire = 1;
//         tick();
//         addr_gen_fire = 0;

//         check_equal(addr_gen_busy, 1, "busy after fire");

//         // Account for the synchronous BRAM read latency.
//         tick();

//         check_equal(systolic_broad_v_signal, 1, "vertical broadcast");
//         check_equal(systolic_broad_h_signal, 1, "horizontal broadcast");

//         for (integer bank=0; bank<SYSTOLIC_HEIGHT; bank++) begin
//             check_equal(a_addr[bank], A_BASE_OFFSET, $sformatf("a_addr[%0d]", bank));
//             check_equal(b_addr[bank], B_BASE_OFFSET, $sformatf("b_addr[%0d]", bank));
//         end

//         for (integer step=0; step<SYSTOLIC_WIDTH; step++) begin
//             check_equal(addr_gen_busy, 1, $sformatf("busy, step %0d", step));
//             check_launcher_step(step);
//             tick();
//             check_equal(systolic_add_signal, 1, $sformatf("add, step %0d", step));
//         end

//         // The final state drops add and busy before accepting another launch.
//         tick();
//         check_equal(systolic_add_signal, 0, "add after completion");
//         check_equal(addr_gen_busy, 0, "busy after completion");
//     endtask

//     task automatic check_systolic_result();
//         for (integer row=0; row<SYSTOLIC_HEIGHT; row++) begin
//             for (integer col=0; col<SYSTOLIC_WIDTH; col++) begin
//                 check_equal(
//                     systolic_dut.result[col][row],
//                     204 + col * 36 + row * (360 + col * 80),
//                     $sformatf("result[%0d][%0d]", col, row)
//                 );
//             end
//         end
//     endtask

//     task automatic drain_and_check();
//         systolic_drain_signal = 1;

//         for (integer drain_step=0; drain_step<SYSTOLIC_HEIGHT; drain_step++) begin
//             tick();

//             for (integer col=0; col<SYSTOLIC_WIDTH; col++) begin
//                 check_equal(
//                     systolic_drain_bar[col],
//                     (204 + col * 36
//                         + (SYSTOLIC_HEIGHT - 1 - drain_step) * (360 + col * 80)) & 8'hff,
//                     $sformatf("drain_bar[%0d], step %0d", col, drain_step)
//                 );
//             end
//         end

//         systolic_drain_signal = 0;
//     endtask

//     initial begin
//         initialize_bram();
//         reset_chip();
//         launch();
//         check_systolic_result();
//         drain_and_check();

//         if (error_count == 0) begin
//             $display("[PASS] systolic integration test completed");
//         end else begin
//             $fatal(1, "[FAIL] systolic integration test found %0d error(s)", error_count);
//         end

//         $finish;
//     end

//     always @(posedge clk) begin
//         $display(
//             "[CLK] time=%0t busy=%0b add=%0b A0=%0d B0=%0d",
//             $time(),
//             addr_gen_busy,
//             systolic_add_signal,
//             systolic_vertical_bar[0],
//             systolic_horizontal_bar[0]
//         );
//     end

// endmodule
