`timescale 1ns/1ps

module metadata_status_cdc (
    input         src_clk,
    input  [31:0] src_status,
    input         dst_clk,
    input         dst_resetn,
    output [31:0] dst_status
);
    // The source word changes only after a complete 40,960-byte metadata
    // frame and then remains stable.  Synchronize every bit and let software
    // accept a record only when two consecutive reads, including toggle[31],
    // match.
    xpm_cdc_array_single #(
        .DEST_SYNC_FF(3),
        .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(1),
        .SRC_INPUT_REG(1),
        .WIDTH(32)
    ) u_status_cdc (
        .src_clk(src_clk),
        .src_in(src_status),
        .dest_clk(dst_clk),
        .dest_out(dst_status)
    );

    wire unused = dst_resetn;
endmodule
