`timescale 1ns/1ps

// Restores a 128-bit AES-GCM frame stream to the native 16-bit video AXIS.
// TUSER is regenerated at frame start and TLAST at every camera line so the
// existing Frame Buffer Write/V4L2 pipeline can remain unchanged.
module axis_frame128_to_video16 #(
    parameter integer FRAME_WIDTH  = 1280,
    parameter integer FRAME_HEIGHT = 720
) (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn, FREQ_HZ 150000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *) input  logic         aclk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *) input  logic         aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)  input  logic [127:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TKEEP" *)  input  logic [15:0]  s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *) input  logic         s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *) output logic         s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)  input  logic         s_axis_tlast,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)  output logic [15:0]  m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TKEEP" *)  output logic [1:0]   m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TSTRB" *)  output logic [1:0]   m_axis_tstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TUSER" *)  output logic         m_axis_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)  output logic         m_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TID" *)    output logic         m_axis_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDEST" *)  output logic         m_axis_tdest,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *) output logic         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *) input  logic         m_axis_tready,

    output logic protocol_error
);
    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer FRAME_BLOCKS = FRAME_PIXELS / 8;
    localparam integer FRAME_COUNT_W = (FRAME_PIXELS <= 2) ? 1 : $clog2(FRAME_PIXELS);
    localparam integer LINE_COUNT_W = (FRAME_WIDTH <= 2) ? 1 : $clog2(FRAME_WIDTH);
    localparam integer BLOCK_COUNT_W = (FRAME_BLOCKS <= 2) ? 1 : $clog2(FRAME_BLOCKS);

    logic [127:0] word_data;
    logic word_valid;
    logic [2:0] lane_count;
    logic [FRAME_COUNT_W-1:0] frame_pixel_count;
    logic [LINE_COUNT_W-1:0] line_pixel_count;
    logic [BLOCK_COUNT_W-1:0] input_block_count;

    wire output_fire = word_valid && m_axis_tready;
    wire input_fire = s_axis_tvalid && s_axis_tready;
    wire expected_input_last = (input_block_count == FRAME_BLOCKS - 1);
    wire final_lane = (lane_count == 3'd7);

    // Accept the following word without a bubble while lane seven is consumed.
    assign s_axis_tready = aresetn && (!word_valid || (m_axis_tready && final_lane));
    assign m_axis_tdata = word_data[lane_count * 16 +: 16];
    assign m_axis_tkeep = 2'b11;
    assign m_axis_tstrb = 2'b11;
    assign m_axis_tuser = word_valid && (frame_pixel_count == 0);
    assign m_axis_tlast = word_valid && (line_pixel_count == FRAME_WIDTH - 1);
    assign m_axis_tid = 1'b0;
    assign m_axis_tdest = 1'b0;
    assign m_axis_tvalid = word_valid;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            word_data <= 128'd0;
            word_valid <= 1'b0;
            lane_count <= 3'd0;
            frame_pixel_count <= '0;
            line_pixel_count <= '0;
            input_block_count <= '0;
            protocol_error <= 1'b0;
        end else begin
            if (output_fire) begin
                if (final_lane) begin
                    word_valid <= 1'b0;
                    lane_count <= 3'd0;
                end else begin
                    lane_count <= lane_count + 3'd1;
                end

                if (line_pixel_count == FRAME_WIDTH - 1)
                    line_pixel_count <= '0;
                else
                    line_pixel_count <= line_pixel_count + 1'b1;

                if (frame_pixel_count == FRAME_PIXELS - 1)
                    frame_pixel_count <= '0;
                else
                    frame_pixel_count <= frame_pixel_count + 1'b1;
            end

            if (input_fire) begin
                word_data <= s_axis_tdata;
                word_valid <= 1'b1;
                lane_count <= 3'd0;
                if (s_axis_tkeep != 16'hffff ||
                    s_axis_tlast != expected_input_last)
                    protocol_error <= 1'b1;
                if (expected_input_last)
                    input_block_count <= '0;
                else
                    input_block_count <= input_block_count + 1'b1;
            end
        end
    end

    initial begin
        if ((FRAME_PIXELS % 8) != 0)
            $error("FRAME_WIDTH*FRAME_HEIGHT must be divisible by eight pixels");
    end
endmodule
