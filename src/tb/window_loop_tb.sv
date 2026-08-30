module window_loop_tb;
    localparam int OUTPUTS = 8;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic fire = 1'b0;
    logic busy;
    logic valid;
    wire signed [OUTPUTS-1:0][31:0] window_x;
    wire signed [OUTPUTS-1:0][31:0] window_y;
    wire signed [OUTPUTS-1:0][47:0] spatial_index;
    wire [OUTPUTS-1:0] output_valid;
    logic signed [47:0] image_plane;

    window_loop #(.OUTPUTS(OUTPUTS)) dut (
        .clk(clk), .rst_n(rst_n), .fire(fire),
        .input_width(16'd3), .input_height(16'd3),
        .input_channels(16'd1),
        .kernel_width(8'd2), .kernel_height(8'd2),
        .stride_x(16'd1), .stride_y(16'd1),
        .pad_left(8'd0), .pad_right(8'd0),
        .pad_top(8'd0), .pad_bottom(8'd0),
        .output_x(16'd0), .output_y(16'd0), .output_width(16'd2),
        .busy(busy), .valid(valid),
        .window_x(window_x), .window_y(window_y),
        .spatial_index(spatial_index), .output_valid(output_valid),
        .image_plane(image_plane)
    );

    always #5 clk = ~clk;

    initial begin
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        fire = 1'b1;
        @(negedge clk);
        fire = 1'b0;
        wait (valid);
        #1;
        if (spatial_index[0] != 0 || spatial_index[1] != 1
            || spatial_index[2] != 3 || spatial_index[3] != 4)
            $fatal(1, "row-major spatial walk mismatch");
        if (window_x[2] != 0 || window_y[2] != 1)
            $fatal(1, "window coordinate wrap mismatch");
        if (output_valid != 8'b0000_1111)
            $fatal(1, "window validity mismatch: %b", output_valid);
        if (image_plane != 9)
            $fatal(1, "image plane mismatch");
        $display("[PASS] window loop test");
        $finish;
    end
endmodule
