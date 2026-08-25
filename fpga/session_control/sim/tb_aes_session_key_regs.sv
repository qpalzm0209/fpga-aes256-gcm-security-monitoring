`timescale 1ns/1ps

module tb_aes_session_key_regs;
    logic clk = 0;
    logic resetn = 0;
    logic [7:0] awaddr = 0;
    logic awvalid = 0;
    logic awready;
    logic [31:0] wdata = 0;
    logic [3:0] wstrb = 0;
    logic wvalid = 0;
    logic wready;
    logic [1:0] bresp;
    logic bvalid;
    logic bready = 0;
    logic [7:0] araddr = 0;
    logic arvalid = 0;
    logic arready;
    logic [31:0] rdata;
    logic [1:0] rresp;
    logic rvalid;
    logic rready = 0;
    logic session_start_switch = 0;
    logic session_terminate_button = 0;
    logic engine_key_ready = 1;
    logic engine_busy = 0;
    logic [255:0] active_key;
    logic [31:0] active_session_id;
    logic active_key_valid;
    logic key_commit_pulse;
    logic key_clear_pulse;
    logic session_request_pending;
    logic rx_disabled_request_pending;
    logic tx_boot_on_request_pending;
    logic [15:0] key_epoch;

`ifdef TX_V1_WRAPPER
    // Dedicated bus for the production role wrapper.  Keeping it independent
    // lets this regression prove the wrapper's BTN3 policy directly without
    // perturbing the detailed core-level interlock tests below.
    logic [7:0] tx_v1_awaddr = 0;
    logic tx_v1_awvalid = 0;
    logic tx_v1_awready;
    logic [31:0] tx_v1_wdata = 0;
    logic [3:0] tx_v1_wstrb = 0;
    logic tx_v1_wvalid = 0;
    logic tx_v1_wready;
    logic [1:0] tx_v1_bresp;
    logic tx_v1_bvalid;
    logic tx_v1_bready = 0;
    logic tx_v1_session_terminate_button = 0;
    logic [255:0] tx_v1_active_key;
    logic [31:0] tx_v1_active_session_id;
    logic tx_v1_active_key_valid;
    logic tx_v1_key_commit_pulse;
    logic tx_v1_key_clear_pulse;
    logic tx_v1_session_request_pending;
    logic [15:0] tx_v1_key_epoch;
    logic tx_v1_saw_clear;
    logic [255:0] tx_v1_key_before_btn;
    logic [31:0] tx_v1_session_id_before_btn;
    logic [31:0] tx_v1_request_count_before_btn;
    logic [31:0] tx_v1_termination_count_before_btn;
    logic tx_v1_request_pending_before_btn;
