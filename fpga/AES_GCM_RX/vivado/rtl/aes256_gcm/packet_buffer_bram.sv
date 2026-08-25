`timescale 1ns/1ps

// 180 x 128 simple dual-port RAM: two authenticated 90-block packet banks.
module packet_buffer_bram (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         wr_en,
    input  logic [7:0]   wr_addr,
    input  logic [127:0] wr_data,
    input  logic         rd_en,
    input  logic [7:0]   rd_addr,
    output logic [127:0] rd_data
);
  (* ram_style = "block" *) logic [127:0] mem [0:179];
  logic         wr_en_q;
  logic [7:0]   wr_addr_q;
  logic [127:0] wr_data_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_en_q <= 1'b0;
    end else begin
      if (wr_en_q) mem[wr_addr_q] <= wr_data_q;
      wr_en_q   <= wr_en;
      wr_addr_q <= wr_addr;
      wr_data_q <= wr_data;
    end
    if (rd_en) rd_data <= mem[rd_addr];
  end
endmodule
