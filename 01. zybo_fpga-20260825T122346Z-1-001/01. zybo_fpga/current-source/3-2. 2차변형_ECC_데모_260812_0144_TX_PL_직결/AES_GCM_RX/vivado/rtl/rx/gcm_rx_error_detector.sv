`timescale 1ns/1ps

import gcm_protocol_pkg::*;

// AAD 계열 4종 에러(REPLAY / SEQUENCE / SESSION / TIMEOUT)를 자체 판정하고,
// AES-GCM 코어가 확정한 TAG 에러를 합쳐 5종을 하나의 이벤트로 내보낸다.
//
// 기대 session_id 를 소프트웨어 shadow 값이 아니라 현재 ECC 데모의
// aes_session_key_regs active_session_id 에서 직접 받고, re-key 유예 창은
// key_commit_pulse / key_clear_pulse 로 자동 개시한다.  BTN3 종료로 키가
// 지워진 구간에서는 TIMEOUT 을 억제해 의도된 정지를 에러로 보고하지 않는다.
//
// s_axis 는 관찰(tap) 전용이다.  어떤 스트림 신호도 구동하지 않으므로 코어의
// ready/valid 계약과 150 MHz 타이밍 클로저에 영향을 주지 않는다.
//
// 한 record = RECORD_WORDS transfer = AAD 1 + payload 90 + TAG 1.
module gcm_rx_error_detector #(
    parameter logic [31:0] MAGIC         = GCM_MAGIC,
    parameter int unsigned RECORD_WORDS  = 92,
    parameter int unsigned FRAME_PACKETS = 1280,
    parameter int unsigned CLK_HZ        = 150_000_000,
    parameter logic [31:0] TIMEOUT_US    = 32'd100_000,  // 100 ms
    parameter logic [31:0] REKEY_US      = 32'd50_000    // 50 ms
) (
    input  logic         aclk,
    input  logic         aresetn,

    // ---- AXI4-Stream tap (입력 전용) --------------------------------------
    input  logic [127:0] s_axis_tdata,
    input  logic         s_axis_tvalid,
    input  logic         s_axis_tready,

    // ---- AES-GCM 코어 피드백 ----------------------------------------------
    input  logic         auth_ok_pulse,    // packet 인증 성공
    input  logic         auth_fail_pulse,  // == TAG 에러 (E1)
    input  logic         bypass_pulse,     // 평문 mode commit
    input  logic         frame_done_pulse, // EOF packet commit
    input  logic         engine_key_ready, // crypto_ready && session_key_valid

    // ---- 세션키 레지스터 뱅크 ----------------------------------------------
    input  logic [31:0]  active_session_id,
    input  logic         active_key_valid,
    input  logic         key_commit_pulse,
    input  logic         key_clear_pulse,
    input  logic [15:0]  key_epoch,

    // ---- 설정 --------------------------------------------------------------
    input  logic [31:0]  cfg_timeout_us,
    input  logic [31:0]  cfg_rekey_us,
    input  logic [4:0]   cfg_error_enable,
    input  logic [4:0]   err_clear,        // sticky W1C

    // ---- 5종 에러 묶음 출력 -------------------------------------------------
    output logic         err_valid,      // 이벤트 1 clk strobe
    output logic [4:0]   err_flags,      // one-hot 묶음 (동시 성립 가능)
    output logic [2:0]   err_code,       // 우선순위 인코딩된 대표 코드
    output logic [4:0]   err_sticky,     // 누적, err_clear 로 해제
    output logic         err_overflow,   // 이벤트 유실 발생
    output logic [191:0] err_record,     // log FIFO 1 entry (6 x 32 bit)
    output logic [31:0]  err_count_tag,
    output logic [31:0]  err_count_replay,
    output logic [31:0]  err_count_sequence,
    output logic [31:0]  err_count_session,
    output logic [31:0]  err_count_timeout,
    output logic [31:0]  err_status,     // GPIO 폴링용 요약 워드
    output logic [31:0]  err_last_frame_id,
    output logic [31:0]  err_last_session_id,
    output logic [15:0]  err_last_packet_id,
    output logic         err_irq
);
    // err_flags / err_sticky / cfg_error_enable 비트 위치
    localparam int ERR_TAG      = 0;
    localparam int ERR_REPLAY   = 1;
    localparam int ERR_SEQUENCE = 2;
    localparam int ERR_SESSION  = 3;
    localparam int ERR_TIMEOUT  = 4;

    localparam logic [2:0] CODE_NONE     = 3'd0;
    localparam logic [2:0] CODE_TAG      = 3'd1;
    localparam logic [2:0] CODE_REPLAY   = 3'd2;
    localparam logic [2:0] CODE_SEQUENCE = 3'd3;
    localparam logic [2:0] CODE_SESSION  = 3'd4;
    localparam logic [2:0] CODE_TIMEOUT  = 3'd5;

    localparam int unsigned US_DIVIDE     = CLK_HZ / 1_000_000;
    localparam int unsigned COUNT_BITS    = $clog2(FRAME_PACKETS + 1);
    localparam int unsigned WORD_BITS     = $clog2(RECORD_WORDS);
    localparam int unsigned SEEN_WORDS    = (FRAME_PACKETS + 31) / 32;
    localparam int unsigned WORD_SEL_BITS = $clog2(SEEN_WORDS);

    // ---------------------------------------------------------------------
    // 시간 기준: 1 us tick.  32 bit 이므로 약 71.6 분에 wrap 한다.
    // ---------------------------------------------------------------------
    logic [$clog2(US_DIVIDE)-1:0] us_prescale;
    logic [31:0]                  time_us;
    logic                         us_tick;

    assign us_tick = (us_prescale == US_DIVIDE[$clog2(US_DIVIDE)-1:0] - 1);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            us_prescale <= '0;
            time_us     <= 32'd0;
        end else if (us_tick) begin
            us_prescale <= '0;
            time_us     <= time_us + 32'd1;
        end else begin
            us_prescale <= us_prescale + 1'b1;
        end
    end

    // ---------------------------------------------------------------------
    // 스트림 tap 과 AAD 파싱
    // ---------------------------------------------------------------------
    wire         input_fire = s_axis_tvalid && s_axis_tready;
    wire [127:0] aad_gcm    = axis_to_gcm(s_axis_tdata);
    wire [31:0]  in_magic   = aad_gcm[127:96];
    wire [31:0]  in_session = aad_gcm[95:64];
    wire [31:0]  in_frame   = aad_gcm[63:32];
    wire [15:0]  in_index   = aad_gcm[31:16];
    wire [15:0]  in_flags   = aad_gcm[15:0];

    logic [WORD_BITS-1:0] record_word;

    wire aad_beat        = input_fire && (record_word == '0);
    wire packet_end_beat = input_fire &&
                           (record_word == WORD_BITS'(RECORD_WORDS - 1));

    always_ff @(posedge aclk) begin
        if (!aresetn)
            record_word <= '0;
        else if (input_fire)
            record_word <= (record_word == WORD_BITS'(RECORD_WORDS - 1)) ?
                           '0 : record_word + 1'b1;
    end

    // ---------------------------------------------------------------------
    // frame / session 컨텍스트
    // ---------------------------------------------------------------------
    logic                  ctx_valid;
    logic [31:0]           ctx_session;
    logic [31:0]           ctx_frame;
    logic [15:0]           expect_index;
    logic [COUNT_BITS-1:0] accept_count;
    logic                  frame_error;
    logic                  hw_valid;
    logic [31:0]           frame_highwater;

    // replay bitmap.  1280 bit 을 단일 벡터로 두면 index 조회가 1280:1 mux
    // (10 logic level)가 되어 150 MHz 를 못 맞춘다.  32 bit word 배열로 나눠
    // word 선택과 bit 선택을 서로 다른 clk 에 수행한다.
    logic [31:0] seen_mem [SEEN_WORDS];

    // 처리 중 packet 컨텍스트와 commit 시점용 shadow.
    // 코어의 auth_*_pulse 는 마지막 transfer 다음 clk 에 뜨는데, 그 clk 에
    // 다음 packet 의 AAD beat 가 겹칠 수 있으므로 별도 shadow 가 필요하다.
    logic [31:0] pkt_session, pkt_frame;
    logic [15:0] pkt_index;
    logic        pkt_encrypted;
    logic [31:0] cmt_session, cmt_frame;
    logic [15:0] cmt_index;
    logic        cmt_encrypted;

    wire packet_accept = auth_ok_pulse || bypass_pulse;

    // AAD 판정 파이프라인.  다음 AAD beat 까지 RECORD_WORDS clk 이 남으므로
    // 3 단 지연은 검출 동작에 영향을 주지 않는다.
    //   S0 (aad_beat) : AAD 필드 latch
    //   S1            : seen_mem word 조회를 레지스터에 담음
    //   S2            : bit 선택 + 전체 판정 + 컨텍스트 갱신
    //   S3            : 이벤트 필드 확정 → 이벤트 mux → 출력
    logic        chk_valid, ck2_valid;
    logic [31:0] chk_session, chk_frame, ck2_session, ck2_frame;
    logic [15:0] chk_index, chk_flags, ck2_index, ck2_flags;
    logic        chk_index_ok, ck2_index_ok;
    logic        chk_magic_ok, ck2_magic_ok;
    logic [31:0] ck2_seen_word;

    wire [WORD_SEL_BITS-1:0] chk_word_sel = chk_index[5 +: WORD_SEL_BITS];

    // ---------------------------------------------------------------------
    // re-key / 세션 전환 유예 창
    // 소프트웨어가 따로 알려줄 필요 없이 키 뱅크의 COMMIT/CLEAR 로 시작한다.
    // ---------------------------------------------------------------------
    logic [31:0] rekey_left_us;
    wire         key_event    = key_commit_pulse || key_clear_pulse;
    wire         rekey_active = (rekey_left_us != 32'd0);

    always_ff @(posedge aclk) begin
        if (!aresetn)
            rekey_left_us <= REKEY_US;      // reset 직후에도 유예 창을 준다
        else if (key_event)
            rekey_left_us <= cfg_rekey_us;
        else if (us_tick && rekey_active)
            rekey_left_us <= rekey_left_us - 32'd1;
    end

    // ---------------------------------------------------------------------
    // E2/E3/E4 판정 (파이프라인 S2 단)
    // ---------------------------------------------------------------------
    wire is_sof = (ck2_index == 16'd0);

    // E4 SESSION : 활성 세션키의 session_id 와 불일치, 또는 프레임 중간 변경.
    // 코어도 input_header_good 에서 같은 비교를 하지만 결과가 protocol_error
    // 한 비트로 뭉개지므로, 여기서 코드/컨텍스트/카운터를 따로 뽑는다.
    wire session_key_bad = active_key_valid &&
                           (ck2_session != active_session_id);
    wire session_ctx_bad = ctx_valid && !is_sof && (ck2_session != ctx_session);
    wire session_any_bad = session_key_bad || session_ctx_bad || !ck2_magic_ok;
    wire hit_session     = ck2_valid && session_any_bad && !rekey_active;

    // E2 REPLAY : 같은 프레임 내 index 재수신 또는 완료된 프레임의 재생
    wire same_ctx      = ctx_valid && (ck2_session == ctx_session) &&
                         (ck2_frame == ctx_frame);
    wire replay_packet = same_ctx && ck2_index_ok &&
                         ck2_seen_word[ck2_index[4:0]];
    wire replay_frame  = ctx_valid && hw_valid &&
                         (ck2_session == ctx_session) &&
                         (ck2_frame <= frame_highwater);
    wire hit_replay    = ck2_valid && (replay_packet || replay_frame);

    // E3 SEQUENCE : packet index 불연속 또는 직전 프레임 미완성
    wire seq_gap     = ctx_valid && !is_sof && (ck2_index != expect_index);
    wire frame_short = is_sof && ctx_valid &&
                       (accept_count != COUNT_BITS'(FRAME_PACKETS));
    wire hit_sequence = ck2_valid && (seq_gap || frame_short);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            chk_valid     <= 1'b0;
            ck2_valid     <= 1'b0;
            chk_session   <= 32'd0;
            chk_frame     <= 32'd0;
            chk_index     <= 16'd0;
            chk_flags     <= 16'd0;
            chk_index_ok  <= 1'b0;
            chk_magic_ok  <= 1'b0;
            ck2_magic_ok  <= 1'b0;
            ck2_session   <= 32'd0;
            ck2_frame     <= 32'd0;
            ck2_index     <= 16'd0;
            ck2_flags     <= 16'd0;
            ck2_index_ok  <= 1'b0;
            ck2_seen_word <= 32'd0;
        end else begin
            chk_valid    <= aad_beat;
            chk_session  <= in_session;
            chk_frame    <= in_frame;
            chk_index    <= in_index;
            chk_flags    <= in_flags;
            chk_index_ok <= (in_index < 16'(FRAME_PACKETS));
            chk_magic_ok <= (in_magic == MAGIC);

            ck2_magic_ok  <= chk_magic_ok;
            ck2_valid     <= chk_valid;
            ck2_session   <= chk_session;
            ck2_frame     <= chk_frame;
            ck2_index     <= chk_index;
            ck2_flags     <= chk_flags;
            ck2_index_ok  <= chk_index_ok;
            ck2_seen_word <= chk_index_ok ? seen_mem[chk_word_sel] : 32'd0;
        end
    end

    // ---------------------------------------------------------------------
    // E5 TIMEOUT : 링크 무입력 / 프레임 stall
    // 무입력 시간은 뺄셈이 아니라 전용 카운터로 센다.  time_us 와의 32 bit
    // 뺄셈 뒤에 다시 32 bit 비교를 이으면 CARRY4 가 두 줄로 직렬되어
    // 150 MHz 를 못 맞춘다.  비교 결과도 레지스터에 담아 끊는다.
    //
    // BTN3 종료 등으로 활성 키가 없는 구간은 영상이 끊기는 것이 정상이므로
    // 검출을 억제한다.  키는 살아 있는데 엔진이 아직 준비 안 된 경우
    // (키 확장 진행 중)는 info 의 no_key 비트로 구분해 보고한다.
    // ---------------------------------------------------------------------
    logic [31:0] idle_us;
    logic        timeout_reached;
    logic        timeout_latched;

    wire hit_timeout      = timeout_reached && !timeout_latched &&
                            active_key_valid && !rekey_active;
    wire timeout_in_frame = ctx_valid && (accept_count != '0) &&
                            (accept_count != COUNT_BITS'(FRAME_PACKETS));
    wire timeout_no_key   = !engine_key_ready;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            idle_us         <= 32'd0;
            timeout_reached <= 1'b0;
            timeout_latched <= 1'b0;
        end else begin
            if (input_fire)
                idle_us <= 32'd0;
            else if (us_tick && (idle_us != 32'hffff_ffff))
                idle_us <= idle_us + 32'd1;

            // input_fire 로 즉시 내려 카운터 리셋 직후의 오검출을 막는다.
            timeout_reached <= (idle_us >= cfg_timeout_us) && !input_fire;

            if (input_fire || key_event)
                timeout_latched <= 1'b0;
            else if (hit_timeout)
                timeout_latched <= 1'b1;
        end
    end

    // ---------------------------------------------------------------------
    // E1 TAG : 코어가 확정한 결과를 그대로 받는다
    // ---------------------------------------------------------------------
    wire hit_tag = auth_fail_pulse;

    // ---------------------------------------------------------------------
    // 컨텍스트 갱신
    // ---------------------------------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            ctx_valid       <= 1'b0;
            ctx_session     <= 32'd0;
            ctx_frame       <= 32'd0;
            expect_index    <= 16'd0;
            accept_count    <= '0;
            frame_error     <= 1'b0;
            hw_valid        <= 1'b0;
            frame_highwater <= 32'd0;
            for (int w = 0; w < SEEN_WORDS; w++)
                seen_mem[w] <= 32'd0;
            pkt_session     <= 32'd0;
            pkt_frame       <= 32'd0;
            pkt_index       <= 16'd0;
            pkt_encrypted   <= 1'b0;
            cmt_session     <= 32'd0;
            cmt_frame       <= 32'd0;
            cmt_index       <= 16'd0;
            cmt_encrypted   <= 1'b0;
        end else begin
            // 1) 인증 성공한 packet 만 replay bitmap 에 등록한다.
            //    인증 실패 packet 으로 bitmap 을 오염시키면 공격자가 정상
            //    packet 을 차단하는 DoS 경로가 된다.
            if (packet_accept) begin
                if (cmt_index < 16'(FRAME_PACKETS))
                    seen_mem[cmt_index[5 +: WORD_SEL_BITS]][cmt_index[4:0]]
                        <= 1'b1;
                accept_count <= accept_count + COUNT_BITS'(1);
            end
            if (auth_fail_pulse)
                frame_error <= 1'b1;

            // 2) EOF commit: 무결한 프레임만 high-water mark 를 올린다.
            if (frame_done_pulse && !frame_error && !auth_fail_pulse) begin
                hw_valid        <= 1'b1;
                frame_highwater <= ctx_frame;
            end

            // 3) record 경계에서 commit shadow 를 확정한다.
            if (packet_end_beat) begin
                cmt_session   <= pkt_session;
                cmt_frame     <= pkt_frame;
                cmt_index     <= pkt_index;
                cmt_encrypted <= pkt_encrypted;
            end

            // 4) AAD beat: 다음 packet 의 commit shadow 재료를 latch 한다.
            if (aad_beat) begin
                pkt_session   <= in_session;
                pkt_frame     <= in_frame;
                pkt_index     <= in_index;
                pkt_encrypted <= in_flags[0];
            end

            // 5) 판정 완료(S2) 시점에 프레임 컨텍스트를 갱신한다.
            //    seen_mem/accept_count 클리어가 1) 보다 뒤에 와야 SOF 가
            //    직전 packet 의 등록을 덮어쓴다.
            if (ck2_valid) begin
                if (is_sof) begin
                    ctx_valid    <= 1'b1;
                    ctx_session  <= ck2_session;
                    ctx_frame    <= ck2_frame;
                    expect_index <= 16'd1;
                    accept_count <= '0;
                    for (int w = 0; w < SEEN_WORDS; w++)
                        seen_mem[w] <= 32'd0;
                    frame_error  <= hit_session || hit_replay || hit_sequence;
                    // 세션이 바뀌면 이전 세션의 high-water 는 의미가 없다.
                    if (ck2_session != ctx_session)
                        hw_valid <= 1'b0;
                end else begin
                    expect_index <= ck2_index + 16'd1;
                    if (hit_session || hit_replay || hit_sequence)
                        frame_error <= 1'b1;
                end
            end

            // 6) 키 뱅크가 COMMIT/CLEAR 하면 모든 freshness 상태를 버린다.
            //    새 세션의 frame_id 는 이전 세션과 무관하므로 high-water 를
            //    유지하면 정상 프레임이 REPLAY 로 오검출된다.
            if (key_event) begin
                ctx_valid    <= 1'b0;
                hw_valid     <= 1'b0;
                accept_count <= '0;
                frame_error  <= 1'b0;
                for (int w = 0; w < SEEN_WORDS; w++)
                    seen_mem[w] <= 32'd0;
            end
        end
    end

    // ---------------------------------------------------------------------
    // 이벤트 후보 3종
    //   A: AAD beat 발원 (REPLAY / SEQUENCE / SESSION, 동시 성립 가능)
    //   B: commit 발원   (TAG)
    //   C: 타이머 발원   (TIMEOUT)
    // A 와 B 가 같은 clk 에 겹칠 수 있으므로 1-deep pending slot 을 둔다.
    // 두 이벤트의 최소 간격이 RECORD_WORDS clk 이라 반드시 배출된다.
    // ---------------------------------------------------------------------

    // S2 조합 판정.  seen bit 선택에서 이벤트 레지스터까지 한 clk 에 몰면
    // 7 logic level 이 되므로, A 계열은 S3 레지스터로 한 단 더 끊는다.
    wire [4:0] a2_flags = {1'b0,
                           hit_session  && cfg_error_enable[ERR_SESSION],
                           hit_sequence && cfg_error_enable[ERR_SEQUENCE],
                           hit_replay   && cfg_error_enable[ERR_REPLAY],
                           1'b0};

    // aux: 코드별로 가장 유용한 부가 정보 하나
    wire [15:0] a2_aux = hit_sequence ?
                             (frame_short ? 16'(accept_count)
                                          : expect_index) :
                         hit_session   ? active_session_id[15:0]
                                       : frame_highwater[15:0];

    // info: {10'b0, magic_bad, no_key, rekey_active, frame stall,
    //        encrypted, 예약}
    // magic_bad 는 코어가 이미 폐기하는 조건이지만 로그에서 "PCAM 패킷인데
    // 세션이 틀림" 과 "아예 다른 트래픽" 을 구분하는 유일한 단서다.
    wire [15:0] a2_info = {10'd0, !ck2_magic_ok, timeout_no_key, rekey_active,
                           1'b0, ck2_flags[0], 1'b0};

    logic [4:0]  a_flags;
    logic [31:0] a_session, a_frame, a_time;
    logic [15:0] a_index, a_aux, a_info, a_epoch;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            a_flags   <= 5'd0;
            a_session <= 32'd0;
            a_frame   <= 32'd0;
            a_index   <= 16'd0;
            a_aux     <= 16'd0;
            a_info    <= 16'd0;
            a_time    <= 32'd0;
            a_epoch   <= 16'd0;
        end else begin
            a_flags   <= a2_flags;
            a_session <= ck2_session;
            a_frame   <= ck2_frame;
            a_index   <= ck2_index;
            a_aux     <= a2_aux;
            a_info    <= a2_info;
            a_time    <= time_us;
            a_epoch   <= key_epoch;
        end
    end

    wire [4:0] b_flags = {4'b0, hit_tag && cfg_error_enable[ERR_TAG]};
    wire [4:0] c_flags = {hit_timeout && cfg_error_enable[ERR_TIMEOUT], 4'b0};

    wire a_fire = |a_flags;
    wire b_fire = |b_flags;
    wire c_fire = |c_flags;

    wire [15:0] c_aux = idle_us[25:10];   // 약 1 ms(1024 us) 단위

    wire [15:0] b_info = {11'd0, timeout_no_key, rekey_active, 1'b0,
                          cmt_encrypted, 1'b0};
    wire [15:0] c_info = {11'd0, timeout_no_key, rekey_active,
                          timeout_in_frame, 1'b0, 1'b0};


    logic        pend_valid;
    logic [4:0]  pend_flags;
    logic [31:0] pend_session, pend_frame;
    logic [15:0] pend_index, pend_aux, pend_info, pend_epoch;
    logic [31:0] pend_time;

    logic        sel_valid;
    logic [4:0]  sel_flags;
    logic [31:0] sel_session, sel_frame;
    logic [15:0] sel_index, sel_aux, sel_info, sel_epoch;
    logic [31:0] sel_time;

    always_comb begin
        sel_valid   = 1'b0;
        sel_flags   = 5'd0;
        sel_session = 32'd0;
        sel_frame   = 32'd0;
        sel_index   = 16'd0;
        sel_aux     = 16'd0;
        sel_info    = 16'd0;
        sel_epoch   = key_epoch;
        sel_time    = time_us;

        if (b_fire) begin
            sel_valid   = 1'b1;
            sel_flags   = b_flags;
            sel_session = cmt_session;
            sel_frame   = cmt_frame;
            sel_index   = cmt_index;
            sel_aux     = 16'd0;
            sel_info    = b_info;
        end else if (a_fire) begin
            sel_valid   = 1'b1;
            sel_flags   = a_flags;
            sel_session = a_session;
            sel_frame   = a_frame;
            sel_index   = a_index;
            sel_aux     = a_aux;
            sel_info    = a_info;
            sel_epoch   = a_epoch;
            sel_time    = a_time;
        end else if (c_fire) begin
            sel_valid   = 1'b1;
            sel_flags   = c_flags;
            sel_session = ctx_session;
            sel_frame   = ctx_frame;
            sel_index   = expect_index;
            sel_aux     = c_aux;
            sel_info    = c_info;
        end else if (pend_valid) begin
            sel_valid   = 1'b1;
            sel_flags   = pend_flags;
            sel_session = pend_session;
            sel_frame   = pend_frame;
            sel_index   = pend_index;
            sel_aux     = pend_aux;
            sel_info    = pend_info;
            sel_epoch   = pend_epoch;
            sel_time    = pend_time;
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            pend_valid   <= 1'b0;
            pend_flags   <= 5'd0;
            pend_session <= 32'd0;
            pend_frame   <= 32'd0;
            pend_index   <= 16'd0;
            pend_aux     <= 16'd0;
            pend_info    <= 16'd0;
            pend_epoch   <= 16'd0;
            pend_time    <= 32'd0;
            err_overflow <= 1'b0;
        end else begin
            if (a_fire && b_fire) begin
                if (pend_valid)
                    err_overflow <= 1'b1;
                pend_valid   <= 1'b1;
                pend_flags   <= a_flags;
                pend_session <= a_session;
                pend_frame   <= a_frame;
                pend_index   <= a_index;
                pend_aux     <= a_aux;
                pend_info    <= a_info;
                pend_epoch   <= a_epoch;
                pend_time    <= a_time;
            end else if (pend_valid && !b_fire && !a_fire && !c_fire) begin
                pend_valid <= 1'b0;
            end
            if (err_clear != 5'd0)
                err_overflow <= 1'b0;
        end
    end

    // ---------------------------------------------------------------------
    // 대표 코드 우선순위: TIMEOUT > SESSION > REPLAY > SEQUENCE > TAG
    // ---------------------------------------------------------------------
    function automatic logic [2:0] encode_code(input logic [4:0] flags);
        if (flags[ERR_TIMEOUT])       encode_code = CODE_TIMEOUT;
        else if (flags[ERR_SESSION])  encode_code = CODE_SESSION;
        else if (flags[ERR_REPLAY])   encode_code = CODE_REPLAY;
        else if (flags[ERR_SEQUENCE]) encode_code = CODE_SEQUENCE;
        else if (flags[ERR_TAG])      encode_code = CODE_TAG;
        else                          encode_code = CODE_NONE;
    endfunction

    logic evt_toggle;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            err_valid           <= 1'b0;
            err_flags           <= 5'd0;
            err_code            <= CODE_NONE;
            err_record          <= 192'd0;
            err_last_frame_id   <= 32'd0;
            err_last_session_id <= 32'd0;
            err_last_packet_id  <= 16'd0;
            evt_toggle          <= 1'b0;
        end else begin
            err_valid <= sel_valid;
            if (sel_valid) begin
                err_flags           <= sel_flags;
                err_code            <= encode_code(sel_flags);
                err_last_frame_id   <= sel_frame;
                err_last_session_id <= sel_session;
                err_last_packet_id  <= sel_index;
                evt_toggle          <= ~evt_toggle;
                err_record          <= {sel_time,
                                        sel_frame,
                                        sel_session,
                                        sel_index,
                                        sel_aux,
                                        sel_epoch,
                                        sel_info,
                                        24'd0,
                                        encode_code(sel_flags),
                                        sel_flags};
            end
        end
    end

    // ---------------------------------------------------------------------
    // sticky 와 카운터: 배출 여부와 무관하게 판정 시점에 누적한다.
    // ---------------------------------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            err_sticky         <= 5'd0;
            err_count_tag      <= 32'd0;
            err_count_replay   <= 32'd0;
            err_count_sequence <= 32'd0;
            err_count_session  <= 32'd0;
            err_count_timeout  <= 32'd0;
        end else begin
            if (b_flags[ERR_TAG])
                err_count_tag <= err_count_tag + 32'd1;
            if (a_flags[ERR_REPLAY])
                err_count_replay <= err_count_replay + 32'd1;
            if (a_flags[ERR_SEQUENCE])
                err_count_sequence <= err_count_sequence + 32'd1;
            if (a_flags[ERR_SESSION])
                err_count_session <= err_count_session + 32'd1;
            if (c_flags[ERR_TIMEOUT])
                err_count_timeout <= err_count_timeout + 32'd1;

            err_sticky <= (err_sticky |
                           {c_flags[ERR_TIMEOUT], a_flags[ERR_SESSION],
                            a_flags[ERR_SEQUENCE], a_flags[ERR_REPLAY],
                            b_flags[ERR_TAG]}) & ~err_clear;
        end
    end

    assign err_irq = |(err_sticky & cfg_error_enable);

    // ---------------------------------------------------------------------
    // GPIO 폴링용 요약 워드 (기존 frame_status 와 같은 toggle 방식)
    // ---------------------------------------------------------------------
    assign err_status = {evt_toggle,          // [31]    이벤트마다 반전
                         err_sticky,          // [30:26] 누적 5종
                         err_flags,           // [25:21] 최근 이벤트 묶음
                         err_code,            // [20:18] 최근 대표 코드
                         err_overflow,        // [17]
                         rekey_active,        // [16]
                         err_last_frame_id[15:0]};
endmodule
