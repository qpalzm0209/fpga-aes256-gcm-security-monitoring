`timescale 1ns/1ps

module tb_video_aes_gcm_tx_top;
  logic clk = 1'b0;
  logic resetn = 1'b0;
  logic sw3_encrypt = 1'b1;
  logic [31:0] session_id = 32'h11223344;
  logic [255:0] session_key = 256'h000102030405060708090a0b0c0d0e0f_101112131415161718191a1b1c1d1e1f;
  logic session_key_valid = 1'b0;
  logic key_commit = 1'b0;

  logic [127:0] s_data = '0;
  logic [15:0]  s_keep = 16'hffff;
  logic         s_valid = 1'b0;
  wire          s_ready;
  logic         s_user = 1'b0;
  logic         s_last = 1'b0;

  wire [127:0] m_data;
  wire [15:0]  m_keep;
  wire         m_valid;
  logic        m_ready = 1'b1;
  wire         m_user;
  wire         m_last;

  wire [127:0] meta_data;
  wire [15:0]  meta_keep;
  wire         meta_valid;
  logic        meta_ready = 1'b1;
  wire         meta_last;
  wire [31:0]  status_frame_id;
  wire [15:0]  status_packet_index;
  wire         key_ready;
  wire         busy;
  wire         protocol_error;

  integer cipher_file;
  integer meta_file;
  integer output_blocks = 0;
  integer meta_blocks = 0;
  integer i;

  always #3.333 clk = ~clk;

  video_aes_gcm_tx_top dut (
      .aclk(clk), .aresetn(resetn), .sw3_encrypt(sw3_encrypt),
      .session_id(session_id),
      .session_key(session_key), .session_key_valid(session_key_valid),
      .key_commit(key_commit), .key_clear(1'b0),
      .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
      .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
      .s_axis_tuser(s_user), .s_axis_tlast(s_last),
      .m_axis_tdata(m_data), .m_axis_tkeep(m_keep),
      .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
      .m_axis_tuser(m_user), .m_axis_tlast(m_last),
      .m_meta_tdata(meta_data), .m_meta_tkeep(meta_keep),
      .m_meta_tvalid(meta_valid), .m_meta_tready(meta_ready),
      .m_meta_tlast(meta_last),
      .status_frame_id(status_frame_id),
      .status_packet_index(status_packet_index),
      .key_ready(key_ready), .busy(busy),
      .protocol_error(protocol_error)
  );

  always @(posedge clk) begin
    if (resetn && m_valid && m_ready) begin
      for (i = 0; i < 16; i = i + 1)
        $fwrite(cipher_file, "%02x", m_data[i*8 +: 8]);
      $fwrite(cipher_file, "\n");
      output_blocks <= output_blocks + 1;
    end
    if (resetn && meta_valid && meta_ready) begin
      for (i = 0; i < 16; i = i + 1)
        $fwrite(meta_file, "%02x", meta_data[i*8 +: 8]);
      $fwrite(meta_file, "\n");
      meta_blocks <= meta_blocks + 1;
    end
  end

  task automatic send_block(input integer block_index);
    integer lane;
    begin
      @(negedge clk);
      for (lane = 0; lane < 16; lane = lane + 1)
        s_data[lane*8 +: 8] = ((block_index * 16) + lane) & 8'hff;
      s_user  = (block_index == 0);
      s_last  = 1'b0;
      s_valid = 1'b1;
      do @(posedge clk); while (!s_ready);
      @(negedge clk);
      s_valid = 1'b0;
      s_user  = 1'b0;
    end
  endtask

  initial begin
    cipher_file = $fopen("tx_cipher.hex", "w");
    meta_file   = $fopen("tx_meta.hex", "w");
    repeat (8) @(posedge clk);
    resetn = 1'b1;
    @(negedge clk);
    session_key_valid = 1'b1;
    key_commit = 1'b1;
    @(negedge clk);
    key_commit = 1'b0;
    wait (key_ready);
    repeat (4) @(posedge clk);
    for (integer block = 0; block < 90; block = block + 1)
      send_block(block);
    wait (meta_blocks == 2);
    repeat (5) @(posedge clk);
    $display("RESULT output_blocks=%0d meta_blocks=%0d protocol_error=%0d frame=%0d packet=%0d",
             output_blocks, meta_blocks, protocol_error,
             status_frame_id, status_packet_index);
    $fclose(cipher_file);
    $fclose(meta_file);
    if (output_blocks != 90 || meta_blocks != 2 || protocol_error)
      $fatal(1, "AXI/protocol failure");
    $finish;
  end

  initial begin
    #5000000;
    $fatal(1, "simulation timeout");
  end
endmodule
