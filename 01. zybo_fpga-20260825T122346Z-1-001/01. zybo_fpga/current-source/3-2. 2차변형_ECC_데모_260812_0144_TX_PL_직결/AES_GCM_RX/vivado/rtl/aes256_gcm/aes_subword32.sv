import aes_sbox_pkg::*;
`timescale 1ns / 1ps
module aes_subword32 (
    input  logic [31:0] word_in,
    output logic [31:0] word_out
);


  assign word_out = {
    aes_sbox_byte(word_in[31:24]),
    aes_sbox_byte(word_in[23:16]),
    aes_sbox_byte(word_in[15:8]),
    aes_sbox_byte(word_in[7:0])
  };

endmodule

