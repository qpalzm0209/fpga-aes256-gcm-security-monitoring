`timescale 1ns/1ps

// 1280x720p60 CTA timing at a 74.25 MHz pixel clock, one pixel per clock.
module video_timing_720p (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_RESET aresetn, FREQ_HZ 74250000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *) input aclk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *) input aresetn,
    input clken,
    output active_video,
    output hblank,
    output hsync,
    output vblank,
    output vsync,
    output field_id,
    output reg frame_toggle
);
    reg [10:0] h_count;
    reg [9:0] v_count;

    always @(posedge aclk) begin
        if (!aresetn) begin
            h_count <= 11'd0;
            v_count <= 10'd0;
            frame_toggle <= 1'b0;
        end else if (clken && h_count == 11'd1649) begin
            h_count <= 11'd0;
            if (v_count == 10'd749) begin
                v_count <= 10'd0;
                frame_toggle <= ~frame_toggle;
            end else begin
                v_count <= v_count + 10'd1;
            end
        end else if (clken) begin
            h_count <= h_count + 11'd1;
        end
    end

    assign active_video = (h_count < 11'd1280) && (v_count < 10'd720);
    assign hblank = (h_count >= 11'd1280);
    assign vblank = (v_count >= 10'd720);
    assign hsync = (h_count >= 11'd1390) && (h_count < 11'd1430);
    assign vsync = (v_count >= 10'd724) && (v_count < 10'd729);
    assign field_id = 1'b0;
endmodule
