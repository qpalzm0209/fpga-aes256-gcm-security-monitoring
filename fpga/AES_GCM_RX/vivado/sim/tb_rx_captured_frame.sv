`timescale 1ns/1ps

module tb_rx_captured_frame;
  localparam int RECORD_BYTES = 1472;
  localparam int RECORDS = 1280;
  localparam int FRAME_BYTES = RECORD_BYTES * RECORDS;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #3.333 clk = ~clk;

  logic [127:0] s_data;
  logic [15:0] s_keep;
  logic s_valid, s_ready, s_last;
  logic [127:0] m_data;
  logic [15:0] m_keep;
  logic m_valid, m_ready, m_last;
  logic [31:0] frame_status;
  logic [255:0] session_key = 256'h000102030405060708090a0b0c0d0e0f_101112131415161718191a1b1c1d1e1f;
  logic session_key_valid = 1'b0;
  logic key_commit = 1'b0;
  logic key_ready;
  logic engine_busy;
  byte unsigned captured [0:FRAME_BYTES-1];
  integer sent_packet = -1;
  integer auth_ok_count = 0;
  integer auth_fail_count = 0;
  integer output_beats = 0;
  integer frame_ready_count = 0;

  axis_gcm_rx_frame_processor_bd dut (
      .aclk(clk), .aresetn(rst_n), .sw3_decrypt(1'b1),
      .session_id(32'h26080330),
      .session_key(session_key), .session_key_valid(session_key_valid),
      .key_commit(key_commit), .key_clear(1'b0),
      .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
      .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
      .s_axis_tlast(s_last), .m_axis_tdata(m_data),
      .m_axis_tkeep(m_keep), .m_axis_tvalid(m_valid),
      .m_axis_tready(m_ready), .m_axis_tlast(m_last),
      .frame_status(frame_status), .key_ready(key_ready), .busy(engine_busy)
  );

  always @(posedge clk) begin
    if (dut.u_impl.auth_ok_pulse) auth_ok_count <= auth_ok_count + 1;
    if (dut.u_impl.auth_fail_pulse) begin
      auth_fail_count <= auth_fail_count + 1;
      $display("FIRST_AUTH_FAIL sent_packet=%0d ok_count=%0d time=%0t",
               sent_packet, auth_ok_count, $time);
    end
    if (m_valid && m_ready) output_beats <= output_beats + 1;
    if (dut.u_impl.frame_ready_pulse) frame_ready_count <= frame_ready_count + 1;
    if (dut.u_impl.protocol_error)
      $display("PROTOCOL_ERROR sent_packet=%0d time=%0t", sent_packet, $time);
  end

  task automatic send_beat(input int byte_offset, input bit last_value);
    logic [127:0] packed_word;
    begin
      for (int lane = 0; lane < 16; lane++)
        packed_word[lane*8 +: 8] = captured[byte_offset + lane];
      s_data <= packed_word;
      s_keep <= 16'hffff;
      s_last <= last_value;
      s_valid <= 1'b1;
      do @(posedge clk); while (!s_ready);
      s_valid <= 1'b0;
      s_last <= 1'b0;
    end
  endtask

  initial begin
    integer fd;
    integer bytes_read;

    s_data = '0;
    s_keep = 16'hffff;
    s_valid = 1'b0;
    s_last = 1'b0;
    m_ready = 1'b1;
    // The launcher runs XSim from its disposable work directory and generates
    // this file there, so the simulation remains portable after the tree is
    // copied to a different machine or Unicode/space-containing path.
    fd = $fopen("rx_encrypted_frame_1280x1472.bin", "rb");
    if (fd == 0) $fatal(1, "captured frame open failed");
    bytes_read = $fread(captured, fd);
    $fclose(fd);
    if (bytes_read != FRAME_BYTES)
      $fatal(1, "captured frame size %0d, expected %0d",
             bytes_read, FRAME_BYTES);

    repeat (8) @(posedge clk);
    rst_n <= 1'b1;
    @(negedge clk);
    session_key_valid = 1'b1;
    key_commit = 1'b1;
    @(negedge clk);
    key_commit = 1'b0;
    while (!key_ready) @(posedge clk);
    repeat (3) @(posedge clk);

    for (int packet = 0; packet < RECORDS; packet++) begin
      sent_packet = packet;
      for (int beat = 0; beat < 92; beat++)
        send_beat(packet * RECORD_BYTES + beat * 16,
                  packet == RECORDS-1 && beat == 91);
    end

    while (!dut.u_impl.frame_done_pulse) @(posedge clk);
    while (output_beats != RECORDS * 90) @(posedge clk);
    repeat (4) @(posedge clk);
    $display("CAPTURE_RESULT auth_ok=%0d auth_fail=%0d output_beats=%0d frame_ready_count=%0d frame_fail=%0b protocol_error=%0b",
             auth_ok_count, auth_fail_count, output_beats,
             frame_ready_count, dut.u_impl.frame_fail,
             dut.u_impl.protocol_error);
    if (auth_ok_count != RECORDS || auth_fail_count != 0 ||
        output_beats != RECORDS * 90 || frame_ready_count != 1 ||
        dut.u_impl.frame_fail || frame_status[29])
      $fatal(1, "captured full-frame RX validation failed");
    $display("PASS: generated 1280-record standard-MTU frame authenticated");
    $finish;
  end

  initial begin
    #100000000;
    $fatal(1, "captured frame simulation timeout");
  end
endmodule
