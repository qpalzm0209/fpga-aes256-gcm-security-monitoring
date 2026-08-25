`timescale 1ns / 1ps
package aes_key_rcon_pkg;

  function automatic logic [7:0] aes256_rcon(input logic [2:0] index);
    unique case (index)
      3'd1:    aes256_rcon = 8'h01;
      3'd2:    aes256_rcon = 8'h02;
      3'd3:    aes256_rcon = 8'h04;
      3'd4:    aes256_rcon = 8'h08;
      3'd5:    aes256_rcon = 8'h10;
      3'd6:    aes256_rcon = 8'h20;
      3'd7:    aes256_rcon = 8'h40;
      default: aes256_rcon = 8'h00;
    endcase
  endfunction

endpackage

