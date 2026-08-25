`timescale 1ns/1ps

// One 32-bit AXI beat contains Y0,U,Y1,V.  The module accepts a new pair
// while the second pixel of the previous pair is consumed, so steady-state
// output is one RGB pixel per pixel clock.
module axis_yuyv32_to_rgb24 (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn, FREQ_HZ 74250000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *) input aclk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *) input aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *) input [31:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TKEEP" *) input [3:0] s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TUSER" *) input s_axis_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *) input s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *) input s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *) output s_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *) output [23:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TKEEP" *) output [2:0] m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TUSER" *) output m_axis_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *) output m_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *) output m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *) input m_axis_tready
);
    reg [31:0] pair_data;
    reg pair_user, pair_last, pair_valid, second_pixel;
    reg signed [19:0] y_product_reg;
    reg signed [19:0] r_chroma_reg;
    reg signed [19:0] g_u_chroma_reg;
    reg signed [19:0] g_v_chroma_reg;
    reg signed [19:0] b_chroma_reg;
    reg calc_user_reg, calc_last_reg, calc_valid_reg;
    reg signed [21:0] r_scaled_reg;
    reg signed [21:0] g_scaled_reg;
    reg signed [21:0] b_scaled_reg;
    reg sum_user_reg, sum_last_reg, sum_valid_reg;
    reg [23:0] rgb_data_reg;
    reg rgb_user_reg, rgb_last_reg, rgb_valid_reg;

    function [7:0] clamp22;
        input signed [21:0] value;
        begin
            if (value[21])
                clamp22 = 8'd0;
            else if (value > 22'sd255)
                clamp22 = 8'd255;
            else
                clamp22 = value[7:0];
        end
    endfunction

    wire [7:0] current_y = second_pixel ? pair_data[23:16] :
                                             pair_data[7:0];
    wire signed [9:0] current_c = $signed({1'b0, current_y}) - 10'sd16;
    wire signed [9:0] current_d =
        $signed({1'b0, pair_data[15:8]}) - 10'sd128;
    wire signed [9:0] current_e =
        $signed({1'b0, pair_data[31:24]}) - 10'sd128;
    wire signed [9:0] current_c_nonnegative =
        current_c[9] ? 10'sd0 : current_c;

    wire signed [21:0] y_ext = {{2{y_product_reg[19]}}, y_product_reg};
    wire signed [21:0] r_ext = {{2{r_chroma_reg[19]}}, r_chroma_reg};
    wire signed [21:0] gu_ext = {{2{g_u_chroma_reg[19]}}, g_u_chroma_reg};
    wire signed [21:0] gv_ext = {{2{g_v_chroma_reg[19]}}, g_v_chroma_reg};
    wire signed [21:0] b_ext = {{2{b_chroma_reg[19]}}, b_chroma_reg};
    wire signed [21:0] r_scaled = (y_ext + r_ext + 22'sd128) >>> 8;
    wire signed [21:0] g_scaled =
        (y_ext + gu_ext + gv_ext + 22'sd128) >>> 8;
    wire signed [21:0] b_scaled = (y_ext + b_ext + 22'sd128) >>> 8;

    // Three elastic arithmetic stages keep one pixel/clock throughput while
    // splitting multiplier, color-sum, and clamp timing paths.
    wire rgb_ready = !rgb_valid_reg || m_axis_tready;
    wire sum_ready = !sum_valid_reg || rgb_ready;
    wire calc_ready = !calc_valid_reg || sum_ready;
    wire pair_advance = pair_valid && calc_ready;
    assign s_axis_tready = !pair_valid || (second_pixel && calc_ready);
    assign m_axis_tvalid = rgb_valid_reg;
    assign m_axis_tdata = rgb_data_reg;
    assign m_axis_tkeep = 3'b111;
    assign m_axis_tuser = rgb_valid_reg && rgb_user_reg;
    assign m_axis_tlast = rgb_valid_reg && rgb_last_reg;

    always @(posedge aclk) begin
        if (!aresetn) begin
            pair_data <= 32'd0;
            pair_user <= 1'b0;
            pair_last <= 1'b0;
            pair_valid <= 1'b0;
            second_pixel <= 1'b0;
            y_product_reg <= 20'sd0;
            r_chroma_reg <= 20'sd0;
            g_u_chroma_reg <= 20'sd0;
            g_v_chroma_reg <= 20'sd0;
            b_chroma_reg <= 20'sd0;
            calc_user_reg <= 1'b0;
            calc_last_reg <= 1'b0;
            calc_valid_reg <= 1'b0;
            r_scaled_reg <= 22'sd0;
            g_scaled_reg <= 22'sd0;
            b_scaled_reg <= 22'sd0;
            sum_user_reg <= 1'b0;
            sum_last_reg <= 1'b0;
            sum_valid_reg <= 1'b0;
            rgb_data_reg <= 24'd0;
            rgb_user_reg <= 1'b0;
            rgb_last_reg <= 1'b0;
            rgb_valid_reg <= 1'b0;
        end else begin
            if (rgb_ready) begin
                if (sum_valid_reg) begin
                    // Digilent rgb2dvi uses vid_pData[23:16]=R,
                    // vid_pData[7:0]=G and vid_pData[15:8]=B.
                    rgb_data_reg <= {
                        clamp22(r_scaled_reg), clamp22(b_scaled_reg),
                        clamp22(g_scaled_reg)
                    };
                    rgb_user_reg <= sum_user_reg;
                    rgb_last_reg <= sum_last_reg;
                    rgb_valid_reg <= 1'b1;
                end else begin
                    rgb_valid_reg <= 1'b0;
                    rgb_user_reg <= 1'b0;
                    rgb_last_reg <= 1'b0;
                end
            end
            if (sum_ready) begin
                if (calc_valid_reg) begin
                    r_scaled_reg <= r_scaled;
                    g_scaled_reg <= g_scaled;
                    b_scaled_reg <= b_scaled;
                    sum_user_reg <= calc_user_reg;
                    sum_last_reg <= calc_last_reg;
                    sum_valid_reg <= 1'b1;
                end else begin
                    sum_valid_reg <= 1'b0;
                    sum_user_reg <= 1'b0;
                    sum_last_reg <= 1'b0;
                end
            end
            if (calc_ready) begin
                if (pair_valid) begin
                    y_product_reg <=
                        $signed(current_c_nonnegative) * 11'sd298;
                    r_chroma_reg <= $signed(current_e) * 11'sd409;
                    g_u_chroma_reg <= $signed(current_d) * -11'sd100;
                    g_v_chroma_reg <= $signed(current_e) * -11'sd208;
                    b_chroma_reg <= $signed(current_d) * 11'sd516;
                    calc_user_reg <= !second_pixel && pair_user;
                    calc_last_reg <= second_pixel && pair_last;
                    calc_valid_reg <= 1'b1;
                end else begin
                    calc_valid_reg <= 1'b0;
                    calc_user_reg <= 1'b0;
                    calc_last_reg <= 1'b0;
                end
            end
            if (pair_advance) begin
                if (!second_pixel)
                    second_pixel <= 1'b1;
                else begin
                    second_pixel <= 1'b0;
                    pair_valid <= 1'b0;
                end
            end
            if (s_axis_tvalid && s_axis_tready) begin
                pair_data <= s_axis_tdata;
                pair_user <= s_axis_tuser;
                pair_last <= s_axis_tlast;
                pair_valid <= 1'b1;
                second_pixel <= 1'b0;
            end
        end
    end

    wire unused = &{1'b0, s_axis_tkeep};
endmodule
