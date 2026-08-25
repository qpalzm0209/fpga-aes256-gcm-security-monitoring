
`timescale 1ns / 1ps
module aes_next_round_key (
    input  logic [127:0] base_key,
    input  logic [ 31:0] transform,
    output logic [127:0] next_key
);

  logic [31:0] w0, w1, w2, w3;
  logic [31:0] nw0, nw1, nw2, nw3;

  assign {w0, w1, w2, w3} = base_key;

  assign nw0 = transform ^ w0;
  assign nw1 = transform ^ w0 ^ w1;
  assign nw2 = transform ^ w0 ^ w1 ^ w2;
  assign nw3 = transform ^ w0 ^ w1 ^ w2 ^ w3;

  assign next_key = {nw0, nw1, nw2, nw3};

endmodule

