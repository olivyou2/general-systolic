/**

    Systolic Launcher treat sequential row-column generation of systolic array
    1. GEMV, GEMM
        
    2. CNN


**/


module systolic_launcher#(
    parameter A_ADDR_WIDTH = 10,
    parameter B_ADDR_WIDTH = 10,

    parameter SYSTOLIC_WIDTH = 16,
    parameter SYSTOLIC_HEIGHT = 16
)(
    input logic clk,
    input logic rst,

    // A - column based bank
    output logic [A_ADDR_WIDTH-1: 0] a_addr,
    input logic [SYSTOLIC_WIDTH*8-1: 0] a_data,
    input logic a_valid,
    output logic a_ready,

    // B - column based bank
    output logic [B_ADDR_WIDTH-1: 0] b_addr,
    input logic [SYSTOLIC_HEIGHT*8-1: 0] b_data,
    input logic b_valid,
    output logic b_ready,

    output logic [7:0] systolic_horizontal_bar[SYSTOLIC_WIDTH],
    output logic [7:0] systoli_vertical_bar[SYSTOLIC_HEIGHT],

    output logic add,
    output logic flow_v,
    output logic flow_h,
    output logic broad_h,

    input logic fire,
    output logic busy,

    // Mode select
    input logic fire_mode,

    // GEMM mode
    input logic [9:0] gemm_cnt
    input logic [A_ADDR_WIDTH-1: 0] gemm_a_base;
    input logic [B_ADDR_WIDTH-1: 0] gemm_b_base;
);

    // <-- Fire Parameters -->
    logic [9:0] launcher_gemm_cnt;
    logic [A_ADDR_WIDTH-1:0] launcher_gemm_a_base;
    logic [A_ADDR_WIDTH-1:0] launcher_gemm_a_addr;
    logic [B_ADDR_WIDTH-1:0] launcher_gemm_b_base;
    logic [B_ADDR_WIDTH-1:0] launcher_gemm_b_addr;

    // <-- Internal Status -->
    logic systolic_stall;

    // <-- FSM Management -->
    logic [3:0] launcher_fsm;
    localparam FSM_IDLE = 0;
    localparam FSM_GEMM_FIRE = 1;

    localparam FSM_CNN_INIT = 8;

    // <-- Assigns --> 
    assign busy = launcher_fsm != FSM_IDLE;

    assign a_addr = launcher_gemm_a_addr;
    assign b_addr = launcher_gemm_b_addr;

    assign systolic_stall = !a_valid || !b_valid;

    assign a_ready = a_valid && b_valid;
    assign b_ready = a_valid && b_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            launcher_fsm <= 0;

            launcher_gemm_cnt <= 0;
        end else begin
            case launcher_fsm
                FSM_IDLE: begin
                    if (fire) begin
                        if (fire_mode == 0) begin
                            launcher_fsm <= FSM_GEMM_FIRE;

                            launcher_gemm_a_addr <= gemm_a_base;
                            launcher_gemm_a_base <= gemm_a_base;
                            launcher_gemm_b_addr <= gemm_b_base;
                            launcher_gemm_b_base <= gemm_b_base;
                        end else begin
                            launcher_fsm <= FSM_CNN_INIT;
                        end
                    end
                end

                FSM_GEMM_FIRE: begin
                    // wait for data arrival

                    if (a_valid && b_valid)
                end

                FSM_CNN_INIT: begin
                end
            endcase
        end
    end

endmodule;