
/**

    Controller
    
    1. Set configurations such as DMA issue, MESH configurations, Data path and etc.
    2. Issue DMA Command
    3. Fire Specific Node


**/

module controller#(
    parameter MEMORY_DEPTH = 512
)(
    input logic clk,
    input logic rst_n,

    input logic en,
    output logic [3:0] fsm_status,

    input logic write_valid,
    input logic [63:0] write_data,
    input logic [63:0] write_addr,

    output logic mesh_valid,
    output logic [31:0] mesh_data,
    output logic [31:0] mesh_addr,

    output logic fire,
    input logic layer_fin

);
    localparam MEMROY_ADDR_LEN = $clog2(MEMORY_DEPTH);

    logic [63:0] memory[MEMORY_DEPTH];
    logic [63:0] memory_out;
    
    logic [MEMROY_ADDR_LEN-1: 0] memory_addr;

    // assign memory_out = memory[memory_addr];    
    
    // Debug: BRAM simulation
    always @(posedge clk) begin
        memory_out <= memory[memory_addr];
    end

    // WRITE MEMORY
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset Controllers
        end else begin
            if (write_valid) begin
                $display("controller: data writed %0h @ %0h", write_data, write_addr);
                memory[write_addr[MEMROY_ADDR_LEN-1: 0]] <= write_data;
            end
        end
    end

    // FSM
    localparam FSM_IDLE     = 4'h0;
    localparam FSM_FETCH    = 4'h1;
    localparam FSM_ISSUE    = 4'h2;
    localparam FSM_WAIT     = 4'h3;

    logic [9:0]     configuration_counter;
    logic [31:0]    configuration_header;

    logic [9:0]     configuration_num;
    assign configuration_num = configuration_header[9:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_status <= 0;

            memory_addr <= 0;

            configuration_counter <= 0;
            configuration_header <= 0;
        end else begin
            mesh_valid <= 0;
            fire <= 0;

            case (fsm_status) 
                // IDLE
                FSM_IDLE: begin
                    memory_addr <= 0;
                    if (en) fsm_status <= FSM_FETCH; 
                end

                // FETCH
                FSM_FETCH: begin
                    fsm_status <= FSM_ISSUE;
                end
                
                // ISSUE
                FSM_ISSUE: begin
                    if (configuration_counter == 0) begin
                        configuration_counter <= 1;
                        configuration_header <= memory_out[31:0];
                        memory_addr <= memory_addr + 1;
                        fsm_status <= FSM_FETCH;
                    end else begin
                        if (configuration_num == 0) begin
                            fsm_status <= FSM_IDLE;
                        end else if (configuration_counter == configuration_num) begin
                            configuration_counter <= 0;
                            fsm_status <= FSM_WAIT;
                            
                            fire <= 1;
                        end else begin
                            mesh_valid <= 1;
                            mesh_addr <= memory_out[31:0];
                            mesh_data <= memory_out[63:32];

                            configuration_counter <= configuration_counter + 1;
                            memory_addr <= memory_addr + 1;
                            fsm_status <= FSM_FETCH;
                        end
                    end
                end

                // WAIT FOR LAYER FINISH
                FSM_WAIT: begin
                    if (layer_fin) begin
                        fsm_status <= FSM_ISSUE;
                    end
                end

                default: begin
                end
                
            endcase
        end
    end

endmodule