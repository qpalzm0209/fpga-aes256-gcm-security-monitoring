`timescale 1ns/1ps

import gcm_protocol_pkg::*;

// gcm_rx_error_detector 단위 검증.
//
// record geometry 는 실제 배포값(92 beat / 1280 packet)을 그대로 쓰고,
// 타이머 파라미터만 시뮬레이션 길이에 맞게 줄인다.  코어는 인스턴스화하지
// 않고 auth_ok/auth_fail/frame_done 을 직접 구동해 각 에러를 독립적으로
// 만들 수 있게 한다.
module tb_gcm_rx_error_detector;
  localparam int RECORD_BEATS = 92;
  localparam int PACKETS      = 1280;
  localparam int CLK_HZ       = 150_000_000;
  localparam logic [31:0] TIMEOUT_US = 32'd200;
  localparam logic [31:0] REKEY_US   = 32'd100;

  localparam logic [31:0] SESSION_A = 32'ha5a50001;
  localparam logic [31:0] SESSION_B = 32'ha5a50002;
  localparam logic [31:0] FRAME_1   = 32'd1000;
  localparam logic [31:0] FRAME_2   = 32'd1001;
  localparam logic [31:0] FRAME_3   = 32'd1002;

  // err_flags 비트 위치
  localparam int B_TAG = 0, B_REPLAY = 1, B_SEQ = 2, B_SESSION = 3,
                 B_TIMEOUT = 4;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #3.333 clk = ~clk;

  logic [127:0] s_data  = '0;
  logic         s_valid = 1'b0;
  logic         s_ready = 1'b1;

  logic auth_ok = 1'b0, auth_fail = 1'b0, bypass_p = 1'b0;
  logic frame_done = 1'b0;
  logic eng_key_ready = 1'b1;

  logic [31:0] act_session   = SESSION_A;
  logic        act_key_valid = 1'b1;
  logic        key_commit    = 1'b0;
  logic        key_clear     = 1'b0;
  logic [15:0] key_epoch     = 16'd1;

  wire         err_valid;
  wire [4:0]   err_flags;
  wire [2:0]   err_code;
  wire [4:0]   err_sticky;
  wire         err_overflow;
  wire [191:0] err_record;
  wire [31:0]  c_tag, c_replay, c_seq, c_session, c_timeout;
  wire [31:0]  err_status, err_frame_id, err_session_id;
  wire [15:0]  err_packet_id;
  wire         err_irq;

  gcm_rx_error_detector #(
      .RECORD_WORDS(RECORD_BEATS),
      .FRAME_PACKETS(PACKETS),
      .CLK_HZ(CLK_HZ),
      .TIMEOUT_US(TIMEOUT_US),
      .REKEY_US(REKEY_US)
  ) dut (
      .aclk(clk), .aresetn(resetn),
      .s_axis_tdata(s_data), .s_axis_tvalid(s_valid),
      .s_axis_tready(s_ready),
      .auth_ok_pulse(auth_ok), .auth_fail_pulse(auth_fail),
      .bypass_pulse(bypass_p), .frame_done_pulse(frame_done),
      .engine_key_ready(eng_key_ready),
      .active_session_id(act_session), .active_key_valid(act_key_valid),
      .key_commit_pulse(key_commit), .key_clear_pulse(key_clear),
      .key_epoch(key_epoch),
      .cfg_timeout_us(TIMEOUT_US), .cfg_rekey_us(REKEY_US),
      .cfg_error_enable(5'b11111), .err_clear(5'd0),
      .err_valid(err_valid), .err_flags(err_flags), .err_code(err_code),
      .err_sticky(err_sticky), .err_overflow(err_overflow),
      .err_record(err_record),
      .err_count_tag(c_tag), .err_count_replay(c_replay),
      .err_count_sequence(c_seq), .err_count_session(c_session),
      .err_count_timeout(c_timeout),
      .err_status(err_status),
      .err_last_frame_id(err_frame_id),
      .err_last_session_id(err_session_id),
      .err_last_packet_id(err_packet_id),
      .err_irq(err_irq)
  );

  // ---- 이벤트 수집 -------------------------------------------------------
  logic [4:0]  evt_flags [$];
  logic [2:0]  evt_code  [$];
  logic [31:0] evt_frame [$];
  logic [15:0] evt_pkt   [$];

  always @(posedge clk) begin
    if (resetn && err_valid) begin
      evt_flags.push_back(err_flags);
      evt_code.push_back(err_code);
      evt_frame.push_back(err_frame_id);
      evt_pkt.push_back(err_packet_id);
    end
  end

  int pass_count = 0;
  int fail_count = 0;

  task automatic drain();
    evt_flags.delete();
    evt_code.delete();
    evt_frame.delete();
    evt_pkt.delete();
  endtask

  task automatic check(input string name, input bit ok, input string detail);
    if (ok) begin
      pass_count++;
      $display("[PASS] %-34s %s", name, detail);
    end else begin
      fail_count++;
      $display("[FAIL] %-34s %s", name, detail);
    end
  endtask

  // 정확히 1건이 나왔고 지정한 비트가 서 있는지
  task automatic expect_single(input string name, input int bit_index);
    string detail;
    if (evt_flags.size() != 1) begin
      $sformat(detail, "events=%0d (expected 1)", evt_flags.size());
      check(name, 1'b0, detail);
    end else begin
      $sformat(detail, "flags=%05b code=%0d frame=%0d packet=%0d",
               evt_flags[0], evt_code[0], evt_frame[0], evt_pkt[0]);
      check(name, evt_flags[0][bit_index] === 1'b1, detail);
    end
    drain();
    show_delta(name);
  endtask

  task automatic expect_none(input string name);
    string detail;
    $sformat(detail, "events=%0d (expected 0)", evt_flags.size());
    check(name, evt_flags.size() == 0, detail);
    drain();
    show_delta(name);
  endtask

  // ---- 자극 --------------------------------------------------------------
  // 한 record = AAD 1 + payload 90 + TAG 1.  마지막 beat 다음 clk 에
  // 코어와 동일하게 auth_ok / auth_fail 을 1 clk 펄스로 준다.
  task automatic send_record(input logic [31:0] sess,
                             input logic [31:0] frm,
                             input logic [15:0] idx,
                             input bit accept,
                             input bit tag_error,
                             input bit eof);
    logic [127:0] aad;
    logic [15:0]  flags;
    flags = {GCM_VERSION, 9'd0, (idx == 16'(PACKETS - 1)), (idx == 16'd0),
             1'b1};
    aad = {GCM_MAGIC, sess, frm, idx, flags};

    @(negedge clk);
    s_valid = 1'b1;
    s_data  = gcm_to_axis(aad);
    for (int i = 1; i < RECORD_BEATS; i++) begin
      @(negedge clk);
      s_data = {96'd0, i[31:0]};
    end
    @(negedge clk);
    s_valid = 1'b0;
    if (tag_error)      auth_fail  = 1'b1;
    else if (accept)    auth_ok    = 1'b1;
    if (eof)            frame_done = 1'b1;
    @(negedge clk);
    auth_ok    = 1'b0;
    auth_fail  = 1'b0;
    frame_done = 1'b0;
  endtask

  task automatic send_frame(input logic [31:0] sess, input logic [31:0] frm);
    for (int p = 0; p < PACKETS; p++)
      send_record(sess, frm, 16'(p), 1'b1, 1'b0, (p == PACKETS - 1));
  endtask

  task automatic wait_us(input int count);
    repeat (count * (CLK_HZ / 1_000_000)) @(posedge clk);
  endtask

  // 키 이벤트로 freshness 상태를 비우고 re-key 창이 끝날 때까지 기다린다.
  // 먼저 record 하나를 흘려 idle 타이머를 0 으로 되돌린다.  그렇게 하지
  // 않으면 직전 시나리오에서 쌓인 무입력 시간이 남아, key event 가
  // timeout_latched 를 풀어주는 순간 다음 시나리오에 TIMEOUT 이 끼어든다.
  task automatic reset_context();
    send_record(act_session, 32'hdead0000, 16'd0, 1'b1, 1'b0, 1'b0);
    @(negedge clk);
    key_commit = 1'b1;
    @(negedge clk);
    key_commit = 1'b0;
    wait_us(int'(REKEY_US) + 20);
    drain();
  endtask

  int unsigned prev_tag, prev_replay, prev_seq, prev_session, prev_timeout;

  task automatic show_delta(input string name);
    $display("       %-30s dTAG=%0d dREPLAY=%0d dSEQ=%0d dSESSION=%0d dTIMEOUT=%0d",
             name, c_tag - prev_tag, c_replay - prev_replay,
             c_seq - prev_seq, c_session - prev_session,
             c_timeout - prev_timeout);
    prev_tag = c_tag; prev_replay = c_replay; prev_seq = c_seq;
    prev_session = c_session; prev_timeout = c_timeout;
  endtask

  initial begin
    $display("=== tb_gcm_rx_error_detector ===");
    repeat (10) @(posedge clk);
    resetn = 1'b1;
    // reset 직후에도 re-key 유예 창이 열려 있으므로 먼저 흘려보낸다.
    wait_us(int'(REKEY_US) + 20);
    drain();

    // ---- S1: 정상 프레임 1개 -> 이벤트 없음 ----------------------------
    send_frame(SESSION_A, FRAME_1);
    wait_us(5);
    expect_none("S1 clean frame");

    // ---- S2: 프레임 내 packet 재전송 -> REPLAY --------------------------
    send_record(SESSION_A, FRAME_2, 16'd0, 1'b1, 1'b0, 1'b0);
    for (int p = 1; p <= 5; p++)
      send_record(SESSION_A, FRAME_2, 16'(p), 1'b1, 1'b0, 1'b0);
    drain();
    send_record(SESSION_A, FRAME_2, 16'd3, 1'b1, 1'b0, 1'b0); // 이미 본 index
    wait_us(5);
    expect_single("S2 in-frame replay", B_REPLAY);

    // ---- S3: index 건너뜀 -> SEQUENCE -----------------------------------
    reset_context();
    send_record(SESSION_A, FRAME_3, 16'd0, 1'b1, 1'b0, 1'b0);
    send_record(SESSION_A, FRAME_3, 16'd1, 1'b1, 1'b0, 1'b0);
    drain();
    send_record(SESSION_A, FRAME_3, 16'd7, 1'b1, 1'b0, 1'b0); // 2 를 기대
    wait_us(5);
    expect_single("S3 index skip", B_SEQ);

    // ---- S4: 세션 불일치 -> SESSION -------------------------------------
    reset_context();
    send_record(SESSION_A, FRAME_3, 16'd0, 1'b1, 1'b0, 1'b0);
    drain();
    // 코어라면 header 불량으로 폐기하므로 auth pulse 를 주지 않는다.
    send_record(SESSION_B, FRAME_3, 16'd1, 1'b0, 1'b0, 1'b0);
    wait_us(5);
    expect_single("S4 session mismatch", B_SESSION);

    // ---- S5: TAG 검증 실패 -> TAG ---------------------------------------
    reset_context();
    send_record(SESSION_A, FRAME_3, 16'd0, 1'b1, 1'b0, 1'b0);
    drain();
    send_record(SESSION_A, FRAME_3, 16'd1, 1'b0, 1'b1, 1'b0);
    wait_us(5);
    expect_single("S5 tag failure", B_TAG);

    // ---- S6: 무입력 -> TIMEOUT ------------------------------------------
    reset_context();
    send_record(SESSION_A, FRAME_3, 16'd0, 1'b1, 1'b0, 1'b0);
    drain();
    wait_us(int'(TIMEOUT_US) + 50);
    expect_single("S6 link timeout", B_TIMEOUT);

    // 계속 조용해도 재발화하지 않아야 한다 (로그 폭주 방지)
    wait_us(int'(TIMEOUT_US) * 2);
    expect_none("S6b timeout not repeated");

    // ---- S6c: 키 이벤트 후에는 다시 감시가 열려야 한다 --------------------
    // re-key 뒤에도 영상이 안 돌아오면 반드시 알아야 하므로, key event 는
    // timeout_latched 를 푼다.  이것이 의도된 동작임을 명시적으로 검사한다.
    @(negedge clk);
    key_commit = 1'b1;
    @(negedge clk);
    key_commit = 1'b0;
    drain();
    wait_us(int'(REKEY_US) + int'(TIMEOUT_US) + 50);
    expect_single("S6c timeout re-arms after key event", B_TIMEOUT);

    // ---- S7: 완료된 프레임 재생 -> REPLAY --------------------------------
    reset_context();
    send_frame(SESSION_A, FRAME_1);      // high-water = FRAME_1
    wait_us(5);
    drain();
    send_record(SESSION_A, FRAME_1, 16'd0, 1'b1, 1'b0, 1'b0); // 같은 프레임 재생
    wait_us(5);
    expect_single("S7 completed-frame replay", B_REPLAY);

    // ---- S8: re-key 창 안의 세션 전환 -> 에러 아님 -----------------------
    @(negedge clk);
    key_commit = 1'b1;
    act_session = SESSION_B;
    key_epoch = key_epoch + 16'd1;
    @(negedge clk);
    key_commit = 1'b0;
    drain();
    send_record(SESSION_B, 32'd2000, 16'd0, 1'b1, 1'b0, 1'b0);
    send_record(SESSION_B, 32'd2000, 16'd1, 1'b1, 1'b0, 1'b0);
    wait_us(5);
    expect_none("S8 rekey window adopts session");

    // ---- S9: 키가 없으면 TIMEOUT 억제 ------------------------------------
    wait_us(int'(REKEY_US) + 20);
    drain();
    @(negedge clk);
    key_clear = 1'b1;
    act_key_valid = 1'b0;
    eng_key_ready = 1'b0;
    @(negedge clk);
    key_clear = 1'b0;
    wait_us(int'(TIMEOUT_US) * 3);
    expect_none("S9 timeout suppressed without key");

    // ---- 카운터 확인 ------------------------------------------------------
    // 시나리오별 기대 누적치.
    //   TAG     = 1  (S5)
    //   REPLAY  = 2  (S2, S7)
    //   SESSION = 1  (S4)
    //   TIMEOUT = 2  (S6, S6c)
    //   SEQ     = 6  S2 에서 재전송 packet 이 expect_index 와도 어긋나 1,
    //                S3 의 index skip 1,
    //                S3/S4/S5/S6 앞의 reset_context 가 미완성 프레임을
    //                SOF 로 닫으며 frame_short 4  → 1 + 1 + 4 = 6
    begin
      string detail;
      $sformat(detail,
               "tag=%0d replay=%0d seq=%0d session=%0d timeout=%0d sticky=%05b",
               c_tag, c_replay, c_seq, c_session, c_timeout, err_sticky);
      check("counters accumulate",
            (c_tag == 32'd1) && (c_replay == 32'd2) && (c_seq == 32'd6) &&
            (c_session == 32'd1) && (c_timeout == 32'd2) &&
            (err_sticky == 5'b11111), detail);
    end

    $display("--------------------------------------------------");
    $display("PASS=%0d  FAIL=%0d", pass_count, fail_count);
    if (fail_count == 0)
      $display("RESULT: ALL TESTS PASSED");
    else
      $display("RESULT: FAILURES PRESENT");
    $finish;
  end

  initial begin
    #50_000_000;
    $display("RESULT: TIMEOUT - testbench did not finish");
    $finish;
  end
endmodule

