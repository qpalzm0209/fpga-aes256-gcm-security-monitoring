`timescale 1ns/1ps

module tb_tx_pipeline_health_status;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    reg [31:0] level = 32'd0;
    reg raw_prog_full = 1'b0;
    reg pack_error = 1'b0;
    reg crypto_error = 1'b0;
    reg unpack_error = 1'b0;
    wire [31:0] status;

    always #3.333 clk = ~clk;

    tx_pipeline_health_status dut (
        .aclk(clk),
        .aresetn(resetn),
        .fifo_level(level),
        .fifo_near_full(raw_prog_full),
        .pack_protocol_error(pack_error),
        .crypto_protocol_error(crypto_error),
        .unpack_protocol_error(unpack_error),
        .status(status)
    );

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        repeat (3) tick();
        resetn = 1'b1;

        // The FIFO IP can pulse prog_full during reset release.  With only two
        // beats occupied this must not become a sticky near-full failure.
        raw_prog_full = 1'b1;
        level = 32'd2;
        tick();
        raw_prog_full = 1'b0;
        tick();
        if (status[30] !== 1'b0) $fatal(1, "reset transient became sticky");
        if (status[27:14] !== 14'd2) $fatal(1, "high-water mismatch");

        level = 32'd7680;
        tick();
        level = 32'd0;
        tick();
        if (status[30] !== 1'b1) $fatal(1, "real threshold was not sticky");
        if (status[27:14] !== 14'd7680) $fatal(1, "threshold high-water mismatch");

        $display("PASS: health ignores reset prog_full pulse and records real occupancy threshold");
        $finish;
    end
endmodule
