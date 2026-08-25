import aes_sbox_pkg::*;

module aes_subbytes (
    input  logic [127:0] state_in,
    output logic [127:0] state_out
);
  integer i;

  always_comb begin
    for (i = 0; i < 16; i = i + 1) begin
      state_out[127-(i*8)-:8] = aes_sbox_byte(state_in[127-(i*8)-:8]);
    end
  end
endmodule

