/**

    외부 BRAM은 Row, Column 별로 항상 N바이트 이상 제공할 수 있어야 함

    예시에서는 systolic 이 8*8 이기 때문에, word 가 8바이트인 경우 가로로 1개, 세로로 8개 있어야 함
        계산식)
        systolic data unit bits = U
        systolic size (width=height) = S
        data width = U*S = W
        bram array width = W / bram_data_width
        bram array height = S

    array 를 통신할 때 표준적으로 row-sequential 하게 전송해야 함

**/


module systolic_launcher#(
    parameter A_DATAWIDTH=64,
    parameter A_ADDRWIDTH=9,
    parameter A_BANKS=8,
    
    parameter B_DATAWIDTH=64,
    parameter B_ADDRWIDTH=9,
    parameter B_BANKS=8,

    parameter SYSTOLIC_UNITWIDTH=8,
    parameter SYSTOLIC_WIDTH=8,
    parameter SYSTOLIC_HEIGHT=8
)(
    input logic clk,
    input logic rst_n,

    input logic [A_ADDRWIDTH-1: 0] a_mat_base_offset,
    input logic [B_ADDRWIDTH-1: 0] b_mat_base_offset,

    // Each port architecture bases on the assumption that response data always 1 clock later
    output logic[A_ADDRWIDTH-1: 0] a_addr[A_BANKS],
    input logic[A_DATAWIDTH-1: 0] a_data[A_BANKS],

    output logic[B_ADDRWIDTH-1: 0] b_addr[B_BANKS],
    input logic[B_DATAWIDTH-1: 0] b_data[B_BANKS],

    // Addr Gen 제어부
    input logic fire,
    output logic busy,

    // Systolic 제어부
    output logic [SYSTOLIC_UNITWIDTH-1:0] systolic_vertical_bar[SYSTOLIC_HEIGHT],
    output logic [SYSTOLIC_UNITWIDTH-1:0] systolic_horizontal_bar[SYSTOLIC_WIDTH],

    output logic systolic_add_signal,
    output logic systolic_flow_v_signal,
    output logic systolic_flow_h_signal,
    output logic systolic_broad_v_signal,
    output logic systolic_broad_h_signal
);
    assign systolic_broad_v_signal = 1;
    assign systolic_broad_h_signal = 1;

    assign busy = fsm_status != 0;
    assign systolic_flow_v_signal = busy;
    assign systolic_flow_h_signal = busy;

    logic [3:0] fsm_status;
    logic [$clog2(A_BANKS)-1: 0] a_col_sel;
    logic [$clog2(B_BANKS)-1: 0] b_bank_sel;
    logic [7:0] row_counter;
    
    genvar systolic_x;
    genvar systolic_y;

    generate
        for (systolic_y=0; systolic_y<SYSTOLIC_HEIGHT; systolic_y++) begin
            assign systolic_vertical_bar[systolic_y] =
                a_data[systolic_y][a_col_sel*SYSTOLIC_UNITWIDTH +: SYSTOLIC_UNITWIDTH];
        end   

        for (systolic_x=0; systolic_x<SYSTOLIC_WIDTH; systolic_x++) begin
            assign systolic_horizontal_bar[systolic_x] =
                b_data[b_bank_sel][systolic_x*SYSTOLIC_UNITWIDTH +: SYSTOLIC_UNITWIDTH];
        end    
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_status      <= 0;
            a_col_sel       <= 0;
            b_bank_sel      <= 0;
            row_counter     <= 0;
            systolic_add_signal <= 0;
        end else begin
            case (fsm_status) 
                // IDLE stage
                0: begin
                    if (fire) begin
                        fsm_status <= 1;

                        for (int i=0; i<8; i++) begin
                            a_addr[i] <= a_mat_base_offset;
                            b_addr[i] <= b_mat_base_offset;
                        end
                        row_counter <= 0;

                        a_col_sel <= 0;
                        b_bank_sel <= 0;
                    end
                end

                // BRAM pipe stage
                1: begin
                    // wait for data arrival
                    fsm_status <= 2;
                end

                2: begin
                    systolic_add_signal <= 1;

                    a_col_sel   <= a_col_sel + 1;
                    b_bank_sel  <= b_bank_sel + 1;
                    row_counter <= row_counter + 1;

                    if (row_counter == 7) begin
                        fsm_status <= 3;
                    end
                end

                3: begin
                    systolic_add_signal <= 0;
                    fsm_status <= 0;
                end

                default: begin end
            endcase
        end
    end

endmodule;
