`timescale 1ns/1ps

// Raw-frame DMA adapter for the replaceable 128-bit AES-256-GCM engine.
// Unlike a Video Frame Buffer IP, this path is byte-transparent: DDR bytes
// presented by MM2S are the exact bytes authenticated and written by S2MM.
module axis_gcm_tx_frame_processor (
    input  logic         aclk,
    input  logic         aresetn,
    input  logic         sw3_encrypt,
    input  logic [31:0]  session_id,
    input  logic [255:0] session_key,
    input  logic         session_key_valid,
    input  logic         key_commit,
    input  logic         key_clear,

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

    output logic [127:0] m_meta_tdata,
    output logic [15:0]  m_meta_tkeep,
    output logic         m_meta_tvalid,
    input  logic         m_meta_tready,
    output logic         m_meta_tlast,

    output logic [31:0]  active_frame_id,
    output logic         active_frame_encrypted,
    output logic [31:0]  debug_status,
    output logic         key_ready,
    output logic         busy,
    output logic         protocol_error
);
    localparam logic [16:0] LAST_BLOCK = 17'd115199;

    logic sw_meta, sw_sync;
    logic [16:0] input_block;
    logic [16:0] output_block;
    logic engine_s_ready;
    logic [127:0] engine_m_data;
    logic [15:0] engine_m_keep;
    logic engine_m_valid, engine_m_user, engine_m_last;
    logic [127:0] engine_meta_data;
    logic [15:0] engine_meta_keep;
    logic engine_meta_valid, engine_meta_last;
    logic [31:0] engine_frame_id;
    logic engine_protocol_error;
    logic engine_key_ready;
    logic engine_busy;
    logic [15:0] meta_packet_index;

    wire input_fire = s_axis_tvalid && engine_s_ready;
    wire output_fire = engine_m_valid && m_axis_tready;
    wire expected_dma_last = (input_block == LAST_BLOCK);
    wire injected_frame_last = expected_dma_last;
    wire engine_meta_fire = engine_meta_valid && m_meta_tready;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            sw_meta <= 1'b0;
            sw_sync <= 1'b0;
            input_block <= 17'd0;
            output_block <= 17'd0;
            active_frame_id <= 32'd0;
            active_frame_encrypted <= 1'b0;
            protocol_error <= 1'b0;
            meta_packet_index <= 16'd0;
        end else begin
            sw_meta <= sw3_encrypt;
            sw_sync <= sw_meta;
            if (input_fire) begin
                if (input_block == 17'd0) begin
                    active_frame_id <= engine_frame_id;
                    active_frame_encrypted <= sw_sync;
                end
                if (s_axis_tkeep != 16'hffff ||
                    s_axis_tlast != expected_dma_last)
                    protocol_error <= 1'b1;
                if (expected_dma_last) begin
                    input_block <= 17'd0;
                end else begin
                    input_block <= input_block + 17'd1;
                end
            end
            if (output_fire)
                output_block <= (output_block == LAST_BLOCK) ?
                                17'd0 : output_block + 17'd1;
            if (engine_meta_fire && engine_meta_last)
                meta_packet_index <= (meta_packet_index == 16'd1279) ?
                                     16'd0 : meta_packet_index + 16'd1;
            if (engine_protocol_error)
                protocol_error <= 1'b1;
        end
    end

    video_aes_gcm_tx_top u_engine (
        .aclk(aclk), .aresetn(aresetn), .sw3_encrypt(sw3_encrypt),
        .session_id(session_id), .session_key(session_key),
        .session_key_valid(session_key_valid), .key_commit(key_commit),
        .key_clear(key_clear),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(engine_s_ready),
        .s_axis_tuser(input_block == 17'd0),
        .s_axis_tlast(injected_frame_last),
        .m_axis_tdata(engine_m_data), .m_axis_tkeep(engine_m_keep),
        .m_axis_tvalid(engine_m_valid), .m_axis_tready(m_axis_tready),
        .m_axis_tuser(engine_m_user), .m_axis_tlast(engine_m_last),
        .m_meta_tdata(engine_meta_data),
        .m_meta_tkeep(engine_meta_keep),
        .m_meta_tvalid(engine_meta_valid),
        .m_meta_tready(m_meta_tready),
        .m_meta_tlast(engine_meta_last),
        .status_frame_id(engine_frame_id), .status_packet_index(),
        .debug_status(debug_status),
        .key_ready(engine_key_ready), .busy(engine_busy),
        .protocol_error(engine_protocol_error)
    );

    assign s_axis_tready = engine_s_ready;
    assign m_axis_tdata = engine_m_data;
    assign m_axis_tkeep = engine_m_keep;
    assign m_axis_tvalid = engine_m_valid;
    assign m_axis_tlast = engine_m_valid && (output_block == LAST_BLOCK);
    assign m_meta_tdata = engine_meta_data;
    assign m_meta_tkeep = engine_meta_keep;
    assign m_meta_tvalid = engine_meta_valid;
    assign m_meta_tlast = engine_meta_last &&
                              (meta_packet_index == 16'd1279);
    assign key_ready = engine_key_ready;
    assign busy = engine_busy;

    wire unused = &{1'b0, engine_m_user, engine_m_last};
endmodule
