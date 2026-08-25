`timescale 1ns/1ps

// Runtime diagnostics for the HDMI pixel domain. Sticky FIFO flags remain
// visible to software even when the live pulse is shorter than an AXI read.
module hdmi_status_pack (
    input aclk,
    input aresetn,
    input video_clk_locked,
    input vid_locked,
    input underflow,
    input overflow,
    input vtg_ce,
    input active_video,
    input frame_toggle,
    output [31:0] status
);
    reg underflow_sticky;
    reg overflow_sticky;
    reg previous_frame_toggle;
    reg [15:0] frame_count;

    always @(posedge aclk) begin
        if (!aresetn) begin
            underflow_sticky <= 1'b0;
            overflow_sticky <= 1'b0;
            previous_frame_toggle <= 1'b0;
            frame_count <= 16'd0;
        end else begin
            if (underflow)
                underflow_sticky <= 1'b1;
            if (overflow)
                overflow_sticky <= 1'b1;
            if (frame_toggle != previous_frame_toggle) begin
                previous_frame_toggle <= frame_toggle;
                frame_count <= frame_count + 16'd1;
            end
        end
    end

    assign status = {
        frame_count,
        7'd0,
        frame_toggle,
        active_video,
        vtg_ce,
        overflow_sticky,
        underflow_sticky,
        overflow,
        underflow,
        vid_locked,
        video_clk_locked
    };
endmodule
