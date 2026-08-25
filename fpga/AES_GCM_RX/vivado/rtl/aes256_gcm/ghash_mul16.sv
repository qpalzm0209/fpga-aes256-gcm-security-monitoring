`timescale 1ns/1ps

// One GHASH multiplication in exactly 16 clocks (8 multiplier bits/clock).
// ready is also asserted on the final clock, allowing a dependent multiply to
// start without a bubble by using result as its y_in value.
module ghash_mul16 (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [127:0] h,
    input  logic [127:0] data_in,
    input  logic [127:0] y_in,
    output logic         ready,
    output logic         busy,
    output logic         done,
    output logic [127:0] result
);
  localparam logic [127:0] R_POLY =
      128'he1000000000000000000000000000000;

  logic         running;
  logic [3:0]   byte_index;
  logic [127:0] x_reg;
  logic [127:0] z_reg;
  logic [127:0] v_reg;
  logic [255:0] step_value;
  logic [127:0] z_next;
  logic [127:0] v_next;

  function automatic logic [255:0] step8(
      input logic [127:0] z_in,
      input logic [127:0] v_in,
      input logic [7:0]   x_bits
  );
    logic [127:0] v0, v1, v2, v3, v4, v5, v6, v7, v8;
    logic [127:0] p0, p1, p2, p3, p4, p5, p6, p7;
    logic [127:0] q0, q1, q2, q3;
    begin
      v0 = v_in;
      v1 = v0[0] ? ((v0 >> 1) ^ R_POLY) : (v0 >> 1);
      v2 = v1[0] ? ((v1 >> 1) ^ R_POLY) : (v1 >> 1);
      v3 = v2[0] ? ((v2 >> 1) ^ R_POLY) : (v2 >> 1);
      v4 = v3[0] ? ((v3 >> 1) ^ R_POLY) : (v3 >> 1);
      v5 = v4[0] ? ((v4 >> 1) ^ R_POLY) : (v4 >> 1);
      v6 = v5[0] ? ((v5 >> 1) ^ R_POLY) : (v5 >> 1);
      v7 = v6[0] ? ((v6 >> 1) ^ R_POLY) : (v6 >> 1);
      v8 = v7[0] ? ((v7 >> 1) ^ R_POLY) : (v7 >> 1);

      p0 = x_bits[7] ? v0 : 128'h0;
      p1 = x_bits[6] ? v1 : 128'h0;
      p2 = x_bits[5] ? v2 : 128'h0;
      p3 = x_bits[4] ? v3 : 128'h0;
      p4 = x_bits[3] ? v4 : 128'h0;
      p5 = x_bits[2] ? v5 : 128'h0;
      p6 = x_bits[1] ? v6 : 128'h0;
      p7 = x_bits[0] ? v7 : 128'h0;
      q0 = p0 ^ p1;
      q1 = p2 ^ p3;
      q2 = p4 ^ p5;
      q3 = p6 ^ p7;
      step8 = {z_in ^ (q0 ^ q1) ^ (q2 ^ q3), v8};
    end
  endfunction

  // Consume the next byte from a shift register.  This avoids a 16:1
  // variable-part-select mux on the GHASH critical path.
  assign step_value = step8(z_reg, v_reg, x_reg[127:120]);
  assign z_next = step_value[255:128];
  assign v_next = step_value[127:0];
  assign done   = running && (byte_index == 4'd15);
  assign ready  = !running || done;
  assign busy   = running && !done;
  assign result = done ? z_next : z_reg;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      running    <= 1'b0;
      byte_index <= 4'd0;
      x_reg      <= 128'h0;
      z_reg      <= 128'h0;
      v_reg      <= 128'h0;
    end else if (running) begin
      if (done) begin
        if (start) begin
          running    <= 1'b1;
          byte_index <= 4'd0;
          x_reg      <= y_in ^ data_in;
          z_reg      <= 128'h0;
          v_reg      <= h;
        end else begin
          z_reg   <= z_next;
          v_reg   <= v_next;
          running <= 1'b0;
        end
      end else begin
        byte_index <= byte_index + 4'd1;
        x_reg      <= {x_reg[119:0], 8'h00};
        z_reg      <= z_next;
        v_reg      <= v_next;
      end
    end else if (start) begin
      running    <= 1'b1;
      byte_index <= 4'd0;
      x_reg      <= y_in ^ data_in;
      z_reg      <= 128'h0;
      v_reg      <= h;
    end
  end
endmodule
