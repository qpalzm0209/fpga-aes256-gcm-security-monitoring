`timescale 1ns/1ps

// Models the property that the old width-bridge test missed: a camera emits
// active pixels at a fixed rate and cannot pause just because AES deasserts
// TREADY.  The active part of every 720p30 line is intentionally emitted at
// one 16-bit pixel per 150-MHz clock (more bursty than the live sensor).  A
// behavioral FIFO with the same 8192-beat capacity as the block design sits
// between the packer and the real AES-GCM frame processor.
module tb_tx_camera_realtime_fifo;
  localparam int WIDTH = 1280;
  localparam int HEIGHT = 720;
  localparam int FRAME_BLOCKS = WIDTH * HEIGHT / 8;
  localparam int FIFO_DEPTH = 8192;
  // 150 MHz / 30 fps / 750 total lines, rounded up.  This preserves the
  // camera's average frame rate while making the active-line burst worst-case.
  localparam int LINE_CYCLES = 6667;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #3.333 clk = ~clk;

  logic [15:0] cam_data = '0;
  logic [1:0] cam_keep = 2'b11;
  logic [1:0] cam_strb = 2'b11;
  logic cam_user = 1'b0;
  logic cam_last = 1'b0;
  logic cam_valid = 1'b0;
  wire cam_ready;

  wire [127:0] pack_data;
  wire [15:0] pack_keep;
  wire pack_valid;
  wire pack_ready;
  wire pack_last;
  wire pack_error;

  logic [127:0] fifo_data [0:FIFO_DEPTH-1];
  logic [15:0] fifo_keep [0:FIFO_DEPTH-1];
  logic fifo_last [0:FIFO_DEPTH-1];
  integer write_pointer = 0;
  integer read_pointer = 0;
  integer fifo_count = 0;
  integer fifo_high_water = 0;

  wire [127:0] crypto_in_data = fifo_data[read_pointer];
  wire [15:0] crypto_in_keep = fifo_keep[read_pointer];
  wire crypto_in_last = fifo_last[read_pointer];
  wire crypto_in_valid = fifo_count != 0;
  wire crypto_in_ready;
  wire fifo_push = pack_valid && pack_ready;
  wire fifo_pop = crypto_in_valid && crypto_in_ready;
  assign pack_ready = fifo_count < FIFO_DEPTH;

  wire [127:0] cipher_data;
  wire [15:0] cipher_keep;
  wire cipher_valid;
  logic cipher_ready = 1'b0;
  wire cipher_last;
  wire [127:0] meta_data;
  wire [15:0] meta_keep;
  wire meta_valid;
  logic meta_ready = 1'b0;
  wire meta_last;
  wire [31:0] active_frame_id;
  wire active_frame_encrypted;
  wire [31:0] debug_status;
  wire key_ready;
  wire crypto_busy;
  wire crypto_error;

  logic session_key_valid = 1'b0;
  logic key_commit = 1'b0;
  integer cycle_count = 0;
  integer output_blocks = 0;
  integer metadata_beats = 0;
  integer camera_pixels = 0;

  axis_video16_to_frame128 #(
      .FRAME_WIDTH(WIDTH), .FRAME_HEIGHT(HEIGHT)
  ) u_pack (
      .aclk(clk), .aresetn(resetn),
      .s_axis_tdata(cam_data), .s_axis_tkeep(cam_keep),
      .s_axis_tstrb(cam_strb), .s_axis_tuser(cam_user),
      .s_axis_tlast(cam_last), .s_axis_tid(1'b0),
      .s_axis_tdest(1'b0), .s_axis_tvalid(cam_valid),
      .s_axis_tready(cam_ready),
      .m_axis_tdata(pack_data), .m_axis_tkeep(pack_keep),
      .m_axis_tvalid(pack_valid), .m_axis_tready(pack_ready),
      .m_axis_tlast(pack_last), .protocol_error(pack_error)
  );

  axis_gcm_tx_frame_processor u_crypto (
      .aclk(clk), .aresetn(resetn), .sw3_encrypt(1'b1),
      .session_id(32'h26081232),
      .session_key(256'h000102030405060708090a0b0c0d0e0f_101112131415161718191a1b1c1d1e1f),
      .session_key_valid(session_key_valid), .key_commit(key_commit),
      .key_clear(1'b0),
      .s_axis_tdata(crypto_in_data), .s_axis_tkeep(crypto_in_keep),
      .s_axis_tvalid(crypto_in_valid), .s_axis_tready(crypto_in_ready),
      .s_axis_tlast(crypto_in_last),
      .m_axis_tdata(cipher_data), .m_axis_tkeep(cipher_keep),
      .m_axis_tvalid(cipher_valid), .m_axis_tready(cipher_ready),
      .m_axis_tlast(cipher_last),
      .m_meta_tdata(meta_data), .m_meta_tkeep(meta_keep),
      .m_meta_tvalid(meta_valid), .m_meta_tready(meta_ready),
      .m_meta_tlast(meta_last), .active_frame_id(active_frame_id),
      .active_frame_encrypted(active_frame_encrypted),
      .debug_status(debug_status), .key_ready(key_ready),
      .busy(crypto_busy), .protocol_error(crypto_error)
  );

  always @(posedge clk) begin
    cycle_count <= cycle_count + 1;
    // Downstream stalls are independent of the fixed-rate camera source.
    cipher_ready <= resetn && ((cycle_count % 257) >= 9);
    meta_ready <= resetn && ((cycle_count % 113) >= 5);

    if (!resetn) begin
      write_pointer <= 0;
      read_pointer <= 0;
      fifo_count <= 0;
      fifo_high_water <= 0;
    end else begin
      if (fifo_push) begin
        fifo_data[write_pointer] <= pack_data;
        fifo_keep[write_pointer] <= pack_keep;
        fifo_last[write_pointer] <= pack_last;
        write_pointer <= (write_pointer == FIFO_DEPTH-1) ? 0 :
                         write_pointer + 1;
      end
      if (fifo_pop)
        read_pointer <= (read_pointer == FIFO_DEPTH-1) ? 0 :
                        read_pointer + 1;
      case ({fifo_push, fifo_pop})
        2'b10: fifo_count <= fifo_count + 1;
        2'b01: fifo_count <= fifo_count - 1;
        default: fifo_count <= fifo_count;
      endcase
      if (fifo_count > fifo_high_water)
        fifo_high_water <= fifo_count;
      if (fifo_count >= FIFO_DEPTH)
        $fatal(1, "ingress FIFO overflow");
    end

    if (resetn && cam_valid) begin
      if (!cam_ready)
        $fatal(1, "fixed-rate camera was backpressured at pixel %0d FIFO=%0d",
               camera_pixels, fifo_count);
      camera_pixels <= camera_pixels + 1;
    end
    if (resetn && cipher_valid && cipher_ready)
      output_blocks <= output_blocks + 1;
    if (resetn && meta_valid && meta_ready)
      metadata_beats <= metadata_beats + 1;
  end

  initial begin : camera_source
    repeat (12) @(posedge clk);
    resetn = 1'b1;
    @(negedge clk);
    session_key_valid = 1'b1;
    key_commit = 1'b1;
    @(negedge clk);
    key_commit = 1'b0;
    wait (key_ready);
    repeat (8) @(posedge clk);

    for (int line = 0; line < HEIGHT; line++) begin
      for (int pixel = 0; pixel < WIDTH; pixel++) begin
        @(negedge clk);
        cam_data = (line * WIDTH + pixel) & 16'hffff;
        cam_user = (line == 0) && (pixel == 0);
        cam_last = pixel == WIDTH-1;
        cam_valid = 1'b1;
        @(posedge clk);
      end
      @(negedge clk);
      cam_valid = 1'b0;
      cam_user = 1'b0;
      cam_last = 1'b0;
      repeat (LINE_CYCLES - WIDTH) @(posedge clk);
    end
    // Thirty vertical-blank lines complete the 720p30 timing envelope.
    repeat (30 * LINE_CYCLES) @(posedge clk);

    wait (fifo_count == 0 && !crypto_busy);
    repeat (20) @(posedge clk);
    if (pack_error || crypto_error)
      $fatal(1, "protocol error pack=%0b crypto=%0b", pack_error,
             crypto_error);
    if (camera_pixels != WIDTH * HEIGHT ||
        output_blocks != FRAME_BLOCKS || metadata_beats != 2560)
      $fatal(1,
             "count mismatch pixels=%0d cipher=%0d metadata=%0d",
             camera_pixels, output_blocks, metadata_beats);
    if (fifo_high_water >= 7680)
      $fatal(1, "FIFO safety margin exhausted: high_water=%0d",
             fifo_high_water);
    $display("PASS: fixed-rate 720p30 camera survived AES backpressure; FIFO high-water=%0d/%0d",
             fifo_high_water, FIFO_DEPTH);
    $finish;
  end

  initial begin
    #80000000;
    $fatal(1,
           "timeout pixels=%0d fifo=%0d high=%0d cipher=%0d metadata=%0d",
           camera_pixels, fifo_count, fifo_high_water, output_blocks,
           metadata_beats);
  end

  wire unused = &{1'b0, cipher_data, cipher_keep, cipher_last, meta_data,
                  meta_keep, meta_last, active_frame_id,
                  active_frame_encrypted, debug_status};
endmodule
