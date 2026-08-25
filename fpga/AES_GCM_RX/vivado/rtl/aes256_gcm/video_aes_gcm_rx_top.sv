`timescale 1ns/1ps

import gcm_protocol_pkg::*;

module video_aes_gcm_rx_top #(
    parameter logic [31:0] MAGIC = GCM_MAGIC
) (
    input  logic         aclk,
    input  logic         aresetn,
    input  logic         sw3_decrypt,
    input  logic [31:0]  session_id,
    input  logic [255:0] session_key,
    input  logic         session_key_valid,
    input  logic         key_commit,
    input  logic         key_clear,

    // AXI DMA MM2S stream: 1280 records/frame, 92 transfers/record.
    input  logic [127:0] s_axis_tdata,
    input  logic [15:0]  s_axis_tkeep,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic         s_axis_tlast,

    // AXI DMA S2MM stream: payload only, 1,843,200 bytes/frame.
    output logic [127:0] m_axis_tdata,
    output logic [15:0]  m_axis_tkeep,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic         m_axis_tuser,
    output logic         m_axis_tlast,

    output logic         key_ready,
    output logic         busy,
    output logic         auth_ok_pulse,
    output logic         auth_fail_pulse,
    output logic         bypass_pulse,
    output logic         frame_done_pulse,
    output logic         frame_ready_pulse,
    output logic         frame_fail,
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
    ST_ENC_TAG,
    ST_BYPASS_PAYLOAD,
    ST_BYPASS_TAG,
    ST_DROP_PAYLOAD,
    ST_DROP_TAG
  } state_t;

  state_t state;

  (* ASYNC_REG = "TRUE" *) logic sw_meta;
  (* ASYNC_REG = "TRUE" *) logic sw_sync;
  logic frame_mode;
  logic packet_mode;
  // A session key belongs to one complete 1280-record video frame.  This
  // state keeps engine_busy high across packet-to-packet idle gaps and until
  // the authenticated final payload has completely drained from both banks.
  logic frame_active;
  logic frame_drain_pending;
  logic frame_boundary_guard;
  logic header_valid;
  logic [6:0] payload_index;
  logic [31:0] packet_session_id;
  logic [31:0] packet_frame_id;
  logic [15:0] packet_index;
  logic [15:0] packet_flags;
  logic        frame_context_valid;
  logic [31:0] frame_session_id;
  logic [31:0] frame_context_id;
  logic [15:0] expected_packet_index;
  logic        frame_tx_encrypted;
  logic [127:0] aad_reg;
  logic [95:0] nonce_reg;

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

  logic write_bank;
  logic read_bank;
  logic [1:0] bank_ready;
  logic [1:0] bank_zero;
  logic [1:0] bank_sof;
  logic [1:0] bank_eof;

  logic         out_valid;
  logic [6:0]   out_index;
  logic [127:0] out_data;
  logic         read_pending;
  logic         read_pending_zero;
  logic         packet_mem_read_en;
  logic [7:0]   packet_mem_read_addr;
  logic [127:0] packet_mem_read_data;

  wire [127:0] input_gcm = axis_to_gcm(s_axis_tdata);
  wire [31:0] input_magic = input_gcm[127:96];
  wire [31:0] input_session_id = input_gcm[95:64];
  wire [31:0] input_frame_id = input_gcm[63:32];
  wire [15:0] input_packet_index = input_gcm[31:16];
  wire [15:0] input_flags = input_gcm[15:0];
  wire input_sequence_good = (input_packet_index == 16'd0) ||
                             (frame_context_valid &&
                              (input_session_id == frame_session_id) &&
                              (input_frame_id == frame_context_id) &&
                              (input_flags[0] == frame_tx_encrypted) &&
                              (input_packet_index == expected_packet_index));
  wire input_header_good = (input_magic == MAGIC) &&
                           (input_session_id == session_id) &&
                           (input_packet_index <= LAST_PACKET_INDEX) &&
                           (input_flags[15:12] == GCM_VERSION) &&
                           (input_flags[11:3] == 9'b0) &&
                           (input_flags[1] == (input_packet_index == 16'd0)) &&
                           (input_flags[2] ==
                            (input_packet_index == LAST_PACKET_INDEX)) &&
                           input_sequence_good &&
                           (s_axis_tkeep == 16'hffff) && !s_axis_tlast;
  wire selected_mode = (input_packet_index == 16'd0) ?
                       sw_sync : frame_mode;

  wire [127:0] current_keystream = data_done ? data_out : keystream_reg;
  wire [127:0] current_ghash_y = ghash_done ? ghash_result : ghash_y_reg;
  wire setup_complete = (tag_mask_valid || aux_done) &&
                        (keystream_valid || data_done) && ghash_done;
  wire encrypted_window = (state == ST_ENC_PAYLOAD) ||
                          ((state == ST_ENC_SETUP_WAIT) && setup_complete);
  wire encrypted_fire = encrypted_window && s_axis_tvalid &&
                        ghash_ready && (keystream_valid || data_done);
  wire bypass_fire = (state == ST_BYPASS_PAYLOAD) && s_axis_tvalid;
  wire drop_fire = (state == ST_DROP_PAYLOAD) && s_axis_tvalid;
  wire enc_tag_fire = (state == ST_ENC_TAG) && s_axis_tvalid;
  wire bypass_tag_fire = (state == ST_BYPASS_TAG) && s_axis_tvalid;
  wire drop_tag_fire = (state == ST_DROP_TAG) && s_axis_tvalid;
  wire tag_matches = (input_gcm == (tag_mask_reg ^ ghash_y_reg));
  wire packet_commit = enc_tag_fire || bypass_tag_fire || drop_tag_fire;
  wire commit_sof = (packet_index == 16'd0);
  wire commit_eof = (packet_index == LAST_PACKET_INDEX);
  wire tag_format_good = (s_axis_tkeep == 16'hffff) &&
                         (s_axis_tlast == commit_eof);
  wire commit_zero = drop_tag_fire || !header_valid || !tag_format_good ||
                     (enc_tag_fire && !tag_matches);
  wire output_release = out_valid && m_axis_tready &&
                        (out_index == 7'd89);
  wire packet_mem_write = encrypted_fire || bypass_fire;
  wire [7:0] packet_mem_write_addr =
      (write_bank ? 8'd90 : 8'd0) + payload_index;
  wire [127:0] packet_mem_write_data = encrypted_fire ?
      gcm_to_axis(input_gcm ^ current_keystream) : s_axis_tdata;
  wire start_packet_read = !out_valid && !read_pending &&
                           bank_ready[read_bank];
  wire advance_packet_read = out_valid && m_axis_tready &&
                             (out_index != 7'd89);
  wire frame_drained = frame_drain_pending && (state == ST_IDLE) &&
                       (bank_ready == 2'b00) && !out_valid &&
                       !read_pending;

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

  packet_buffer_bram u_packet_buffer (
      .clk(aclk), .rst_n(aresetn), .wr_en(packet_mem_write),
      .wr_addr(packet_mem_write_addr), .wr_data(packet_mem_write_data),
      .rd_en(packet_mem_read_en), .rd_addr(packet_mem_read_addr),
      .rd_data(packet_mem_read_data)
  );

  always_comb begin
    packet_mem_read_en = start_packet_read || advance_packet_read;
    packet_mem_read_addr = (read_bank ? 8'd90 : 8'd0) +
                           (start_packet_read ? 8'd0 :
                            {1'b0, out_index + 7'd1});
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      sw_meta <= 1'b0;
      sw_sync <= 1'b0;
    end else begin
      sw_meta <= sw3_decrypt;
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
    end else if (state == ST_PACKET_LAUNCH) begin
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
        ghash_data  = input_gcm;
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
    unique case (state)
      ST_IDLE: s_axis_tready = !frame_drain_pending &&
                               !frame_boundary_guard &&
                               !bank_ready[write_bank] &&
                               (!selected_mode || key_ready);
      ST_ENC_SETUP_WAIT, ST_ENC_PAYLOAD:
        s_axis_tready = encrypted_window && ghash_ready &&
                        (keystream_valid || data_done);
      ST_ENC_TAG, ST_BYPASS_PAYLOAD, ST_BYPASS_TAG,
      ST_DROP_PAYLOAD, ST_DROP_TAG: s_axis_tready = 1'b1;
      default: ;
    endcase
  end

  // The packet state drives BRAM write address/control, so reset it
  // synchronously in the AXI clock domain as required by RAMB36E1.
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      state             <= ST_IDLE;
      frame_mode        <= 1'b0;
      packet_mode       <= 1'b0;
      frame_active      <= 1'b0;
      frame_drain_pending <= 1'b0;
      frame_boundary_guard <= 1'b0;
      header_valid      <= 1'b0;
      payload_index     <= 7'd0;
      packet_session_id <= 32'h0;
      packet_frame_id   <= 32'h0;
      packet_index      <= 16'h0;
      packet_flags      <= 16'h0;
      frame_context_valid <= 1'b0;
      frame_session_id    <= 32'h0;
      frame_context_id    <= 32'h0;
      expected_packet_index <= 16'd0;
      frame_tx_encrypted <= 1'b0;
      aad_reg           <= 128'h0;
      nonce_reg         <= 96'h0;
      hash_subkey       <= 128'h0;
      crypto_ready      <= 1'b0;
      ghash_y_reg       <= 128'h0;
      tag_mask_reg      <= 128'h0;
      tag_mask_valid    <= 1'b0;
      keystream_reg     <= 128'h0;
      keystream_valid   <= 1'b0;
      write_bank        <= 1'b0;
      auth_ok_pulse     <= 1'b0;
      auth_fail_pulse   <= 1'b0;
      bypass_pulse      <= 1'b0;
      frame_done_pulse  <= 1'b0;
      frame_ready_pulse <= 1'b0;
      frame_fail        <= 1'b0;
      protocol_error    <= 1'b0;
    end else begin
      auth_ok_pulse     <= 1'b0;
      auth_fail_pulse   <= 1'b0;
      bypass_pulse      <= 1'b0;
      frame_done_pulse  <= 1'b0;
      frame_ready_pulse <= 1'b0;

      // Keep one idle clock after the final output drain.  The register bank
      // observes engine_busy low during that clock and can deliver a queued
      // key_clear/key_commit before the next frame header is accepted.
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

      if (key_clear && (state == ST_IDLE) &&
          (bank_ready == 2'b00) && !out_valid && !read_pending) begin
        crypto_ready    <= 1'b0;
        hash_subkey     <= 128'h0;
        tag_mask_valid  <= 1'b0;
        keystream_valid <= 1'b0;
      end else if (key_commit && session_key_valid &&
                   (state == ST_IDLE) && (bank_ready == 2'b00) &&
                   !out_valid && !read_pending) begin
        crypto_ready    <= 1'b0;
        hash_subkey     <= 128'h0;
        tag_mask_valid  <= 1'b0;
        keystream_valid <= 1'b0;
        state           <= ST_KEY_START;
      end else unique case (state)
        ST_KEY_START: state <= ST_KEY_WAIT;
        ST_KEY_WAIT: if (round_keys_valid) state <= ST_H_START;
        ST_H_START: state <= ST_H_WAIT;
        ST_H_WAIT: begin
          if (aux_done) begin
            hash_subkey <= aux_out;
            crypto_ready <= 1'b1;
            state <= ST_IDLE;
          end
        end
        ST_IDLE: begin
          if (s_axis_tvalid && s_axis_tready) begin
            if (!frame_active)
              frame_active <= 1'b1;
            aad_reg           <= input_gcm;
            packet_session_id <= input_session_id;
            packet_frame_id   <= input_frame_id;
            packet_index      <= input_packet_index;
            packet_flags      <= input_flags;
            nonce_reg <= make_nonce(input_session_id, input_frame_id,
                                    input_packet_index);
            packet_mode   <= selected_mode;
            header_valid  <= input_header_good;
            payload_index <= 7'd0;
            if (input_packet_index == 16'd0) begin
              frame_mode <= sw_sync;
              frame_fail <= !input_header_good;
              frame_context_valid <= 1'b1;
              frame_session_id <= input_session_id;
              frame_context_id <= input_frame_id;
              frame_tx_encrypted <= input_flags[0];
              expected_packet_index <= 16'd1;
            end
            if (!input_header_good) begin
              protocol_error <= 1'b1;
              frame_fail <= 1'b1;
              state <= ST_DROP_PAYLOAD;
            end else if (selected_mode) begin
              tag_mask_valid  <= 1'b0;
              keystream_valid <= 1'b0;
              state <= ST_PACKET_LAUNCH;
            end else begin
              state <= ST_BYPASS_PAYLOAD;
            end
          end
        end
        ST_PACKET_LAUNCH: begin
          ghash_y_reg <= 128'h0;
          state <= ST_ENC_SETUP_WAIT;
        end
        ST_ENC_SETUP_WAIT, ST_ENC_PAYLOAD: begin
          if (encrypted_fire) begin
            keystream_valid <= 1'b0;
            if ((s_axis_tkeep != 16'hffff) || s_axis_tlast) begin
              protocol_error <= 1'b1;
              header_valid   <= 1'b0;
            end
            if (payload_index == 7'd89)
              state <= ST_ENC_LAST_WAIT;
            else begin
              payload_index <= payload_index + 7'd1;
              state <= ST_ENC_PAYLOAD;
            end
          end
        end
        ST_ENC_LAST_WAIT: if (ghash_done) state <= ST_ENC_LEN_WAIT;
        ST_ENC_LEN_WAIT: if (ghash_done) state <= ST_ENC_TAG;
        ST_ENC_TAG: begin
          if (enc_tag_fire) begin
            if ((s_axis_tkeep != 16'hffff) ||
                (s_axis_tlast != commit_eof)) begin
              protocol_error <= 1'b1;
              header_valid   <= 1'b0;
            end
            if (tag_matches && header_valid && tag_format_good)
              auth_ok_pulse <= 1'b1;
            else begin
              auth_fail_pulse <= 1'b1;
              frame_fail <= 1'b1;
            end
            state <= ST_IDLE;
          end
        end
        ST_BYPASS_PAYLOAD: begin
          if (bypass_fire) begin
            if ((s_axis_tkeep != 16'hffff) || s_axis_tlast) begin
              protocol_error <= 1'b1;
              header_valid   <= 1'b0;
            end
            if (payload_index == 7'd89)
              state <= ST_BYPASS_TAG;
            else
              payload_index <= payload_index + 7'd1;
          end
        end
        ST_BYPASS_TAG: begin
          if (bypass_tag_fire) begin
            if ((s_axis_tkeep != 16'hffff) ||
                (s_axis_tlast != commit_eof)) begin
              protocol_error <= 1'b1;
              header_valid   <= 1'b0;
              frame_fail     <= 1'b1;
            end
            bypass_pulse <= 1'b1;
            state <= ST_IDLE;
          end
        end
        ST_DROP_PAYLOAD: begin
          if (drop_fire) begin
            if (payload_index == 7'd89)
              state <= ST_DROP_TAG;
            else
              payload_index <= payload_index + 7'd1;
          end
        end
        ST_DROP_TAG: if (drop_tag_fire) state <= ST_IDLE;
        default: state <= ST_KEY_START;
      endcase

      if (packet_commit) begin
        write_bank <= ~write_bank;
        // s_axis_tlast is the physical DMA frame boundary.  commit_eof is the
        // authenticated protocol boundary; either one must close the busy
        // transaction so malformed input cannot deadlock future rekeying.
        if (commit_eof || s_axis_tlast)
          frame_drain_pending <= 1'b1;
        if (commit_eof) begin
          frame_context_valid <= 1'b0;
          expected_packet_index <= 16'd0;
          frame_done_pulse <= 1'b1;
          if (!commit_zero && header_valid && !frame_fail)
            frame_ready_pulse <= 1'b1;
        end else if (packet_index != 16'd0) begin
          expected_packet_index <= packet_index + 16'd1;
        end
      end
    end
  end

  // BRAM address/control registers use synchronous reset so reset assertion is
  // covered by static timing and cannot asynchronously disturb the RAM port.
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      bank_ready <= 2'b00;
      bank_zero  <= 2'b00;
      bank_sof   <= 2'b00;
      bank_eof   <= 2'b00;
    end else begin
      if (output_release) bank_ready[read_bank] <= 1'b0;
      if (packet_commit) begin
        bank_ready[write_bank] <= 1'b1;
        bank_zero[write_bank]  <= commit_zero || !header_valid;
        bank_sof[write_bank]   <= commit_sof;
        bank_eof[write_bank]   <= commit_eof;
      end
    end
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      read_bank <= 1'b0;
      out_valid <= 1'b0;
      out_index <= 7'd0;
      out_data  <= 128'h0;
      read_pending <= 1'b0;
      read_pending_zero <= 1'b0;
    end else begin
      if (read_pending) begin
        out_valid <= 1'b1;
        out_data  <= read_pending_zero ? 128'h0 : packet_mem_read_data;
        read_pending <= 1'b0;
      end

      if (start_packet_read) begin
        out_index <= 7'd0;
        read_pending <= 1'b1;
        read_pending_zero <= bank_zero[read_bank];
      end else if (out_valid && m_axis_tready) begin
        out_valid <= 1'b0;
        if (out_index == 7'd89) begin
          out_index <= 7'd0;
          read_bank <= ~read_bank;
        end else begin
          out_index <= out_index + 7'd1;
          read_pending <= 1'b1;
          read_pending_zero <= bank_zero[read_bank];
        end
      end
    end
  end

  assign m_axis_tdata  = out_data;
  assign m_axis_tkeep  = 16'hffff;
  assign m_axis_tvalid = out_valid;
  assign m_axis_tuser  = out_valid && bank_sof[read_bank] &&
                         (out_index == 7'd0);
  assign m_axis_tlast  = out_valid && bank_eof[read_bank] &&
                         (out_index == 7'd89);

  assign key_ready = crypto_ready && session_key_valid;
  assign busy = frame_active || (state != ST_IDLE) || out_valid || read_pending ||
                (bank_ready != 2'b00);

  wire unused_status = &{1'b0, key_busy, data_busy, aux_busy, ghash_busy,
                         packet_mode, packet_session_id, packet_frame_id,
                         packet_flags};
endmodule
