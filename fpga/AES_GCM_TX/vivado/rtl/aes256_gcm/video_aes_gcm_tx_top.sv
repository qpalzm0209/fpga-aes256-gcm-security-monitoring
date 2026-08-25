`timescale 1ns/1ps

import gcm_protocol_pkg::*;

module video_aes_gcm_tx_top #(
    parameter logic [31:0] MAGIC = GCM_MAGIC
) (
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
    input  logic         s_axis_tuser,
    input  logic         s_axis_tlast,

    output logic [127:0] m_axis_tdata,
    output logic [15:0]  m_axis_tkeep,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic         m_axis_tuser,
    output logic         m_axis_tlast,

    // Two 128-bit transfers per packet: exact AAD followed by TAG.
    output logic [127:0] m_meta_tdata,
    output logic [15:0]  m_meta_tkeep,
    output logic         m_meta_tvalid,
    input  logic         m_meta_tready,
    output logic         m_meta_tlast,

    output logic [31:0]  status_frame_id,
    output logic [15:0]  status_packet_index,
    output logic [31:0]  debug_status,
    output logic         key_ready,
    output logic         busy,
    output logic         protocol_error
);
  typedef enum logic [3:0] {
    ST_KEY_START,
    ST_KEY_WAIT,
    ST_H_START,
    ST_H_WAIT,
    ST_IDLE,
    ST_PACKET_LAUNCH,
    ST_ENC_SETUP_WAIT,
    ST_ENC_PAYLOAD,
    ST_ENC_LAST_WAIT,
    ST_ENC_LEN_WAIT,
    ST_BYPASS
  } state_t;

  state_t state;

  (* ASYNC_REG = "TRUE" *) logic sw_meta;
  (* ASYNC_REG = "TRUE" *) logic sw_sync;
  logic frame_mode;
  logic packet_mode;
  // Session-key changes are frame transactions, not packet transactions.
  // Keep busy asserted across all 1280 packets, including the idle bubbles
  // between records.  The final frame boundary is opened only after both the
  // payload output and the two-beat metadata record have drained.
  logic frame_active;
  logic frame_drain_pending;
  logic frame_boundary_guard;

  logic [31:0] frame_id;
  logic [15:0] packet_index;
  logic [6:0]  payload_index;
  logic [127:0] aad_reg;
  logic [95:0]  nonce_reg;

  logic          key_start;
  logic          key_busy;
  logic          round_keys_valid;
  wire [1919:0]  round_keys;

  logic          data_start;
  logic [127:0]  data_in;
  logic          data_busy;
  logic          data_done;
  logic [127:0]  data_out;

  logic          aux_start;
  logic [127:0]  aux_in;
  logic          aux_busy;
  logic          aux_done;
  logic [127:0]  aux_out;

  logic          ghash_start;
  logic [127:0]  ghash_data;
  logic [127:0]  ghash_y_in;
  logic          ghash_ready;
  logic          ghash_busy;
  logic          ghash_done;
  logic [127:0]  ghash_result;

  logic [127:0] hash_subkey;
  logic         crypto_ready;
  logic [127:0] ghash_y_reg;
  logic [127:0] tag_mask_reg;
  logic         tag_mask_valid;
  logic [127:0] keystream_reg;
  logic         keystream_valid;
  logic         setup_hash_valid;
  logic         length_hash_valid;

  logic         out_valid;
  logic [127:0] out_data;
  logic [15:0]  out_keep;
  logic         out_user;
  logic         out_last;

  logic         meta_pending;
  logic         meta_phase;
  logic [127:0] meta_aad;
  logic [127:0] meta_tag;

  wire selected_mode = (packet_index == 16'd0) ? sw_sync : frame_mode;
  wire out_can_load = !out_valid || m_axis_tready;
  wire [127:0] current_keystream = data_done ? data_out : keystream_reg;
  wire [127:0] current_ghash_y = ghash_done ? ghash_result : ghash_y_reg;
  wire setup_complete = (tag_mask_valid || aux_done) &&
                        (keystream_valid || data_done) &&
                        (setup_hash_valid || ghash_done);
  wire encrypted_window = (state == ST_ENC_PAYLOAD) ||
                          ((state == ST_ENC_SETUP_WAIT) && setup_complete);
  wire encrypted_fire = encrypted_window && s_axis_tvalid &&
                        out_can_load && ghash_ready &&
                        (keystream_valid || data_done);
  wire metadata_pop = meta_pending && meta_phase &&
                      m_meta_tready;
  wire metadata_free = !meta_pending || metadata_pop;
  wire bypass_fire = (state == ST_BYPASS) && s_axis_tvalid &&
                     out_can_load &&
                     ((payload_index != 7'd89) || metadata_free);
  // GHASH completion is a one-cycle pulse.  The metadata writer can still be
  // backpressuring the previous packet on that cycle, so retain completion
  // until the writer accepts the new AAD/TAG pair.
  wire encrypted_commit = (state == ST_ENC_LEN_WAIT) &&
                          (ghash_done || length_hash_valid) && metadata_free;
  wire bypass_commit = bypass_fire && (payload_index == 7'd89);
  wire packet_commit = encrypted_commit || bypass_commit;
  wire frame_drained = frame_drain_pending && (state == ST_IDLE) &&
                       !out_valid && !meta_pending;

  aes256_key_expansion u_key_expansion (
      .clk(aclk), .rst_n(aresetn), .start(key_start), .key_in(session_key),
      .busy(key_busy), .round_keys_valid(round_keys_valid),
      .round_keys(round_keys)
  );

  aes256_iterative_core u_data_aes (
      .clk(aclk), .rst_n(aresetn), .start(data_start), .data_in(data_in),
      .round_keys(round_keys), .round_keys_valid(round_keys_valid),
      .busy(data_busy), .done(data_done), .data_out(data_out)
  );

  aes256_iterative_core u_aux_aes (
      .clk(aclk), .rst_n(aresetn), .start(aux_start), .data_in(aux_in),
      .round_keys(round_keys), .round_keys_valid(round_keys_valid),
      .busy(aux_busy), .done(aux_done), .data_out(aux_out)
  );

  ghash_mul16 u_ghash (
      .clk(aclk), .rst_n(aresetn), .start(ghash_start),
      .h(hash_subkey), .data_in(ghash_data), .y_in(ghash_y_in),
      .ready(ghash_ready), .busy(ghash_busy), .done(ghash_done),
      .result(ghash_result)
  );

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      sw_meta <= 1'b0;
      sw_sync <= 1'b0;
    end else begin
      sw_meta <= sw3_encrypt;
      sw_sync <= sw_meta;
    end
  end

  always_comb begin
    key_start   = (state == ST_KEY_START);
    data_start  = 1'b0;
    data_in     = 128'h0;
    aux_start   = 1'b0;
    aux_in      = 128'h0;
    ghash_start = 1'b0;
    ghash_data  = 128'h0;
    ghash_y_in  = current_ghash_y;

    if (state == ST_H_START) begin
      aux_start = 1'b1;
      aux_in    = 128'h0;
    end else if ((state == ST_PACKET_LAUNCH) && packet_mode) begin
      aux_start   = 1'b1;
      aux_in      = {nonce_reg, 32'd1};
      data_start  = 1'b1;
      data_in     = {nonce_reg, 32'd2};
      ghash_start = 1'b1;
      ghash_data  = aad_reg;
      ghash_y_in  = 128'h0;
    end else begin
      if (encrypted_fire) begin
        ghash_start = 1'b1;
        ghash_data  = axis_to_gcm(s_axis_tdata) ^ current_keystream;
        ghash_y_in  = current_ghash_y;
        if (payload_index != 7'd89) begin
          data_start = 1'b1;
          data_in    = {nonce_reg, 32'd3 + payload_index};
        end
      end else if ((state == ST_ENC_LAST_WAIT) && ghash_done) begin
        ghash_start = 1'b1;
        ghash_data  = GCM_LENGTH_BLOCK;
        ghash_y_in  = ghash_result;
      end
    end
  end

  always_comb begin
    s_axis_tready = 1'b0;
    if (encrypted_window)
      s_axis_tready = out_can_load && ghash_ready &&
                      (keystream_valid || data_done);
    else if (state == ST_BYPASS)
      s_axis_tready = out_can_load &&
                      ((payload_index != 7'd89) || metadata_free);
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      state             <= ST_IDLE;
      frame_mode        <= 1'b0;
      packet_mode       <= 1'b0;
      frame_active      <= 1'b0;
      frame_drain_pending <= 1'b0;
      frame_boundary_guard <= 1'b0;
      frame_id          <= 32'd0;
      packet_index      <= 16'd0;
      payload_index     <= 7'd0;
      aad_reg           <= 128'h0;
      nonce_reg         <= 96'h0;
      hash_subkey       <= 128'h0;
      crypto_ready      <= 1'b0;
      ghash_y_reg       <= 128'h0;
      tag_mask_reg      <= 128'h0;
      tag_mask_valid    <= 1'b0;
      keystream_reg     <= 128'h0;
      keystream_valid   <= 1'b0;
      setup_hash_valid  <= 1'b0;
      length_hash_valid <= 1'b0;
      protocol_error    <= 1'b0;
    end else begin
      // One deliberately idle clock follows a completed frame drain.  This
      // gives the session register bank a full engine_busy-low cycle in which
      // to raise key_clear/key_commit before a new frame can be admitted.
      if (frame_boundary_guard)
        frame_boundary_guard <= 1'b0;
      if (frame_drained) begin
        frame_active         <= 1'b0;
        frame_drain_pending  <= 1'b0;
        frame_boundary_guard <= 1'b1;
      end

      if (data_done) begin
        keystream_reg   <= data_out;
        keystream_valid <= 1'b1;
      end
      if (aux_done && (state != ST_H_WAIT)) begin
        tag_mask_reg   <= aux_out;
        tag_mask_valid <= 1'b1;
      end
      if (ghash_done) ghash_y_reg <= ghash_result;
      // AAD GHASH completion can occur while the previous packet's final
      // AXIS beat is still backpressured.  Retain it until payload beat 0 is
      // actually accepted; otherwise the setup state waits forever for a
      // one-cycle done pulse that has already passed.
      if ((state == ST_ENC_SETUP_WAIT) && ghash_done)
        setup_hash_valid <= 1'b1;
      if ((state == ST_ENC_LEN_WAIT) && ghash_done)
        length_hash_valid <= 1'b1;
      if (encrypted_commit)
        length_hash_valid <= 1'b0;

      if (key_clear && (state == ST_IDLE)) begin
        crypto_ready   <= 1'b0;
        hash_subkey    <= 128'h0;
        tag_mask_valid <= 1'b0;
        keystream_valid <= 1'b0;
      // The session register bank intentionally survives a video-runtime
      // reset. Re-expand its already-active key when this engine has been
      // reset after the one-cycle key_commit pulse, so Linux/camera startup
      // order can never leave the payload engine on stale round keys.
      end else if ((key_commit || (session_key_valid && !crypto_ready)) &&
                   session_key_valid &&
                   (state == ST_IDLE) && !out_valid && !meta_pending) begin
        crypto_ready   <= 1'b0;
        hash_subkey    <= 128'h0;
        tag_mask_valid <= 1'b0;
        keystream_valid <= 1'b0;
        state          <= ST_KEY_START;
      end else unique case (state)
        ST_KEY_START: state <= ST_KEY_WAIT;
        ST_KEY_WAIT:  if (round_keys_valid) state <= ST_H_START;
        ST_H_START:   state <= ST_H_WAIT;
        ST_H_WAIT: begin
          if (aux_done) begin
            hash_subkey <= aux_out;
            crypto_ready <= 1'b1;
            state       <= ST_IDLE;
          end
        end
        ST_IDLE: begin
          if (!frame_drain_pending && !frame_boundary_guard &&
              s_axis_tvalid && metadata_free &&
              (!selected_mode || (crypto_ready && session_key_valid))) begin
            packet_mode <= selected_mode;
            if (packet_index == 16'd0) begin
              frame_mode   <= sw_sync;
              frame_active <= 1'b1;
            end
            aad_reg <= make_aad(
                MAGIC, session_id, frame_id, packet_index,
                make_flags(selected_mode,
                           packet_index == 16'd0,
                           packet_index == LAST_PACKET_INDEX));
            nonce_reg <= make_nonce(session_id, frame_id, packet_index);
            payload_index   <= 7'd0;
            tag_mask_valid  <= 1'b0;
            keystream_valid <= 1'b0;
            state <= ST_PACKET_LAUNCH;
          end
        end
        ST_PACKET_LAUNCH: begin
          setup_hash_valid  <= 1'b0;
          length_hash_valid <= 1'b0;
          if (packet_mode) begin
            ghash_y_reg <= 128'h0;
            state <= ST_ENC_SETUP_WAIT;
          end else begin
            state <= ST_BYPASS;
          end
        end
        ST_ENC_SETUP_WAIT, ST_ENC_PAYLOAD: begin
          if (encrypted_fire) begin
            keystream_valid <= 1'b0;
            setup_hash_valid <= 1'b0;
            if ((s_axis_tkeep != 16'hffff) ||
                (s_axis_tuser != ((packet_index == 16'd0) &&
                                  (payload_index == 7'd0))) ||
                (s_axis_tlast != ((payload_index == 7'd89) &&
                                  (packet_index == LAST_PACKET_INDEX))))
              protocol_error <= 1'b1;
            if (payload_index == 7'd89) begin
              state <= ST_ENC_LAST_WAIT;
            end else begin
              payload_index <= payload_index + 7'd1;
              state <= ST_ENC_PAYLOAD;
            end
          end
        end
        ST_ENC_LAST_WAIT: begin
          if (ghash_done) state <= ST_ENC_LEN_WAIT;
        end
        ST_ENC_LEN_WAIT: begin
          if (encrypted_commit) state <= ST_IDLE;
        end
        ST_BYPASS: begin
          if (bypass_fire) begin
            if ((s_axis_tkeep != 16'hffff) ||
                (s_axis_tuser != ((packet_index == 16'd0) &&
                                  (payload_index == 7'd0))) ||
                (s_axis_tlast != ((payload_index == 7'd89) &&
                                  (packet_index == LAST_PACKET_INDEX))))
              protocol_error <= 1'b1;
            if (payload_index == 7'd89)
              state <= ST_IDLE;
            else
              payload_index <= payload_index + 7'd1;
          end
        end
        default: state <= ST_KEY_START;
      endcase

      if (packet_commit) begin
        if (packet_index == LAST_PACKET_INDEX) begin
          packet_index <= 16'd0;
          frame_id     <= frame_id + 32'd1;
          frame_drain_pending <= 1'b1;
        end else begin
          packet_index <= packet_index + 16'd1;
        end
      end
    end
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      out_valid <= 1'b0;
      out_data  <= 128'h0;
      out_keep  <= 16'h0;
      out_user  <= 1'b0;
      out_last  <= 1'b0;
    end else begin
      if (out_valid && m_axis_tready) out_valid <= 1'b0;
      if (encrypted_fire || bypass_fire) begin
        out_valid <= 1'b1;
        out_data  <= encrypted_fire ?
                     gcm_to_axis(axis_to_gcm(s_axis_tdata) ^
                                 current_keystream) : s_axis_tdata;
        out_keep  <= s_axis_tkeep;
        out_user  <= s_axis_tuser;
        out_last  <= s_axis_tlast;
      end
    end
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      meta_pending <= 1'b0;
      meta_phase   <= 1'b0;
      meta_aad     <= 128'h0;
      meta_tag     <= 128'h0;
    end else begin
      if (meta_pending && m_meta_tready) begin
        if (meta_phase) begin
          meta_pending <= 1'b0;
          meta_phase   <= 1'b0;
        end else begin
          meta_phase <= 1'b1;
        end
      end
      if (packet_commit) begin
        meta_pending <= 1'b1;
        meta_phase   <= 1'b0;
        meta_aad     <= gcm_to_axis(aad_reg);
        meta_tag     <= encrypted_commit ?
                        gcm_to_axis(tag_mask_reg ^ current_ghash_y) : 128'h0;
      end
    end
  end

  assign m_axis_tdata  = out_data;
  assign m_axis_tkeep  = out_keep;
  assign m_axis_tvalid = out_valid;
  assign m_axis_tuser  = out_user;
  assign m_axis_tlast  = out_last;

  assign m_meta_tdata  = meta_phase ? meta_tag : meta_aad;
  assign m_meta_tkeep  = 16'hffff;
  assign m_meta_tvalid = meta_pending;
  assign m_meta_tlast  = meta_phase;

  assign status_frame_id     = frame_id;
  assign status_packet_index = packet_index;
  assign debug_status = {state, packet_index[10:0], payload_index,
                         meta_pending, meta_phase, out_valid,
                         setup_hash_valid, tag_mask_valid, keystream_valid,
                         length_hash_valid, ghash_busy, data_busy, aux_busy};
  assign key_ready = crypto_ready && session_key_valid;
  assign busy = frame_active || (state != ST_IDLE) || out_valid ||
                meta_pending;

  wire unused_status = &{1'b0, key_busy, data_busy, aux_busy, ghash_busy};
endmodule
