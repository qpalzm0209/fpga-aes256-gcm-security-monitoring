`timescale 1ns/1ps

module tb_axis_metadata_bram_writer;
  logic clk = 0;
  logic resetn = 0;
  logic [31:0] frame_id = 32'h12345678;
  logic frame_encrypted = 1;
  logic [127:0] data = 0;
  logic [15:0] keep = 16'hffff;
  logic valid = 0;
  wire ready;
  logic last = 0;
  wire bram_clk, bram_rst, bram_en;
  wire [3:0] bram_we;
  wire [16:0] bram_addr;
  wire [31:0] bram_wrdata;
  logic [31:0] bram_rddata = 0;
  wire [31:0] status;
  logic [31:0] memory [0:32767];

  always #3.333 clk = ~clk;
  always @(posedge bram_clk)
    if (bram_en && bram_we == 4'hf)
      memory[bram_addr[16:2]] <= bram_wrdata;

  axis_metadata_bram_writer dut (
      .aclk(clk), .aresetn(resetn), .frame_id(frame_id),
      .frame_encrypted(frame_encrypted), .s_meta_tdata(data),
      .s_meta_tkeep(keep), .s_meta_tvalid(valid),
      .s_meta_tready(ready), .s_meta_tlast(last),
      .bram_clk(bram_clk), .bram_rst(bram_rst), .bram_en(bram_en),
      .bram_we(bram_we), .bram_addr(bram_addr),
      .bram_wrdata(bram_wrdata), .bram_rddata(bram_rddata),
      .status(status)
  );

  task automatic send_meta(input logic [127:0] value,
                           input logic is_last);
    begin
      @(negedge clk);
      data = value;
      last = is_last;
      valid = 1;
      do @(posedge clk); while (!ready);
      @(negedge clk);
      valid = 0;
      last = 0;
    end
  endtask

  initial begin
    repeat (5) @(posedge clk);
    resetn = 1;
    send_meta(128'h00112233445566778899aabbccddeeff, 0);
    send_meta(128'h11111111222222223333333344444444, 0);
    send_meta(128'hdeadbeefdeadbeefdeadbeefdeadbeef, 0);
    send_meta(128'haaaaaaaabbbbbbbbccccccccdddddddd, 1);
    wait (status[31] == 1'b1);
    repeat (2) @(posedge clk);
    if (memory[0] !== 32'hccddeeff || memory[1] !== 32'h8899aabb ||
        memory[2] !== 32'h44556677 || memory[3] !== 32'h00112233)
      $fatal(1, "packet-0 AAD layout mismatch");
    if (memory[4] !== 32'h44444444 || memory[7] !== 32'h11111111)
      $fatal(1, "TAG0 layout mismatch");
    if (memory[8] !== 32'hdddddddd || memory[11] !== 32'haaaaaaaa)
      $fatal(1, "TAG1 layout mismatch");
    if (status[30:29] !== 2'd0 || status[28] !== 1'b1 ||
        status[15:0] !== 16'h5678)
      $fatal(1, "completion status mismatch: %08x", status);
    $display("RESULT metadata writer compact-ring layout PASS status=%08x", status);
    $finish;
  end
endmodule
