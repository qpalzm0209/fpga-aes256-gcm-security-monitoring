`timescale 1ns/1ps

module tb_axis_video_frame_width_bridge;
    localparam integer WIDTH = 16;
    localparam integer HEIGHT = 3;
    localparam integer PIXELS = WIDTH * HEIGHT;

    logic clk = 1'b0;
    logic resetn = 1'b0;
    always #5 clk = ~clk;

    logic [15:0] in_data;
    logic [1:0] in_keep, in_strb;
    logic in_user, in_last, in_id, in_dest, in_valid, in_ready;
    logic [127:0] packed_data;
    logic [15:0] packed_keep;
    logic packed_valid, packed_ready, packed_last;
    logic pack_error;
    logic [15:0] out_data;
    logic [1:0] out_keep, out_strb;
    logic out_user, out_last, out_id, out_dest, out_valid, out_ready;
    logic unpack_error;

    integer sent = 0;
    integer garbage_sent = 0;
    integer received = 0;
    integer cycles = 0;

    axis_video16_to_frame128 #(.FRAME_WIDTH(WIDTH), .FRAME_HEIGHT(HEIGHT)) u_pack (
        .aclk(clk), .aresetn(resetn),
        .s_axis_tdata(in_data), .s_axis_tkeep(in_keep), .s_axis_tstrb(in_strb),
        .s_axis_tuser(in_user), .s_axis_tlast(in_last), .s_axis_tid(in_id),
        .s_axis_tdest(in_dest), .s_axis_tvalid(in_valid), .s_axis_tready(in_ready),
        .m_axis_tdata(packed_data), .m_axis_tkeep(packed_keep),
        .m_axis_tvalid(packed_valid), .m_axis_tready(packed_ready),
        .m_axis_tlast(packed_last), .protocol_error(pack_error)
    );

    axis_frame128_to_video16 #(.FRAME_WIDTH(WIDTH), .FRAME_HEIGHT(HEIGHT)) u_unpack (
        .aclk(clk), .aresetn(resetn),
        .s_axis_tdata(packed_data), .s_axis_tkeep(packed_keep),
        .s_axis_tvalid(packed_valid), .s_axis_tready(packed_ready),
        .s_axis_tlast(packed_last),
        .m_axis_tdata(out_data), .m_axis_tkeep(out_keep), .m_axis_tstrb(out_strb),
        .m_axis_tuser(out_user), .m_axis_tlast(out_last), .m_axis_tid(out_id),
        .m_axis_tdest(out_dest), .m_axis_tvalid(out_valid), .m_axis_tready(out_ready),
        .protocol_error(unpack_error)
    );

    always_comb begin
        in_data = garbage_sent < 5 ?
                  (16'hd000 + garbage_sent[15:0]) :
                  (16'h4000 + sent[15:0]);
        in_keep = 2'b11;
        in_strb = 2'b11;
        in_user = garbage_sent >= 5 && (sent % PIXELS) == 0;
        in_last = garbage_sent >= 5 && (sent % WIDTH) == WIDTH - 1;
        in_id = 1'b0;
        in_dest = 1'b0;
        in_valid = resetn && (garbage_sent < 5 || sent < PIXELS * 2) &&
                   ((cycles % 5) != 1);
        out_ready = resetn && ((cycles % 7) != 3) && ((cycles % 11) != 6);
    end

    always_ff @(posedge clk) begin
        cycles <= cycles + 1;
        if (resetn && in_valid && in_ready) begin
            if (garbage_sent < 5)
                garbage_sent <= garbage_sent + 1;
            else
                sent <= sent + 1;
        end
        if (resetn && out_valid && out_ready) begin
            if (out_data !== (16'h4000 + received[15:0]))
                $fatal(1, "data mismatch at %0d: got %h", received, out_data);
            if (out_keep !== 2'b11 || out_strb !== 2'b11)
                $fatal(1, "keep/strb mismatch at %0d", received);
            if (out_user !== ((received % PIXELS) == 0))
                $fatal(1, "TUSER mismatch at %0d", received);
            if (out_last !== ((received % WIDTH) == WIDTH - 1))
                $fatal(1, "TLAST mismatch at %0d", received);
            received <= received + 1;
            if (received == PIXELS * 2 - 1) begin
                if (pack_error || unpack_error)
                    $fatal(1, "unexpected sticky protocol error");
                $display("PASS: SOF resync plus two frames survived width conversion and backpressure");
                $finish;
            end
        end
        if (cycles > 4000)
            $fatal(1, "timeout sent=%0d received=%0d", sent, received);
    end

    initial begin
        repeat (6) @(posedge clk);
        resetn <= 1'b1;
    end
endmodule
