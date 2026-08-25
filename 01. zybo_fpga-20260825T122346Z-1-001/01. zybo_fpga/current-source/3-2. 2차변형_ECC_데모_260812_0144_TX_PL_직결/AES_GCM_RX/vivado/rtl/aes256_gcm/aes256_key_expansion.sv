`timescale 1ns / 1ps

module aes256_key_expansion (
    input logic         clk,
    input logic         rst_n,
    input logic         start,
    input logic [255:0] key_in,

    output logic          busy,              // 1: round_key generation
    output logic          round_keys_valid,  // 1: all round key is ready 
    output wire  [1919:0] round_keys
);

  import aes_key_rcon_pkg::*;

  /*
     * key_in = {w0,w1,w2,w3,w4,w5,w6,w7}
     * left   = {w0,w1,w2,w3}
     * right  = {w4,w5,w6,w7}
     */
  logic   [127:0] left_key_reg;
  logic   [127:0] right_key_reg;

  logic           phase_g;
  logic   [  3:0] key_index;
  logic   [  2:0] rcon_index;
  logic   [  7:0] current_rcon;

  logic   [127:0] round_key_mem  [0:14];

  logic   [127:0] base_key;
  logic   [ 31:0] last_word;
  logic   [ 31:0] transform_word;
  logic   [ 31:0] transform_reg;
  logic           transform_pending;
  logic   [127:0] generated_key;

  integer         i;

  assign round_keys = {
    round_key_mem[0],
    round_key_mem[1],
    round_key_mem[2],
    round_key_mem[3],
    round_key_mem[4],
    round_key_mem[5],
    round_key_mem[6],
    round_key_mem[7],
    round_key_mem[8],
    round_key_mem[9],
    round_key_mem[10],
    round_key_mem[11],
    round_key_mem[12],
    round_key_mem[13],
    round_key_mem[14]
  };

  assign current_rcon = aes256_rcon(rcon_index);

  // G: right key??留덉?留??뚮뱶濡?transform ?앹꽦, left key瑜??뺤옣
  // U: left key??留덉?留??뚮뱶濡?transform ?앹꽦, right key瑜??뺤옣
  always_comb begin
    if (phase_g) begin
      base_key  = left_key_reg;
      last_word = right_key_reg[31:0];
    end else begin
      base_key  = right_key_reg;
      last_word = left_key_reg[31:0];
    end
  end

  //transform 媛??앹꽦
  aes256_key_transform u_key_transform (
      .last_word (last_word),
      .use_g     (phase_g),
      .rcon_value(current_rcon),
      .transform (transform_word)
  );

  //?ㅼ쓬 ?쇱슫?쒓컪 ?앹꽦
  aes_next_round_key u_next_round_key (
      .base_key (base_key),
      .transform(transform_reg),
      .next_key (generated_key)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      left_key_reg     <= 128'h0;
      right_key_reg    <= 128'h0;

      phase_g          <= 1'b1;
      key_index        <= 4'd0;
      rcon_index       <= 3'd1;
      transform_reg    <= 32'h0;
      transform_pending <= 1'b0;

      busy             <= 1'b0;
      round_keys_valid <= 1'b0;

      for (i = 0; i < 15; i = i + 1) begin
        round_key_mem[i] <= 128'h0;
      end
    end else if (start && !busy) begin
      left_key_reg     <= key_in[255:128];
      right_key_reg    <= key_in[127:0];

      round_key_mem[0] <= key_in[255:128];
      round_key_mem[1] <= key_in[127:0];

      phase_g          <= 1'b1;
      key_index        <= 4'd2;
      rcon_index       <= 3'd1;
      transform_pending <= 1'b0;

      busy             <= 1'b1;
      round_keys_valid <= 1'b0;
    end else if (busy) begin
      /* Split SubWord/RotWord and the 128-bit XOR chain across two clocks.
       * Key setup is one-time per session, so this adds only 13 setup clocks
       * and removes the marginal 150 MHz combinational path without changing
       * steady-state AES-GCM throughput. */
      if (!transform_pending) begin
        transform_reg     <= transform_word;
        transform_pending <= 1'b1;
      end else begin
        transform_pending          <= 1'b0;
        round_key_mem[key_index]    <= generated_key;

        if (phase_g) begin
          left_key_reg <= generated_key;
          phase_g      <= 1'b0;
          rcon_index   <= rcon_index + 3'd1;
        end else begin
          right_key_reg <= generated_key;
          phase_g       <= 1'b1;
        end

        if (key_index == 4'd14) begin
          busy             <= 1'b0;
          round_keys_valid <= 1'b1;
        end else begin
          key_index <= key_index + 4'd1;
        end
      end
    end
  end

endmodule
