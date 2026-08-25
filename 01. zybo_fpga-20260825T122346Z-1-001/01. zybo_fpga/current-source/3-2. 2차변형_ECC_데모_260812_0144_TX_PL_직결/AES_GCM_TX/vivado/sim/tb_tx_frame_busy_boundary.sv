`timescale 1ns/1ps

// Verifies that engine_busy is a complete-frame transaction boundary.  The
// plaintext path keeps this regression fast while exercising the same packet,
// payload-output and metadata-drain control used by encrypted frames.
module tb_tx_frame_busy_boundary;
  localparam int PACKETS = 1280;
  localparam int BLOCKS_PER_PACKET = 90;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  logic [127:0] s_data = '0;
  logic [15:0] s_keep = 16'hffff;
  logic s_valid = 1'b0;
  wire s_ready;
  logic s_user = 1'b0;
  logic s_last = 1'b0;
  wire [127:0] m_data;
  wire [15:0] m_keep;
  wire m_valid;
  logic m_ready = 1'b1;
  wire m_user;
  wire m_last;
  wire [127:0] meta_data;
  wire [15:0] meta_keep;
  wire meta_valid;
  logic meta_ready = 1'b1;
  wire meta_last;
  wire [31:0] frame_id;
  wire [15:0] packet_index;
  wire [31:0] debug_status;
  wire key_ready;
  wire busy;
  wire protocol_error;

  int output_blocks = 0;
  int metadata_beats = 0;
  bit enforce_busy = 1'b0;

  always #3.333 clk = ~clk;

  video_aes_gcm_tx_top dut (
      .aclk(clk), .aresetn(resetn), .sw3_encrypt(1'b0),
      .session_id(32'h26080501), .session_key(256'd0),
      .session_key_valid(1'b0), .key_commit(1'b0), .key_clear(1'b0),
      .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
      .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
      .s_axis_tuser(s_user), .s_axis_tlast(s_last),
      .m_axis_tdata(m_data), .m_axis_tkeep(m_keep),
      .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
      .m_axis_tuser(m_user), .m_axis_tlast(m_last),
      .m_meta_tdata(meta_data), .m_meta_tkeep(meta_keep),
      .m_meta_tvalid(meta_valid), .m_meta_tready(meta_ready),
      .m_meta_tlast(meta_last), .status_frame_id(frame_id),
      .status_packet_index(packet_index), .debug_status(debug_status),
      .key_ready(key_ready), .busy(busy),
      .protocol_error(protocol_error)
  );

  always @(posedge clk) begin
    if (resetn && enforce_busy && !busy)
      $fatal(1, "TX busy dropped inside a 1280-packet frame");
    if (resetn && m_valid && m_ready)
      output_blocks <= output_blocks + 1;
    if (resetn && meta_valid && meta_ready)
      metadata_beats <= metadata_beats + 1;
  end

  task automatic send_block(input int packet, input int block_index);
    begin
      @(negedge clk);
      for (int lane = 0; lane < 16; lane++)
        s_data[lane*8 +: 8] =
            (packet * 11 + block_index * 7 + lane) & 8'hff;
      s_user = (packet == 0) && (block_index == 0);
      s_last = (packet == PACKETS-1) &&
               (block_index == BLOCKS_PER_PACKET-1);
      s_valid = 1'b1;
      do @(posedge clk); while (!s_ready);
      @(negedge clk);
      s_valid = 1'b0;
      s_user = 1'b0;
      s_last = 1'b0;
    end
  endtask

  initial begin
    repeat (8) @(posedge clk);
    resetn = 1'b1;
    repeat (4) @(posedge clk);

    for (int packet = 0; packet < PACKETS; packet++) begin
      for (int block_index = 0; block_index < BLOCKS_PER_PACKET;
           block_index++) begin
        if ((packet == PACKETS-1) &&
            (block_index == BLOCKS_PER_PACKET-1)) begin
          // Drain beat 88 first, then close both sinks before presenting beat
          // 89.  The engine may still accept beat 89 into its empty output
          // register, giving a deterministic final-output stall.
          wait (!m_valid && !meta_valid);
          m_ready = 1'b0;
          meta_ready = 1'b0;
        end
        send_block(packet, block_index);
        if ((packet == PACKETS-1) &&
            (block_index == BLOCKS_PER_PACKET-1)) begin
        end
        if ((packet == 0) && (block_index == 0))
          enforce_busy = 1'b1;
      end
    end

    // The final payload and metadata were just created.  Hold both sinks and
    // prove the frame transaction cannot appear idle while either is pending.
    repeat (32) @(posedge clk);
    if (!busy) $fatal(1, "TX busy dropped before final drains");

    // Draining only video is insufficient: final AAD/TAG still owns the frame.
    @(negedge clk);
    m_ready = 1'b1;
    wait (output_blocks == PACKETS * BLOCKS_PER_PACKET);
    repeat (8) @(posedge clk);
    if (!busy) $fatal(1, "TX busy dropped before final metadata drain");

    @(negedge clk);
    enforce_busy = 1'b0;
    meta_ready = 1'b1;
    wait (metadata_beats == PACKETS * 2);
    wait (!busy);
    repeat (2) @(posedge clk);

    if (protocol_error || frame_id != 32'd1 || packet_index != 16'd0 ||
        output_blocks != PACKETS * BLOCKS_PER_PACKET ||
        metadata_beats != PACKETS * 2)
      $fatal(1, "TX frame-boundary accounting failure");
    $display("PASS: TX busy stayed high for all 1280 packets and final output/meta drains");
    $finish;
  end

  initial begin
    #10000000;
    $display("TIMEOUT_DIAG busy=%0b state=%0d frame_active=%0b drain=%0b guard=%0b packet=%0d payload=%0d out=%0d meta=%0d s_valid=%0b s_ready=%0b m_valid=%0b meta_valid=%0b",
             busy, dut.state, dut.frame_active, dut.frame_drain_pending,
             dut.frame_boundary_guard, packet_index, dut.payload_index,
             output_blocks, metadata_beats, s_valid, s_ready, m_valid,
             meta_valid);
    $fatal(1, "TX frame busy simulation timeout");
  end

  wire unused = &{1'b0, m_data, m_keep, m_user, m_last, meta_data,
                   meta_keep, meta_last, debug_status, key_ready};
endmodule
