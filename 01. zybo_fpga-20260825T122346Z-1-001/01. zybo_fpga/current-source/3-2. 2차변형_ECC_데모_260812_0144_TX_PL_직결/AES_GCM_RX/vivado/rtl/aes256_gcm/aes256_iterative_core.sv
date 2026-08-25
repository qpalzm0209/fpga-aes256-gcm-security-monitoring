`timescale 1ns / 1ps
module aes256_iterative_core (
    input logic clk,
    input logic rst_n,

    input logic         start,
    input logic [127:0] data_in,

    input logic [1919:0] round_keys,
    input logic          round_keys_valid,

    output logic         busy,
    output logic         done,
    output logic [127:0] data_out
);

  logic [127:0] state_reg;
  logic [127:0] initial_state;
  logic [127:0] round_state;
  logic [127:0] current_round_key;

  logic [  3:0] round_count;
  logic         final_round;

  // round_keys = {RK0, RK1, ... , RK14}
  function automatic logic [127:0] round_key_at(input logic [1919:0] keys, input logic [3:0] index);
    round_key_at = keys[1919-(index*128)-:128];
  endfunction

  assign current_round_key = round_key_at(round_keys, round_count);
  assign final_round       = (round_count == 4'd14);

  aes_addroundkey U_INITIAL_AddRoundKey (
      .state_in (data_in),
      .round_key(round_key_at(round_keys, 4'd0)),
      .state_out(initial_state)
  );

  aes_round U_ROUND (
      .state_in   (state_reg),
      .round_key  (current_round_key),
      .final_round(final_round),
      .state_out  (round_state)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_reg   <= 128'h0;
      round_count <= 4'd0;
      data_out    <= 128'h0;
      busy        <= 1'b0;
      done        <= 1'b0;
    end else begin
      done <= 1'b0;

      if (start && !busy && round_keys_valid) begin
        state_reg   <= initial_state;
        round_count <= 4'd1;
        busy        <= 1'b1;
      end else if (busy) begin
        if (final_round) begin
          data_out    <= round_state;
          round_count <= 4'd0;
          busy        <= 1'b0;
          done        <= 1'b1;
        end else begin
          state_reg   <= round_state;
          round_count <= round_count + 4'd1;
        end
      end
    end
  end

endmodule
