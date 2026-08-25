`timescale 1ns/1ps

module tb_tx_backpressure;
  localparam integer PACKETS = 1280;
  localparam integer BLOCKS_PER_PACKET = 90;

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
  logic        m_ready = 1'b0;
  wire         m_user;
  wire         m_last;

  wire [127:0] meta_data;
  wire [15:0]  meta_keep;
  wire         meta_valid;
  logic        meta_ready = 1'b0;
  wire         meta_last;
  wire [31:0]  status_frame_id;
  wire [15:0]  status_packet_index;
  wire [31:0]  debug_status;
  wire         key_ready;
  wire         busy;
  wire         protocol_error;

  logic [31:0] lfsr = 32'h1aceb00c;
  logic directed_output_stall = 1'b0;
  integer cipher_file;
  integer meta_file;
  integer output_blocks = 0;
  integer meta_blocks = 0;
  integer lane;

  logic output_held = 1'b0;
  logic [127:0] held_data;
  logic [15:0] held_keep;
  logic held_user;
  logic held_last;
  logic meta_held = 1'b0;
  logic [127:0] held_meta_data;
  logic [15:0] held_meta_keep;
  logic held_meta_last;

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
      .debug_status(debug_status),
      .key_ready(key_ready), .busy(busy),
      .protocol_error(protocol_error)
  );

  // Independent, deterministic stalls on both AXI output channels.  The long
  // low runs exercise the exact condition created by AXI DMA backpressure.
  always @(negedge clk) begin
    if (!resetn) begin
      lfsr <= 32'h1aceb00c;
      m_ready <= 1'b0;
      meta_ready <= 1'b0;
    end else begin
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      m_ready <= !directed_output_stall &&
                 (lfsr[4:0] != 5'b00000) && (lfsr[9:7] != 3'b000);
      meta_ready <= (lfsr[15:13] != 3'b000);
    end
  end

  always @(posedge clk) begin
    if (!resetn) begin
      output_held <= 1'b0;
      meta_held <= 1'b0;
    end else begin
      if (output_held) begin
        if (!m_valid || m_data !== held_data || m_keep !== held_keep ||
            m_user !== held_user || m_last !== held_last)
          $fatal(1, "m_axis changed while stalled");
        if (m_ready)
          output_held <= 1'b0;
      end
      if (m_valid && !m_ready && !output_held) begin
        output_held <= 1'b1;
        held_data <= m_data;
        held_keep <= m_keep;
        held_user <= m_user;
        held_last <= m_last;
      end

      if (meta_held) begin
        if (!meta_valid || meta_data !== held_meta_data ||
            meta_keep !== held_meta_keep || meta_last !== held_meta_last)
          $fatal(1, "m_meta changed while stalled");
        if (meta_ready)
          meta_held <= 1'b0;
      end
      if (meta_valid && !meta_ready && !meta_held) begin
        meta_held <= 1'b1;
        held_meta_data <= meta_data;
        held_meta_keep <= meta_keep;
        held_meta_last <= meta_last;
      end

      if (m_valid && m_ready) begin
        $fwrite(cipher_file, "%0d %0d ",
                output_blocks / BLOCKS_PER_PACKET,
                output_blocks % BLOCKS_PER_PACKET);
        for (lane = 0; lane < 16; lane = lane + 1)
          $fwrite(cipher_file, "%02x", m_data[lane*8 +: 8]);
        $fwrite(cipher_file, "\n");
        output_blocks <= output_blocks + 1;
      end

      if (meta_valid && meta_ready) begin
        $fwrite(meta_file, "%0d %0d ", meta_blocks / 2, meta_blocks % 2);
        for (lane = 0; lane < 16; lane = lane + 1)
          $fwrite(meta_file, "%02x", meta_data[lane*8 +: 8]);
        $fwrite(meta_file, "\n");
        meta_blocks <= meta_blocks + 1;
      end
    end
  end

  task automatic send_block(input integer packet, input integer block_index);
    integer byte_lane;
    begin
      // Add occasional input bubbles independently of downstream stalls.
      if (((packet * 7 + block_index * 3) % 19) == 0)
        repeat (3) @(posedge clk);
      @(negedge clk);
      for (byte_lane = 0; byte_lane < 16; byte_lane = byte_lane + 1)
        s_data[byte_lane*8 +: 8] =
            (packet * 13 + block_index * 17 + byte_lane * 29) & 8'hff;
      s_user  = (packet == 0) && (block_index == 0);
      s_last  = (packet == PACKETS - 1) &&
                (block_index == BLOCKS_PER_PACKET - 1);
      // Hold the previous packet's final output beat beyond the 16-cycle AAD
      // GHASH.  This reproduces the hardware-only ENC_SETUP_WAIT deadlock
      // that appeared when AXI DMA S2MM backpressured a packet boundary.
      if ((packet == 8) && (block_index == BLOCKS_PER_PACKET - 1)) begin
        directed_output_stall = 1'b1;
        fork
          begin
            repeat (80) @(posedge clk);
            directed_output_stall = 1'b0;
          end
        join_none
      end
      s_valid = 1'b1;
      do @(posedge clk); while (!s_ready);
      @(negedge clk);
      s_valid = 1'b0;
      s_user  = 1'b0;
    end
  endtask

  initial begin
    cipher_file = $fopen("tx_backpressure_cipher.hex", "w");
    meta_file = $fopen("tx_backpressure_meta.hex", "w");
    repeat (8) @(posedge clk);
    resetn = 1'b1;
    @(negedge clk);
    // Model a runtime reset after the session bank already committed the
    // key: the valid/key levels remain, but key_commit is no longer present.
    session_key_valid = 1'b1;
    wait (key_ready);
    repeat (4) @(posedge clk);

    for (integer packet = 0; packet < PACKETS; packet = packet + 1)
      for (integer block = 0; block < BLOCKS_PER_PACKET; block = block + 1)
        send_block(packet, block);

    wait ((output_blocks == PACKETS * BLOCKS_PER_PACKET) &&
          (meta_blocks == PACKETS * 2));
    repeat (10) @(posedge clk);
    $display("RESULT packets=%0d output_blocks=%0d meta_blocks=%0d protocol_error=%0d frame=%0d packet=%0d",
             PACKETS, output_blocks, meta_blocks, protocol_error,
             status_frame_id, status_packet_index);
    $fclose(cipher_file);
    $fclose(meta_file);
    if (protocol_error ||
        status_frame_id != (PACKETS / 1280) ||
        status_packet_index != (PACKETS % 1280))
      $fatal(1, "AXI/protocol counter failure");
    $finish;
  end

  initial begin
    #20000000;
    $fatal(1, "simulation timeout");
  end
endmodule
