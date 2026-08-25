`timescale 1ns/1ps

import gcm_protocol_pkg::*;

// System adapter for the replaceable 128-bit authenticated RX engine.
// The network-frame DMA supplies fixed AAD + 90 payload + TAG records.
module axis_gcm_rx_frame_processor #(
    parameter int unsigned RECORD_WORDS  = 92,
    parameter int unsigned FRAME_PACKETS = 1280,
    parameter int unsigned CLK_HZ        = 150_000_000,
    parameter logic [31:0] TIMEOUT_US    = 32'd100_000,
    parameter logic [31:0] REKEY_US      = 32'd50_000
) (
    input  logic         aclk,
    input  logic         aresetn,
    input  logic         sw3_decrypt,
    input  logic [31:0]  session_id,
    input  logic [255:0] session_key,
    input  logic         session_key_valid,
    input  logic         key_commit,
    input  logic         key_clear,
    input  logic [15:0]  key_epoch,

    input  logic [127:0] s_axis_tdata,
    input  logic [15:0]  s_axis_tkeep,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic         s_axis_tlast,

    output logic [127:0] m_axis_tdata,
    output logic [15:0]  m_axis_tkeep,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic         m_axis_tlast,

    output logic [31:0]  frame_status,
    output logic         key_ready,
    output logic         busy,

    // ---- 에러 검출기 제어/관측 (AXI GPIO 연결) ----------------------------
    // error_control:
    //   [4:0]   err_clear    sticky 해제 (rising edge)
    //   [7:5]   view_sel     error_status 에 실을 뷰 선택
    //   [12:8]  error_enable 코드별 검출 enable, 0 이면 기본 전체 enable
    input  logic [31:0]  error_control,
    output logic [31:0]  error_status,
    output logic         error_irq,

    // ---- 5종 에러 묶음 원본 (phase-2 AXI-Lite log FIFO 용) ----------------
    output logic         err_valid,
    output logic [4:0]   err_flags,
    output logic [2:0]   err_code,
    output logic [4:0]   err_sticky,
    output logic [191:0] err_record
);
    logic engine_m_user;
    logic auth_ok_pulse, auth_fail_pulse, bypass_pulse;
    logic frame_done_pulse, frame_ready_pulse, frame_fail;
    logic protocol_error;

    video_aes_gcm_rx_top #(.MAGIC(32'h5043414d)) u_engine (
        .aclk(aclk), .aresetn(aresetn), .sw3_decrypt(sw3_decrypt),
        .session_id(session_id),
        .session_key(session_key), .session_key_valid(session_key_valid),
        .key_commit(key_commit), .key_clear(key_clear),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tuser(engine_m_user), .m_axis_tlast(m_axis_tlast),
        .key_ready(key_ready), .busy(busy),
        .auth_ok_pulse(auth_ok_pulse),
        .auth_fail_pulse(auth_fail_pulse),
        .bypass_pulse(bypass_pulse),
        .frame_done_pulse(frame_done_pulse),
        .frame_ready_pulse(frame_ready_pulse),
        .frame_fail(frame_fail), .protocol_error(protocol_error)
    );

    // ---- error_control 디코드 --------------------------------------------
    logic [31:0] control_q;
    always_ff @(posedge aclk) begin
        if (!aresetn)
            control_q <= 32'd0;
        else
            control_q <= error_control;
    end

    wire [4:0] clear_pulse  = error_control[4:0] & ~control_q[4:0];
    wire [2:0] view_sel     = error_control[7:5];
    wire [4:0] error_enable = (error_control[12:8] == 5'd0) ?
                              5'b11111 : error_control[12:8];

    // ---- 에러 검출기 -------------------------------------------------------
    logic        det_overflow;
    logic [31:0] det_count_tag, det_count_replay, det_count_sequence;
    logic [31:0] det_count_session, det_count_timeout;
    logic [31:0] det_status, det_last_frame_id, det_last_session_id;
    logic [15:0] det_last_packet_id;

    gcm_rx_error_detector #(
        .RECORD_WORDS(RECORD_WORDS),
        .FRAME_PACKETS(FRAME_PACKETS),
        .CLK_HZ(CLK_HZ),
        .TIMEOUT_US(TIMEOUT_US),
        .REKEY_US(REKEY_US)
    ) u_error_detector (
        .aclk(aclk), .aresetn(aresetn),
        // 스트림 tap: 코어가 구동한 tready 를 그대로 관찰만 한다
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        // 코어 피드백 (TAG 에러 포함)
        .auth_ok_pulse(auth_ok_pulse),
        .auth_fail_pulse(auth_fail_pulse),
        .bypass_pulse(bypass_pulse),
        .frame_done_pulse(frame_done_pulse),
        .engine_key_ready(key_ready),
        // 세션키 레지스터 뱅크
        .active_session_id(session_id),
        .active_key_valid(session_key_valid),
        .key_commit_pulse(key_commit),
        .key_clear_pulse(key_clear),
        .key_epoch(key_epoch),
        // 설정
        .cfg_timeout_us(TIMEOUT_US),
        .cfg_rekey_us(REKEY_US),
        .cfg_error_enable(error_enable),
        .err_clear(clear_pulse),
        // 5종 묶음 출력
        .err_valid(err_valid),
        .err_flags(err_flags),
        .err_code(err_code),
        .err_sticky(err_sticky),
        .err_overflow(det_overflow),
        .err_record(err_record),
        .err_count_tag(det_count_tag),
        .err_count_replay(det_count_replay),
        .err_count_sequence(det_count_sequence),
        .err_count_session(det_count_session),
        .err_count_timeout(det_count_timeout),
        .err_status(det_status),
        .err_last_frame_id(det_last_frame_id),
        .err_last_session_id(det_last_session_id),
        .err_last_packet_id(det_last_packet_id),
        .err_irq(error_irq)
    );

    // AXI GPIO 한 채널로 전체 상태를 보기 위한 뷰 mux.
    always_comb begin
        unique case (view_sel)
            3'd0:    error_status = det_status;
            3'd1:    error_status = det_count_tag;
            3'd2:    error_status = det_count_replay;
            3'd3:    error_status = det_count_sequence;
            3'd4:    error_status = det_count_session;
            3'd5:    error_status = det_count_timeout;
            3'd6:    error_status = {det_last_frame_id[15:0],
                                     det_last_packet_id};
            default: error_status = det_last_session_id;
        endcase
    end

    // Track the deployed 92-block record boundary only for software status.
    // Cryptographic parsing and validation remain inside the engine.
    logic [6:0] record_word;
    logic [31:0] active_frame_id;
    logic active_frame_mode;
    logic sw_meta, sw_sync;
    wire input_fire = s_axis_tvalid && s_axis_tready;
    wire [127:0] input_gcm = axis_to_gcm(s_axis_tdata);
    wire [15:0] input_packet_index = input_gcm[31:16];

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            sw_meta <= 1'b0;
            sw_sync <= 1'b0;
            record_word <= 7'd0;
            active_frame_id <= 32'd0;
            active_frame_mode <= 1'b0;
        end else begin
            sw_meta <= sw3_decrypt;
            sw_sync <= sw_meta;
            if (input_fire) begin
                if ((record_word == 7'd0) &&
                    (input_packet_index == 16'd0)) begin
                    active_frame_id <= input_gcm[63:32];
                    active_frame_mode <= sw_sync;
                end
                if (record_word == 7'd91)
                    record_word <= 7'd0;
                else
                    record_word <= record_word + 7'd1;
            end
        end
    end

    // Delay publication one clock so all final TAG/authentication state from
    // the engine is visible in the software-facing status word.
    logic complete_toggle;
    logic done_pending;
    logic ready_pending;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            complete_toggle <= 1'b0;
            done_pending <= 1'b0;
            ready_pending <= 1'b0;
            frame_status <= 32'd0;
        end else begin
            if (frame_done_pulse) begin
                done_pending <= 1'b1;
                ready_pending <= frame_ready_pulse;
            end else if (done_pending) begin
                complete_toggle <= !complete_toggle;
                frame_status <= {!complete_toggle, active_frame_mode,
                                 !ready_pending, 13'd0,
                                 active_frame_id[15:0]};
                done_pending <= 1'b0;
            end
        end
    end

    wire unused = &{1'b0, engine_m_user,
                    frame_fail, protocol_error, det_overflow};
endmodule

