`timescale 1ns/1ps

import gcm_protocol_pkg::*;

// Verifies that RX engine_busy spans the complete 1280-record DMA frame and
// remains asserted until the authenticated/plaintext final payload drains.
module tb_rx_frame_busy_boundary;
  localparam int PACKETS = 1280;
  localparam int RECORD_BEATS = 92;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  logic [127:0] s_data = '0;
  logic [15:0] s_keep = 16'hffff;
  logic s_valid = 1'b0;
  wire s_ready;
  logic s_last = 1'b0;
  wire [127:0] m_data;
  wire [15:0] m_keep;
  wire m_valid;
  logic m_ready = 1'b1;
  wire m_user;
  wire m_last;
  wire key_ready;
  wire busy;
  wire auth_ok;
  wire auth_fail;
  wire bypass;
  wire frame_done;
  wire frame_ready;
  wire frame_fail;
  wire protocol_error;

  int output_blocks = 0;
  int frame_done_count = 0;
  bit enforce_busy = 1'b0;

  always #3.333 clk = ~clk;

  video_aes_gcm_rx_top dut (
      .aclk(clk), .aresetn(resetn), .sw3_decrypt(1'b0),
      .session_id(32'h26080501), .session_key(256'd0),
      .session_key_valid(1'b0), .key_commit(1'b0), .key_clear(1'b0),
      .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
      .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
      .s_axis_tlast(s_last), .m_axis_tdata(m_data),
      .m_axis_tkeep(m_keep), .m_axis_tvalid(m_valid),
      .m_axis_tready(m_ready), .m_axis_tuser(m_user),
      .m_axis_tlast(m_last), .key_ready(key_ready), .busy(busy),
      .auth_ok_pulse(auth_ok), .auth_fail_pulse(auth_fail),
      .bypass_pulse(bypass), .frame_done_pulse(frame_done),
      .frame_ready_pulse(frame_ready), .frame_fail(frame_fail),
      .protocol_error(protocol_error)
  );

  always @(posedge clk) begin
    if (resetn && enforce_busy && !busy)
      $fatal(1, "RX busy dropped inside a 1280-packet frame");
    if (resetn && m_valid && m_ready)
      output_blocks <= output_blocks + 1;
    if (resetn && frame_done)
      frame_done_count <= frame_done_count + 1;
  end

  task automatic send_beat(input logic [127:0] value,
                           input bit last_value);
    begin
      @(negedge clk);
      s_data = value;
      s_last = last_value;
      s_valid = 1'b1;
      do @(posedge clk); while (!s_ready);
      @(negedge clk);
      s_valid = 1'b0;
      s_last = 1'b0;
    end
  endtask

  task automatic send_record(input int packet);
    logic [15:0] flags;
    logic [127:0] word_value;
    begin
      flags = make_flags(1'b0, packet == 0, packet == PACKETS-1);
      send_beat(gcm_to_axis(make_aad(GCM_MAGIC, 32'h26080501,
                                    32'h00000033, packet[15:0], flags)),
                1'b0);
      for (int payload = 0; payload < 90; payload++) begin
        for (int lane = 0; lane < 16; lane++)
          word_value[lane*8 +: 8] =
              (packet * 13 + payload * 5 + lane) & 8'hff;
        send_beat(word_value, 1'b0);
      end
      send_beat(128'd0, packet == PACKETS-1);
    end
  endtask

  initial begin
    repeat (8) @(posedge clk);
    resetn = 1'b1;
    repeat (4) @(posedge clk);

    for (int packet = 0; packet < PACKETS; packet++) begin
      send_record(packet);
      if (packet == 0)
        enforce_busy = 1'b1;
    end

    // Final TAG has committed, but hold the payload bank occupied.  A packet-
    // level busy implementation incorrectly drops during this interval.
    m_ready = 1'b0;
    repeat (32) @(posedge clk);
    if (!busy) $fatal(1, "RX busy dropped before final payload drain");

    @(negedge clk);
    m_ready = 1'b1;
    wait (output_blocks == PACKETS * 90);
    enforce_busy = 1'b0;
    wait (!busy);
    repeat (2) @(posedge clk);

    if (protocol_error || frame_fail || frame_done_count != 1 ||
        output_blocks != PACKETS * 90)
      $fatal(1, "RX frame-boundary accounting failure");
    $display("PASS: RX busy stayed high for all 1280 packets and final payload drain");
    $finish;
  end

  initial begin
    #10000000;
    $fatal(1, "RX frame busy simulation timeout");
  end

  wire unused = &{1'b0, m_data, m_keep, m_user, m_last, key_ready,
                   auth_ok, auth_fail, bypass, frame_ready};
endmodule
