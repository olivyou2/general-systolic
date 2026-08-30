// Registered output-window origin generator for the CNN launcher.
//
// One launch describes OUTPUTS consecutive output pixels in row-major order.
// The first input origin is multiplied once; the remaining origins are walked
// with additions. Registered outputs also isolate configuration-register
// fanout from the per-cycle operand address path.
module window_loop #(
    parameter int OUTPUTS = 8
)(
    input  logic clk,
    input  logic rst_n,
    input  logic fire,
    input  logic [15:0] input_width,
    input  logic [15:0] input_height,
    input  logic [15:0] input_channels,
    input  logic [7:0]  kernel_width,
    input  logic [7:0]  kernel_height,
    input  logic [15:0] stride_x,
    input  logic [15:0] stride_y,
    input  logic [7:0]  pad_left,
    input  logic [7:0]  pad_right,
    input  logic [7:0]  pad_top,
    input  logic [7:0]  pad_bottom,
    input  logic [15:0] output_x,
    input  logic [15:0] output_y,
    input  logic [15:0] output_width,
    output logic busy,
    output logic valid,
    output wire signed [OUTPUTS-1:0][31:0] window_x,
    output wire signed [OUTPUTS-1:0][31:0] window_y,
    output wire signed [OUTPUTS-1:0][47:0] spatial_index,
    output wire        [OUTPUTS-1:0]       output_valid,
    output logic signed [47:0] image_plane
);
    localparam int OUTPUT_INDEX_WIDTH = (OUTPUTS > 1) ? $clog2(OUTPUTS) : 1;

    typedef enum logic [2:0] {
        IDLE, ORIGIN_Y, PLANE, FIRST_INDEX, EMIT, COMPLETE
    } state_t;

    state_t state;
    logic [OUTPUT_INDEX_WIDTH-1:0] output_index;
    logic signed [31:0] origin_x;
    logic signed [31:0] origin_y;
    logic signed [31:0] current_x;
    logic signed [31:0] current_y;
    logic signed [47:0] current_spatial_index;
    logic signed [47:0] input_row_step;
    logic [15:0] current_output_x;
    logic geometry_valid;
    logic emit_output_valid;

    assign busy = (state != IDLE);
    assign emit_output_valid = geometry_valid
        && ((current_x + $signed({1'b0, kernel_width}))
            <= ($signed({1'b0, input_width})
                + $signed({1'b0, pad_right})))
        && ((current_y + $signed({1'b0, kernel_height}))
            <= ($signed({1'b0, input_height})
                + $signed({1'b0, pad_bottom})))
        && (current_output_x < output_width);

    window_generator #(.WINDOWS(OUTPUTS)) descriptor_registers (
        .clk(clk), .rst_n(rst_n), .capture(state == EMIT),
        .window_index(output_index),
        .window_x_in(current_x), .window_y_in(current_y),
        .spatial_index_in(current_spatial_index),
        .output_valid_in(emit_output_valid),
        .window_x(window_x), .window_y(window_y),
        .spatial_index(spatial_index), .output_valid(output_valid)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            valid <= 1'b0;
            output_index <= '0;
            origin_x <= '0;
            origin_y <= '0;
            current_x <= '0;
            current_y <= '0;
            current_spatial_index <= '0;
            input_row_step <= '0;
            current_output_x <= '0;
            geometry_valid <= 1'b0;
            image_plane <= '0;
        end else begin
            valid <= 1'b0;
            case (state)
                IDLE: begin
                    if (fire) begin
                        origin_x <= $signed({1'b0, output_x})
                                    * $signed({1'b0, stride_x})
                                    - $signed({1'b0, pad_left});
                        current_output_x <= output_x;
                        geometry_valid <=
                            (stride_x != 0) && (stride_y != 0)
                            && (input_width != 0) && (input_height != 0)
                            && (input_channels != 0)
                            && (kernel_width != 0) && (kernel_height != 0)
                            && (output_width != 0)
                            && ((input_width + pad_left + pad_right)
                                >= kernel_width)
                            && ((input_height + pad_top + pad_bottom)
                                >= kernel_height);
                        state <= ORIGIN_Y;
                    end
                end

                ORIGIN_Y: begin
                    origin_y <= $signed({1'b0, output_y})
                                * $signed({1'b0, stride_y})
                                - $signed({1'b0, pad_top});
                    state <= PLANE;
                end

                PLANE: begin
                    image_plane <= $signed({1'b0, input_width})
                                   * $signed({1'b0, input_height});
                    input_row_step <= $signed({1'b0, stride_y})
                                      * $signed({1'b0, input_width});
                    state <= FIRST_INDEX;
                end

                FIRST_INDEX: begin
                    current_x <= origin_x;
                    current_y <= origin_y;
                    current_spatial_index <= origin_y
                                             * $signed({1'b0, input_width})
                                             + origin_x;
                    output_index <= '0;
                    state <= EMIT;
                end

                EMIT: begin
                    if (output_index == OUTPUTS-1) begin
                        state <= COMPLETE;
                    end else begin
                        output_index <= output_index + 1'b1;
                        if ((current_output_x + 1'b1) >= output_width) begin
                            current_output_x <= '0;
                            current_x <= -$signed({1'b0, pad_left});
                            current_y <= current_y
                                         + $signed({1'b0, stride_y});
                            current_spatial_index <= current_spatial_index
                                + input_row_step - current_x
                                - $signed({1'b0, pad_left});
                        end else begin
                            current_output_x <= current_output_x + 1'b1;
                            current_x <= current_x
                                         + $signed({1'b0, stride_x});
                            current_spatial_index <= current_spatial_index
                                + $signed({1'b0, stride_x});
                        end
                    end
                end

                COMPLETE: begin
                    valid <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    initial begin
        if (OUTPUTS < 1) $error("window_loop requires at least one output");
    end
endmodule
