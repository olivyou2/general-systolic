module systolic_tb();

    localparam SYSTOLIC_WIDTH = 8;
    localparam SYSTOLIC_HEIGHT = 8;
    localparam RESULT_SATURATION = 0;

    logic clk=0;
    logic rst_n=0;

    logic [7:0] vertical_bar    [SYSTOLIC_HEIGHT];
    logic [7:0] horizontal_bar  [SYSTOLIC_WIDTH];

    logic [7:0] drain_bar       [SYSTOLIC_WIDTH];

    logic sig_add       = 0;
    logic sig_flow_v    = 0;
    logic sig_flow_h    = 0;
    logic sig_drain     = 0;
    logic sig_broad_h   = 0;

    systolic#(
        .WIDTH(SYSTOLIC_WIDTH),
        .HEIGHT(SYSTOLIC_HEIGHT)
    )dut(
        .clk(clk),
        .rst_n(rst_n),

        .vertical_bar(vertical_bar),
        .horizontal_bar(horizontal_bar),
        .horizontal_drain_bar(drain_bar),
        .result_saturation(RESULT_SATURATION),

        .add(sig_add),
        .flow_v(sig_flow_v),
        .flow_h(sig_flow_h),
        .drain(sig_drain),
        .broad_h(sig_broad_h)
    );

    task automatic tick();
        clk = 1;
        #1;
        clk = 0;
        #1;
    endtask

    task automatic reset_chip();
        rst_n = 0;
        #10;
        rst_n = 1;
        #10;
    endtask

    task automatic drain_data(input integer predrain, input integer col, output logic [7:0] out);
        for (integer i=0; i<predrain+1; i++) begin
            sig_drain = 1;
            tick();
        end

        sig_drain = 0;
        out = drain_bar[col];
    endtask

    task automatic inner_product_launch(
        input logic [7:0] A [4],
        input logic [7:0] B [4]
    );
        // Initial data settings
        
        // [Experimental: broad_h activate]
        sig_broad_h = 1;

        // Flow are enable always during inner product
        sig_flow_v = 1;
        sig_flow_h = 1;

        vertical_bar[0] = A[0];
        horizontal_bar[0] = B[0];

        tick();

        for (integer i=1; i<4; i++) begin
            vertical_bar[0] = A[i];
            horizontal_bar[0] = B[i];

            sig_add = 1;
            tick();
        end

        sig_flow_v = 0;
        sig_flow_h = 0;
        sig_broad_h = 0;

        // Last element add signal
        tick();

        sig_add = 0;
    endtask

    task automatic print_systolic(input int mode);
        if (mode == 0) begin
            $display("------ PRINT RESULT ARRAY ------");
        end else if (mode == 1) begin
            $display("------ PRINT HORIZONTAL ARRAY ------");
        end else if (mode == 2) begin
            $display("------ PRINT VERTICAL ARRAY ------");
        end
        for (int i=0; i<SYSTOLIC_HEIGHT+1; i++) begin
            for (int j=0; j<SYSTOLIC_WIDTH+1; j++) begin
                if (i==0 && j==0) begin
                    $write("  ");
                end else if (i == 0) begin
                    $write("%4d", j-1);
                end else if (j == 0) begin
                    $write("%4d", i-1);
                end else begin
                    if (mode == 0) begin
                        $write("%4d", dut.result[j-1][i-1]);
                    end else if (mode == 1) begin
                        $write("%4d", dut.horizontal_flow[j-1][i-1]);
                    end else if (mode == 2) begin
                        $write("%4d", dut.vertical_flow[j-1][i-1]);
                    end
                end
            end

            $display("");
        end
    endtask

    logic [7:0] A[4];
    logic [7:0] B[4];

    logic [7:0] DRAIN_OUT;

    initial begin
        reset_chip();
        
        A[0] = 1;
        A[1] = 2;
        A[2] = 3;
        A[3] = 4;

        B[0] = 10;
        B[1] = 11;
        B[2] = 12;
        B[3] = 13;

        inner_product_launch(A, B);

        // tick();

        drain_data(7, 0, DRAIN_OUT);
        $display("Drain out=%d", DRAIN_OUT);
    end

    always @(posedge clk) begin
        $display("[CLK] tick %4d", $time());
        print_systolic(0);
    end

endmodule;