`endif

    always #3.333 clk = ~clk;

    aes_session_key_regs #(
        .TERMINATE_DEBOUNCE_CYCLES(3)
    ) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready), .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready), .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready), .s_axi_rdata(rdata),
        .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .session_start_switch(session_start_switch),
        .session_terminate_button(session_terminate_button),
        .engine_key_ready(engine_key_ready), .engine_busy(engine_busy),
        .active_key(active_key), .active_session_id(active_session_id),
        .active_key_valid(active_key_valid),
        .key_commit_pulse(key_commit_pulse),
        .key_clear_pulse(key_clear_pulse),
        .session_request_pending(session_request_pending),
        .key_epoch(key_epoch)
    );

`ifdef TX_V1_WRAPPER
    // This is the actual block-design wrapper used by the TX production
    // design, not a parameterized stand-in from the testbench.
    aes_session_key_regs_bd tx_v1_wrapper (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(tx_v1_awaddr), .s_axi_awvalid(tx_v1_awvalid),
        .s_axi_awready(tx_v1_awready), .s_axi_wdata(tx_v1_wdata),
        .s_axi_wstrb(tx_v1_wstrb), .s_axi_wvalid(tx_v1_wvalid),
        .s_axi_wready(tx_v1_wready), .s_axi_bresp(tx_v1_bresp),
        .s_axi_bvalid(tx_v1_bvalid), .s_axi_bready(tx_v1_bready),
        .s_axi_araddr(8'd0), .s_axi_arvalid(1'b0),
        .s_axi_arready(), .s_axi_rdata(), .s_axi_rresp(),
        .s_axi_rvalid(), .s_axi_rready(1'b1),
        .session_start_switch(1'b0),
        .session_terminate_button(tx_v1_session_terminate_button),
        .engine_key_ready(1'b1), .engine_busy(1'b0),
        .active_key(tx_v1_active_key),
        .active_session_id(tx_v1_active_session_id),
        .active_key_valid(tx_v1_active_key_valid),
        .key_commit_pulse(tx_v1_key_commit_pulse),
        .key_clear_pulse(tx_v1_key_clear_pulse),
        .session_request_pending(tx_v1_session_request_pending),
        .key_epoch(tx_v1_key_epoch)
    );
`endif

    // RX accepts keys received from TX but must ignore its local SW2 so that
    // changing the RX switch can never disturb the active video session.
    aes_session_key_regs #(
        .SESSION_START_ACTIVE_LOW(1'b0),
        .ENABLE_SWITCH_REQUEST(1'b0),
        .TERMINATE_DEBOUNCE_CYCLES(3),
        .ENABLE_TERMINATE_BUTTON(1'b0)
    ) rx_switch_disabled (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(8'd0), .s_axi_awvalid(1'b0),
        .s_axi_awready(), .s_axi_wdata(32'd0),
        .s_axi_wstrb(4'd0), .s_axi_wvalid(1'b0),
        .s_axi_wready(), .s_axi_bresp(),
        .s_axi_bvalid(), .s_axi_bready(1'b1),
        .s_axi_araddr(8'd0), .s_axi_arvalid(1'b0),
        .s_axi_arready(), .s_axi_rdata(),
        .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b1),
        .session_start_switch(session_start_switch),
        .session_terminate_button(session_terminate_button),
        .engine_key_ready(1'b1), .engine_busy(1'b0),
        .active_key(), .active_session_id(), .active_key_valid(),
        .key_commit_pulse(), .key_clear_pulse(),
        .session_request_pending(rx_disabled_request_pending),
        .key_epoch()
    );

    // If TX is power-cycled while SW2 was left ON, it must automatically
    // create one request instead of waiting forever for another edge.
    aes_session_key_regs #(
        .SESSION_START_ACTIVE_LOW(1'b0),
        .ENABLE_SWITCH_REQUEST(1'b1),
        .TERMINATE_DEBOUNCE_CYCLES(3)
    ) tx_boot_on (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(8'd0), .s_axi_awvalid(1'b0),
        .s_axi_awready(), .s_axi_wdata(32'd0),
        .s_axi_wstrb(4'd0), .s_axi_wvalid(1'b0),
        .s_axi_wready(), .s_axi_bresp(),
        .s_axi_bvalid(), .s_axi_bready(1'b1),
        .s_axi_araddr(8'd0), .s_axi_arvalid(1'b0),
        .s_axi_arready(), .s_axi_rdata(),
        .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b1),
        .session_start_switch(1'b1),
        .session_terminate_button(1'b0),
        .engine_key_ready(1'b1), .engine_busy(1'b0),
        .active_key(), .active_session_id(), .active_key_valid(),
        .key_commit_pulse(), .key_clear_pulse(),
        .session_request_pending(tx_boot_on_request_pending),
        .key_epoch()
    );

    task automatic axi_write(input logic [7:0] address,
                             input logic [31:0] value);
        begin
            @(posedge clk);
            awaddr <= address;
            awvalid <= 1;
            wdata <= value;
            wstrb <= 4'hf;
            wvalid <= 1;
            do @(posedge clk); while (!(awready && wready));
            awvalid <= 0;
            wvalid <= 0;
            bready <= 1;
            do @(posedge clk); while (!bvalid);
            assert (bresp == 0) else $fatal(1, "AXI write response");
            bready <= 0;
        end
    endtask

    task automatic axi_read(input logic [7:0] address,
                            output logic [31:0] value);
        begin
            @(posedge clk);
            araddr <= address;
            arvalid <= 1;
            do @(posedge clk); while (!arready);
            arvalid <= 0;
            rready <= 1;
            do @(posedge clk); while (!rvalid);
            value = rdata;
            assert (rresp == 0) else $fatal(1, "AXI read response");
            rready <= 0;
        end
    endtask

`ifdef TX_V1_WRAPPER
    task automatic tx_v1_axi_write(input logic [7:0] address,
                                   input logic [31:0] value);
        begin
            @(posedge clk);
            tx_v1_awaddr <= address;
            tx_v1_awvalid <= 1;
            tx_v1_wdata <= value;
            tx_v1_wstrb <= 4'hf;
            tx_v1_wvalid <= 1;
            do @(posedge clk); while (!(tx_v1_awready && tx_v1_wready));
            tx_v1_awvalid <= 0;
            tx_v1_wvalid <= 0;
            tx_v1_bready <= 1;
            do @(posedge clk); while (!tx_v1_bvalid);
            assert (tx_v1_bresp == 0)
                else $fatal(1, "TX V1 wrapper AXI write response");
            tx_v1_bready <= 0;
        end
    endtask
`endif

    logic [31:0] value;
    logic saw_commit;
    logic saw_clear;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            saw_commit <= 0;
            saw_clear <= 0;
`ifdef TX_V1_WRAPPER
            tx_v1_saw_clear <= 0;
`endif
        end else begin
            saw_commit <= saw_commit || key_commit_pulse;
            saw_clear <= saw_clear || key_clear_pulse;
`ifdef TX_V1_WRAPPER
            tx_v1_saw_clear <= tx_v1_saw_clear || tx_v1_key_clear_pulse;
`endif
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        resetn <= 1;
        repeat (3) @(posedge clk);

        axi_read(8'h00, value);
        assert (value == 32'h4b455931) else $fatal(1, "bad register ID");

        // Final-demo build is active-high.  Booting with SW2 OFF must not
        // request a session; one OFF->ON edge must request exactly once.
        repeat (3) @(posedge clk);
        axi_read(8'h08, value);
        assert (!value[4]) else $fatal(1, "SW2-OFF created a false boot request");
        axi_read(8'h34, value);
        assert (value == 0) else $fatal(1, "boot request counter mismatch");
        assert (tx_boot_on_request_pending)
            else $fatal(1, "TX booted with SW2 ON did not request a session");

        session_start_switch <= 1;
        repeat (5) @(posedge clk);
        axi_read(8'h08, value);
        assert (value[4]) else $fatal(1, "SW2 OFF->ON edge was not latched");
        axi_read(8'h34, value);
        assert (value == 1) else $fatal(1, "SW2 edge request counter mismatch");
        assert (!rx_disabled_request_pending)
            else $fatal(1, "RX-local SW2 created a session request");
        repeat (8) @(posedge clk);
        axi_read(8'h34, value);
        assert (value == 1) else $fatal(1, "SW2 ON level retriggered");

        axi_write(8'h0c, 32'h11223344);
        axi_write(8'h10, 32'h00010203);
        axi_write(8'h14, 32'h04050607);
        axi_write(8'h18, 32'h08090a0b);
        axi_write(8'h1c, 32'h0c0d0e0f);
        axi_write(8'h20, 32'h10111213);
        axi_write(8'h24, 32'h14151617);
        axi_write(8'h28, 32'h18191a1b);
        axi_write(8'h2c, 32'h1c1d1e1f);

        engine_busy <= 1;
        axi_write(8'h04, 32'h1);
        axi_read(8'h08, value);
        assert (value[6] && !value[3] && !active_key_valid)
            else $fatal(1, "busy commit was not queued atomically");

        // The queued COMMIT belongs to request generation 1.  Create a newer
        // SW2 request while the old COMMIT is still waiting for a safe boundary.
        session_start_switch <= 0;
        repeat (5) @(posedge clk);
        session_start_switch <= 1;
        repeat (5) @(posedge clk);
        axi_read(8'h08, value);
        assert (value[6] && value[4])
            else $fatal(1, "new request was not retained beside old commit");
        axi_read(8'h34, value);
        assert (value == 2)
            else $fatal(1, "new request generation did not increment once");

        engine_busy <= 0;
        repeat (3) @(posedge clk);
        assert (active_key_valid && active_session_id == 32'h11223344)
            else $fatal(1, "commit did not publish session");
        assert (active_key == 256'h1c1d1e1f18191a1b1415161710111213_0c0d0e0f08090a0b0405060700010203)
            else $fatal(1, "atomic key mapping mismatch");
        assert (key_epoch == 1 && saw_commit)
            else $fatal(1, "commit pulse/epoch missing");
        axi_read(8'h08, value);
        assert (!value[6] && value[4])
            else $fatal(1, "old commit erased a newer SW2 request");
        axi_read(8'h34, value);
        assert (value == 2)
            else $fatal(1, "commit completion changed request generation");

        // Model the agent consuming the surviving newer request before the
        // independent BTN3 regression below.
        axi_write(8'h04, 32'h4);
        axi_read(8'h08, value);
        assert (!value[4]) else $fatal(1, "request ACK failed");

        // Returning SW2 to OFF only arms the next rising edge.  It must not
        // clear or disturb the current session/video key.
        session_start_switch <= 0;
        repeat (5) @(posedge clk);
        assert (active_key_valid && active_session_id == 32'h11223344)
            else $fatal(1, "SW2 ON->OFF disturbed the active session");
        axi_read(8'h34, value);
        assert (value == 2) else $fatal(1, "SW2 falling edge changed request count");

        // Software must reserve the published key before admitting a DMA
        // frame.  The reservation is visible in status bit 9, a duplicate
        // ACQUIRE is rejected, and RELEASE is unconditional and clears a
        // previous command error.
        axi_write(8'h04, 32'h10);
        axi_read(8'h08, value);
        assert (value[9] && !value[3])
            else $fatal(1, "frame-lock ACQUIRE failed");
        axi_write(8'h04, 32'h10);
        axi_read(8'h08, value);
        assert (value[9] && value[3])
            else $fatal(1, "duplicate frame-lock ACQUIRE was accepted");
        axi_write(8'h04, 32'h20);
        axi_read(8'h08, value);
        assert (!value[9] && !value[3])
            else $fatal(1, "unconditional frame-lock RELEASE failed");

        engine_key_ready <= 0;
        axi_write(8'h04, 32'h10);
        axi_read(8'h08, value);
        assert (!value[9] && value[3])
            else $fatal(1, "ACQUIRE ignored engine_key_ready");
        engine_key_ready <= 1;
        axi_write(8'h04, 32'h20);

        // A queued COMMIT may be prepared while the current frame owns the
        // key, but it must not publish until software releases the frame lock.
        axi_write(8'h04, 32'h10);
        axi_write(8'h04, 32'h1);
        repeat (4) @(posedge clk);
        axi_read(8'h08, value);
        assert (value[9] && value[6] && active_key_valid && key_epoch == 1)
            else $fatal(1, "frame lock did not defer queued COMMIT");
        axi_write(8'h04, 32'h20);
        repeat (3) @(posedge clk);
        axi_read(8'h08, value);
        assert (!value[9] && !value[6] && key_epoch == 2)
            else $fatal(1, "RELEASE did not admit queued COMMIT");

        // A short BTN3 glitch must be rejected by the debounce filter.
        session_terminate_button <= 1;
        @(posedge clk);
        session_terminate_button <= 0;
        repeat (7) @(posedge clk);
        axi_read(8'h08, value);
        assert (!value[8] && active_key_valid)
            else $fatal(1, "BTN3 debounce accepted a short glitch");
        axi_read(8'h3c, value);
        assert (value == 0) else $fatal(1, "glitch changed termination count");

        // Queue a replacement while the engine is busy.  A debounced BTN3
        // press must cancel that unpublished commit/request, then defer key
        // clearing until the first safe engine boundary.
        // Lock the currently published key before the next DMA starts.  BTN3
        // may queue termination while this frame is in flight, but it must
        // not forcibly remove the reservation or the active key.
        axi_write(8'h04, 32'h10);
        engine_busy <= 1;
        axi_write(8'h0c, 32'h55667788);
        axi_write(8'h04, 32'h1);
        axi_read(8'h08, value);
        assert (value[9] && value[6])
            else $fatal(1, "replacement commit was not queued under frame lock");

        session_terminate_button <= 1;
        repeat (10) @(posedge clk);
        axi_read(8'h08, value);
        assert (value[9] && value[8] && value[7] && !value[6] && !value[4])
            else $fatal(1, "BTN3 press did not cancel and queue safe clear");
        assert (active_key_valid)
            else $fatal(1, "BTN3 cleared the key before the safe boundary");
        axi_read(8'h3c, value);
        assert (value == 1) else $fatal(1, "termination count mismatch");

        axi_write(8'h04, 32'h10);
        axi_read(8'h08, value);
        assert (value[9] && value[8] && value[7] && value[3])
            else $fatal(1, "termination/clear race admitted ACQUIRE");

        // Held BTN3 is a stable terminated mode.  It must not retrigger or
        // accept a software COMMIT, and RX's disabled physical control remains
        // inert even though it sees the same testbench button.
        axi_write(8'h04, 32'h1);
        repeat (8) @(posedge clk);
        axi_read(8'h08, value);
        assert (value[9] && value[8] && !value[6] && !value[4] && value[3])
            else $fatal(1, "held BTN3 accepted a commit/request");
        axi_read(8'h3c, value);
        assert (value == 1) else $fatal(1, "held BTN3 retriggered termination");
        assert (!rx_switch_disabled.termination_active &&
                !rx_disabled_request_pending)
            else $fatal(1, "RX-local physical controls were not disabled");

        // The in-flight DMA owner can always release its reservation even
        // while BTN3 remains held.  Engine busy still prevents the queued
        // clear from cutting the current transfer.
        axi_write(8'h04, 32'h20);
        axi_read(8'h08, value);
        assert (!value[9] && value[8] && value[7] && !value[3] &&
                active_key_valid)
            else $fatal(1, "RELEASE was not unconditional during termination");

        // Release BTN3 while the old frame is still busy and clear_pending is
        // still set.  The release must create exactly one next-session request
        // even though the old key cannot be cleared yet.
        session_terminate_button <= 0;
        repeat (10) @(posedge clk);
        axi_read(8'h08, value);
        assert (!value[9] && !value[8] && value[7] && value[4] &&
                active_key_valid)
            else $fatal(1, "release while busy lost clear/request state");
        axi_read(8'h34, value);
        assert (value == 3) else $fatal(1, "release request count mismatch");

        // When the engine drains, the earlier unconditional frame RELEASE
        // allows the termination clear to complete.
        engine_busy <= 0;
        repeat (3) @(posedge clk);
        assert (!active_key_valid && active_key == 0 && saw_clear)
            else $fatal(1, "safe-boundary termination clear failed");
        assert (active_session_id == 0)
            else $fatal(1, "terminated session ID was not cleared");
        axi_read(8'h08, value);
        assert (!value[9] && !value[7] && value[4])
            else $fatal(1, "late clear erased the BTN3 release request");
        axi_read(8'h34, value);
        assert (value == 3)
            else $fatal(1, "late clear changed release request count");

        repeat (8) @(posedge clk);
        axi_read(8'h34, value);
        assert (value == 3) else $fatal(1, "release level retriggered request");
        axi_read(8'h08, value);
        assert (value[4])
            else $fatal(1, "fresh request did not remain pending");
        axi_read(8'h3c, value);
        assert (value == 1) else $fatal(1, "release changed termination count");

`ifdef TX_V1_WRAPPER
        // Exercise the production TX wrapper on its own AXI bus.  The
        // hierarchical constant check prevents a too-short BTN3 hold from
        // masking an accidental return to the 10 ms debounce configuration.
        assert (tx_v1_wrapper.u_core.ENABLE_TERMINATE_BUTTON == 1'b0)
            else $fatal(1, "TX V1 wrapper did not disable BTN3");
        tx_v1_axi_write(8'h0c, 32'ha5a55a5a);
        tx_v1_axi_write(8'h10, 32'h00010203);
        tx_v1_axi_write(8'h14, 32'h04050607);
        tx_v1_axi_write(8'h18, 32'h08090a0b);
        tx_v1_axi_write(8'h1c, 32'h0c0d0e0f);
        tx_v1_axi_write(8'h20, 32'h10111213);
        tx_v1_axi_write(8'h24, 32'h14151617);
        tx_v1_axi_write(8'h28, 32'h18191a1b);
        tx_v1_axi_write(8'h2c, 32'h1c1d1e1f);
        tx_v1_axi_write(8'h04, 32'h1);
        repeat (3) @(posedge clk);
        assert (tx_v1_active_key_valid &&
                tx_v1_active_session_id == 32'ha5a55a5a &&
                tx_v1_active_key ==
                    256'h1c1d1e1f18191a1b1415161710111213_0c0d0e0f08090a0b0405060700010203 &&
                tx_v1_key_epoch == 1)
            else $fatal(1, "TX V1 wrapper failed to publish the test session");
        assert (!tx_v1_saw_clear &&
                !tx_v1_wrapper.u_core.clear_pending &&
                !tx_v1_wrapper.u_core.termination_active)
            else $fatal(1, "TX V1 wrapper began with termination state set");

        tx_v1_key_before_btn = tx_v1_active_key;
        tx_v1_session_id_before_btn = tx_v1_active_session_id;
        tx_v1_request_count_before_btn = tx_v1_wrapper.u_core.request_count;
        tx_v1_termination_count_before_btn =
            tx_v1_wrapper.u_core.termination_count;
        tx_v1_request_pending_before_btn = tx_v1_session_request_pending;

        tx_v1_session_terminate_button <= 1;
        repeat (12) @(posedge clk);
        assert (tx_v1_active_key_valid &&
                tx_v1_active_key == tx_v1_key_before_btn &&
                tx_v1_active_session_id == tx_v1_session_id_before_btn &&
                !tx_v1_key_clear_pulse && !tx_v1_saw_clear &&
                !tx_v1_wrapper.u_core.clear_pending &&
                !tx_v1_wrapper.u_core.termination_active &&
                tx_v1_wrapper.u_core.request_count ==
                    tx_v1_request_count_before_btn &&
                tx_v1_wrapper.u_core.termination_count ==
                    tx_v1_termination_count_before_btn &&
                tx_v1_session_request_pending ==
                    tx_v1_request_pending_before_btn)
            else $fatal(1, "TX V1 wrapper reacted to BTN3 high");

        tx_v1_session_terminate_button <= 0;
        repeat (12) @(posedge clk);
        assert (tx_v1_active_key_valid &&
                tx_v1_active_key == tx_v1_key_before_btn &&
                tx_v1_active_session_id == tx_v1_session_id_before_btn &&
                !tx_v1_key_clear_pulse && !tx_v1_saw_clear &&
                !tx_v1_wrapper.u_core.clear_pending &&
                !tx_v1_wrapper.u_core.termination_active &&
                tx_v1_wrapper.u_core.request_count ==
                    tx_v1_request_count_before_btn &&
                tx_v1_wrapper.u_core.termination_count ==
                    tx_v1_termination_count_before_btn &&
                tx_v1_session_request_pending ==
                    tx_v1_request_pending_before_btn)
            else $fatal(1, "TX V1 wrapper reacted to BTN3 low");

        // BTN3 is inert, but the software lifecycle path remains functional.
        tx_v1_axi_write(8'h04, 32'h2);
        repeat (3) @(posedge clk);
        assert (!tx_v1_active_key_valid && tx_v1_active_key == 0 &&
                tx_v1_active_session_id == 0 && tx_v1_saw_clear &&
                !tx_v1_wrapper.u_core.clear_pending &&
                tx_v1_wrapper.u_core.request_count ==
                    tx_v1_request_count_before_btn &&
                tx_v1_wrapper.u_core.termination_count ==
                    tx_v1_termination_count_before_btn)
            else $fatal(1, "TX V1 wrapper AXI COMMAND_CLEAR failed");

        $display("PASS: core interlocks plus production wrapper BTN3-inert/AXI-CLEAR policy");
`else
        $display("PASS: frame-lock COMMIT/BTN3 interlock, generation-safe release request, SW2 one-shot and RX controls disabled");
`endif
        $finish;
    end
endmodule
