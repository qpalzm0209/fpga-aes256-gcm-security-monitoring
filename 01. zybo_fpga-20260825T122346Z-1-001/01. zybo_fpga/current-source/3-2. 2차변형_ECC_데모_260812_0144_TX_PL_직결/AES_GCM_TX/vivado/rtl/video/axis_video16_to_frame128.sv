`timescale 1ns/1ps

// Packs the native 16-bit YUV422 camera stream into byte-transparent
// 128-bit frame beats for the AES-GCM engine.  Camera TLAST is end-of-line;
// the generated TLAST is end-of-frame, as required by the crypto slot.
module axis_video16_to_frame128 #(
    parameter integer FRAME_WIDTH  = 1280,
    parameter integer FRAME_HEIGHT = 720
) (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn, FREQ_HZ 150000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *) input  logic         aclk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *) input  logic         aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)  input  logic [15:0]  s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TKEEP" *)  input  logic [1:0]   s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TSTRB" *)  input  logic [1:0]   s_axis_tstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TUSER" *)  input  logic         s_axis_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)  input  logic         s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TID" *)    input  logic         s_axis_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDEST" *)  input  logic         s_axis_tdest,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *) input  logic         s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *) output logic         s_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)  output logic [127:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TKEEP" *)  output logic [15:0]  m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *) output logic         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *) input  logic         m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)  output logic         m_axis_tlast,

    output logic protocol_error
);
    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer FRAME_COUNT_W = (FRAME_PIXELS <= 2) ? 1 : $clog2(FRAME_PIXELS);
    localparam integer LINE_COUNT_W = (FRAME_WIDTH <= 2) ? 1 : $clog2(FRAME_WIDTH);

    logic [127:0] pack_data;
    logic [2:0] lane_count;
    logic [FRAME_COUNT_W-1:0] frame_pixel_count;
    logic [LINE_COUNT_W-1:0] line_pixel_count;
    logic output_valid;
    logic output_last;
    logic [127:0] output_data;
    logic frame_synced;

    wire output_fire = output_valid && m_axis_tready;
    wire input_fire = s_axis_tvalid && s_axis_tready;
    wire expected_sof = (frame_pixel_count == 0);
    wire expected_eol = (line_pixel_count == FRAME_WIDTH - 1);
    wire expected_eof = (frame_pixel_count == FRAME_PIXELS - 1);

    // A single registered 128-bit beat provides full AXIS backpressure.  The
    // next camera pixel can be accepted on the same cycle the old beat leaves.
    assign s_axis_tready = aresetn &&
                           (!frame_synced || !output_valid || m_axis_tready);
    assign m_axis_tdata = output_data;
    assign m_axis_tkeep = 16'hffff;
    assign m_axis_tvalid = output_valid;
    assign m_axis_tlast = output_last;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            pack_data <= 128'd0;
            lane_count <= 3'd0;
            frame_pixel_count <= '0;
            line_pixel_count <= '0;
            output_valid <= 1'b0;
            output_last <= 1'b0;
            output_data <= 128'd0;
            frame_synced <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            if (output_fire)
                output_valid <= 1'b0;

            if (input_fire) begin
                // After a runtime pipeline reset, consume and discard any
                // residual partial line until the camera's real SOF arrives.
                if (!frame_synced && !s_axis_tuser) begin
                    lane_count <= 3'd0;
                    frame_pixel_count <= '0;
                    line_pixel_count <= '0;
                end else begin
                    frame_synced <= 1'b1;
                    if (s_axis_tkeep != 2'b11 || s_axis_tstrb != 2'b11 ||
                        s_axis_tuser != expected_sof ||
                        s_axis_tlast != expected_eol)
                        protocol_error <= 1'b1;

                    if (lane_count == 3'd7) begin
                        output_data <= {s_axis_tdata, pack_data[111:0]};
                        output_last <= expected_eof;
                        output_valid <= 1'b1;
                        lane_count <= 3'd0;
                    end else begin
                        pack_data[lane_count * 16 +: 16] <= s_axis_tdata;
                        lane_count <= lane_count + 3'd1;
                    end

                    if (expected_eol)
                        line_pixel_count <= '0;
                    else
                        line_pixel_count <= line_pixel_count + 1'b1;

                    if (expected_eof)
                        frame_pixel_count <= '0;
                    else
                        frame_pixel_count <= frame_pixel_count + 1'b1;
                end
            end
        end
    end

    wire unused = &{1'b0, s_axis_tid, s_axis_tdest};
endmodule
