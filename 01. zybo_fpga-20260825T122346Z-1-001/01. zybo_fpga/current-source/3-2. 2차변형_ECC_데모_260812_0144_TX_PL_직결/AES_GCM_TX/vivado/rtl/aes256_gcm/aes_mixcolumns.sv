`timescale 1ns / 1ps

module aes_mixcolumns (
    input  logic [127:0] state_in,
    output logic [127:0] state_out
);

  logic [7:0] b[0:15];
  logic [7:0] y[0:15];

  integer i;
  integer c;

  function automatic logic [7:0] aes_xtime(input logic [7:0] byte_in);
    aes_xtime = {byte_in[6:0], 1'b0} ^ (8'h1b & {8{byte_in[7]}});
  endfunction

  function automatic logic [7:0] aes_gf_mul2(input logic [7:0] byte_in);
    aes_gf_mul2 = aes_xtime(byte_in);
  endfunction

  function automatic logic [7:0] aes_gf_mul3(input logic [7:0] byte_in);
    aes_gf_mul3 = aes_xtime(byte_in) ^ byte_in;
  endfunction

  always_comb begin
    for (i = 0; i < 16; i = i + 1) begin
      b[i] = state_in[127-(i*8)-:8];
    end

    for (c = 0; c < 4; c = c + 1) begin
      y[(4*c)+0] = aes_gf_mul2(b[(4*c)+0]) ^ aes_gf_mul3(b[(4*c)+1]) ^ b[(4*c)+2] ^ b[(4*c)+3];

      y[(4*c)+1] = b[(4*c)+0] ^ aes_gf_mul2(b[(4*c)+1]) ^ aes_gf_mul3(b[(4*c)+2]) ^ b[(4*c)+3];

      y[(4*c)+2] = b[(4*c)+0] ^ b[(4*c)+1] ^ aes_gf_mul2(b[(4*c)+2]) ^ aes_gf_mul3(b[(4*c)+3]);

      y[(4*c)+3] = aes_gf_mul3(b[(4*c)+0]) ^ b[(4*c)+1] ^ b[(4*c)+2] ^ aes_gf_mul2(b[(4*c)+3]);
    end

    for (i = 0; i < 16; i = i + 1) begin
      state_out[127-(i*8)-:8] = y[i];
    end
  end

endmodule

