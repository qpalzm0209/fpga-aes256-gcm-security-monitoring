`timescale 1ns/1ps

// AXI4-Lite shadow/commit register bank for an AES-256 session key.
// Key words are write-only.  A COMMIT atomically publishes all 256 bits and
// the session ID to the streaming engine; CLEAR invalidates the active key.
module aes_session_key_regs #(
    parameter integer AXI_ADDR_WIDTH = 8,
    // Final physical-demo behavior: one OFF->ON edge starts one session.
    parameter bit SESSION_START_ACTIVE_LOW = 1'b0,
    parameter bit ENABLE_SWITCH_REQUEST = 1'b1,
    // BTN3 must remain stable for 10 ms at 150 MHz before changing state.
    // Simulations override this with a small value.
    parameter integer TERMINATE_DEBOUNCE_CYCLES = 1_500_000,
    parameter bit ENABLE_TERMINATE_BUTTON = 1'b1
) (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aclk, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 150000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    input  logic                      s_axi_aclk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aresetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    input  logic                      s_axi_aresetn,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8, FREQ_HZ 150000000, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    input  logic [AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  logic                      s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output logic                      s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  logic [31:0]               s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  logic [3:0]                s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  logic                      s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output logic                      s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output logic [1:0]                s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output logic                      s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  logic                      s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  logic [AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  logic                      s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output logic                      s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output logic [31:0]               s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output logic [1:0]                s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output logic                      s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  logic                      s_axi_rready,

    input  logic                      session_start_switch,
    input  logic                      session_terminate_button,
    input  logic                      engine_key_ready,
    input  logic                      engine_busy,

    output logic [255:0]              active_key,
    output logic [31:0]               active_session_id,
    output logic                      active_key_valid,
    output logic                      key_commit_pulse,
    output logic                      key_clear_pulse,
    output logic                      session_request_pending,
    output logic [15:0]               key_epoch
);
    localparam logic [31:0] REGISTER_ID = 32'h4b455931; // "KEY1"

    logic [31:0] shadow_key [0:7];
    logic [31:0] shadow_session_id;
    logic [31:0] request_count;
    logic [31:0] termination_count;
    logic        command_error;
    logic [255:0] pending_key;
    logic [31:0]  pending_session_id;
    logic [31:0]  pending_request_generation;
    logic         commit_pending;
    logic         clear_pending;
    logic         clear_from_termination;
    // Software reserves the key/session for one complete DMA video frame.
    // This closes the check-to-START window where BTN3 could otherwise clear
    // the key after software checked it but before the first AXIS beat arrived.
    logic         frame_lock;

    (* ASYNC_REG = "TRUE" *) logic switch_meta;
    (* ASYNC_REG = "TRUE" *) logic switch_sync;
    logic [1:0] switch_sync_valid;
    logic switch_active_last;
    logic switch_initialized;
    wire switch_active = SESSION_START_ACTIVE_LOW ? !switch_sync : switch_sync;

    // BTN3 is asynchronous and mechanical.  Synchronize it first, then
    // accept a press/release only after a parameterized stable interval.
    localparam integer TERMINATE_DEBOUNCE_WIDTH =
        (TERMINATE_DEBOUNCE_CYCLES <= 1) ? 1 :
        $clog2(TERMINATE_DEBOUNCE_CYCLES);
    (* ASYNC_REG = "TRUE" *) logic terminate_meta;
    (* ASYNC_REG = "TRUE" *) logic terminate_sync;
    logic [TERMINATE_DEBOUNCE_WIDTH-1:0] terminate_debounce_count;
    logic termination_active;
    logic terminate_pressed_pulse;
    logic terminate_released_pulse;
    // The synchronized raw level immediately stalls a new commit/request
    // while the debounce timer is proving a press.  Only the debounced state
    // performs the destructive clear, so contact bounce cannot erase a key.
    wire termination_blocking = ENABLE_TERMINATE_BUTTON &&
                                (termination_active || terminate_sync);
    wire switch_request_event = switch_sync_valid[1] &&
                                ENABLE_SWITCH_REQUEST && switch_active &&
                                !termination_blocking &&
                                (!switch_initialized || !switch_active_last);
    wire release_request_event = ENABLE_TERMINATE_BUTTON &&
                                 terminate_released_pulse;

    logic aw_stored;
    logic [AXI_ADDR_WIDTH-1:0] awaddr_stored;
    logic w_stored;
    logic [31:0] wdata_stored;
    logic [3:0] wstrb_stored;

    wire aw_accept = s_axi_awvalid && s_axi_awready;
    wire w_accept = s_axi_wvalid && s_axi_wready;
    wire write_fire = !s_axi_bvalid && (aw_stored || aw_accept) &&
                      (w_stored || w_accept);
    wire [AXI_ADDR_WIDTH-1:0] write_addr =
        aw_stored ? awaddr_stored : s_axi_awaddr;
    wire [31:0] write_data = w_stored ? wdata_stored : s_axi_wdata;
    wire [3:0] write_strb = w_stored ? wstrb_stored : s_axi_wstrb;
    wire [5:0] write_word = write_addr[7:2];
    wire [5:0] read_word = s_axi_araddr[7:2];

    integer i;

    function automatic [31:0] merge_bytes(
        input [31:0] old_value,
        input [31:0] new_value,
        input [3:0] strobe
    );
        integer byte_index;
        begin
            merge_bytes = old_value;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (strobe[byte_index])
                    merge_bytes[byte_index*8 +: 8] =
                        new_value[byte_index*8 +: 8];
        end
    endfunction

    always_comb begin
        s_axi_awready = !aw_stored && !s_axi_bvalid;
        s_axi_wready  = !w_stored && !s_axi_bvalid;
        s_axi_bresp   = 2'b00;
        s_axi_arready = !s_axi_rvalid;
        s_axi_rresp   = 2'b00;

        unique case (read_word)
            6'h00: s_axi_rdata = REGISTER_ID;
            6'h02: s_axi_rdata = {
                key_epoch,
                6'd0,
                frame_lock,
                termination_active,
                clear_pending,
                commit_pending,
                switch_sync,
                session_request_pending,
                command_error,
                engine_busy,
                engine_key_ready,
                active_key_valid
            };
            6'h03: s_axi_rdata = shadow_session_id;
            6'h0c: s_axi_rdata = active_session_id;
            6'h0d: s_axi_rdata = request_count;
            6'h0e: s_axi_rdata = {16'd0, key_epoch};
            6'h0f: s_axi_rdata = termination_count;
            default: s_axi_rdata = 32'd0;
        endcase
    end

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            switch_meta <= 1'b0;
            switch_sync <= 1'b0;
            switch_sync_valid <= 2'b00;
        end else begin
            switch_meta <= session_start_switch;
            switch_sync <= switch_meta;
            switch_sync_valid <= {switch_sync_valid[0], 1'b1};
        end
    end

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            terminate_meta <= 1'b0;
            terminate_sync <= 1'b0;
            terminate_debounce_count <= '0;
            termination_active <= 1'b0;
            terminate_pressed_pulse <= 1'b0;
            terminate_released_pulse <= 1'b0;
        end else begin
            terminate_meta <= session_terminate_button;
            terminate_sync <= terminate_meta;
            terminate_pressed_pulse <= 1'b0;
            terminate_released_pulse <= 1'b0;

            if (!ENABLE_TERMINATE_BUTTON) begin
                terminate_debounce_count <= '0;
                termination_active <= 1'b0;
            end else if (terminate_sync == termination_active) begin
                terminate_debounce_count <= '0;
            end else if ((TERMINATE_DEBOUNCE_CYCLES <= 1) ||
                         (terminate_debounce_count ==
                          TERMINATE_DEBOUNCE_CYCLES - 1)) begin
                terminate_debounce_count <= '0;
                termination_active <= terminate_sync;
                if (terminate_sync)
                    terminate_pressed_pulse <= 1'b1;
                else
                    terminate_released_pulse <= 1'b1;
            end else begin
                terminate_debounce_count <= terminate_debounce_count + 1'b1;
            end
        end
    end

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            aw_stored <= 1'b0;
            awaddr_stored <= '0;
            w_stored <= 1'b0;
            wdata_stored <= 32'd0;
            wstrb_stored <= 4'd0;
            s_axi_bvalid <= 1'b0;
            s_axi_rvalid <= 1'b0;
            active_key <= 256'd0;
            active_session_id <= 32'd0;
            active_key_valid <= 1'b0;
            shadow_session_id <= 32'd0;
            request_count <= 32'd0;
            termination_count <= 32'd0;
            command_error <= 1'b0;
            session_request_pending <= 1'b0;
            key_commit_pulse <= 1'b0;
            key_clear_pulse <= 1'b0;
            key_epoch <= 16'd0;
            pending_key <= 256'd0;
            pending_session_id <= 32'd0;
            pending_request_generation <= 32'd0;
            commit_pending <= 1'b0;
            clear_pending <= 1'b0;
            clear_from_termination <= 1'b0;
            frame_lock <= 1'b0;
            switch_active_last <= 1'b0;
            switch_initialized <= 1'b0;
            for (i = 0; i < 8; i = i + 1)
                shadow_key[i] <= 32'd0;
        end else begin
            key_commit_pulse <= 1'b0;
            key_clear_pulse <= 1'b0;

            // A debounced BTN3 press has priority over every session action.
            // Cancel an unpublished key/request and clear the active key only
            // at an engine-safe boundary.  Holding BTN3 keeps the block in the
            // terminated state; release creates exactly one fresh request.
            if (ENABLE_TERMINATE_BUTTON && terminate_pressed_pulse) begin
                termination_count <= termination_count + 32'd1;
                session_request_pending <= 1'b0;
                commit_pending <= 1'b0;
                pending_request_generation <= 32'd0;
                clear_pending <= 1'b1;
                clear_from_termination <= 1'b1;
                command_error <= 1'b0;
            end else begin
                // Wait until the two-flop synchronizer contains the physical
                // switch value.  An active level already present at boot
                // creates exactly one request; later inactive-to-active edges
                // do likewise.  BTN3 termination suppresses all such requests.
                if (switch_sync_valid[1]) begin
                    if (!switch_initialized) begin
                        switch_initialized <= 1'b1;
                        switch_active_last <= switch_active;
                        if (ENABLE_SWITCH_REQUEST && switch_active &&
                            !termination_blocking) begin
                            session_request_pending <= 1'b1;
                            request_count <= request_count + 32'd1;
                        end
                    end else begin
                        if (ENABLE_SWITCH_REQUEST && switch_active &&
                            !switch_active_last && !termination_blocking) begin
                            session_request_pending <= 1'b1;
                            request_count <= request_count + 32'd1;
                        end
                        switch_active_last <= switch_active;
                    end
                end

                // A software request is captured atomically and completed by
                // PL on the first safe stream boundary.  CLEAR is allowed
                // during termination; COMMIT is not.
                if (commit_pending && !engine_busy && !frame_lock &&
                    !termination_blocking) begin
                    active_key <= pending_key;
                    active_session_id <= pending_session_id;
                    active_key_valid <= 1'b1;
                    key_commit_pulse <= 1'b1;
                    commit_pending <= 1'b0;
                    // COMMIT belongs to the request generation captured when
                    // software issued it.  A newer SW2/release request must
                    // survive completion of this older queued COMMIT.  The
                    // event terms also cover a new edge in this same clock,
                    // before its nonblocking counter update becomes visible.
                    if ((request_count == pending_request_generation) &&
                        !switch_request_event && !release_request_event)
                        session_request_pending <= 1'b0;
                    pending_request_generation <= 32'd0;
                    key_epoch <= key_epoch + 16'd1;
                end else if (clear_pending && !engine_busy && !frame_lock) begin
                    active_key <= 256'd0;
                    active_session_id <= 32'd0;
                    active_key_valid <= 1'b0;
                    key_clear_pulse <= 1'b1;
                    clear_pending <= 1'b0;
                    // A BTN3 release is allowed before an in-flight frame
                    // reaches its safe clear boundary.  In that ordering the
                    // release has already created the next-session request;
                    // do not erase it when the old key is finally cleared.
                    if (!clear_from_termination || termination_active)
                        session_request_pending <= 1'b0;
                    clear_from_termination <= 1'b0;
                end

                if (ENABLE_TERMINATE_BUTTON && termination_active) begin
                    session_request_pending <= 1'b0;
                    commit_pending <= 1'b0;
                end

                // Release is a new session, not a resume of the old key.  The
                // request counter change causes Linux to generate/exchange a
                // fresh random key through the existing agent.
                if (ENABLE_TERMINATE_BUTTON && terminate_released_pulse) begin
                    session_request_pending <= 1'b1;
                    request_count <= request_count + 32'd1;
                end
            end

            if (aw_accept && !write_fire) begin
                aw_stored <= 1'b1;
                awaddr_stored <= s_axi_awaddr;
            end
            if (w_accept && !write_fire) begin
                w_stored <= 1'b1;
                wdata_stored <= s_axi_wdata;
                wstrb_stored <= s_axi_wstrb;
            end
            if (write_fire) begin
                aw_stored <= 1'b0;
                w_stored <= 1'b0;
                s_axi_bvalid <= 1'b1;

                unique case (write_word)
                    6'h01: begin
                        if (write_strb[0] && write_data[3])
                            command_error <= 1'b0;
                        if (write_strb[0] && write_data[2])
                            session_request_pending <= 1'b0;
                        // RELEASE wins if both frame-lock command bits are
                        // written.  It is unconditional so termination can
                        // always drain an already admitted DMA frame.
                        if (write_strb[0] && write_data[5]) begin
                            frame_lock <= 1'b0;
                            command_error <= 1'b0;
                        end else if (write_strb[0] && write_data[4]) begin
                            if (!termination_blocking && !commit_pending &&
                                !clear_pending && active_key_valid &&
                                engine_key_ready && !frame_lock) begin
                                frame_lock <= 1'b1;
                                command_error <= 1'b0;
                            end else begin
                                command_error <= 1'b1;
                            end
                        end
                        if (write_strb[0] &&
                            (write_data[1:0] == 2'b01)) begin
                            if (!termination_blocking && !commit_pending &&
                                !clear_pending) begin
                                pending_key <= {
                                    shadow_key[7], shadow_key[6],
                                    shadow_key[5], shadow_key[4],
                                    shadow_key[3], shadow_key[2],
                                    shadow_key[1], shadow_key[0]
                                };
                                pending_session_id <= shadow_session_id;
                                pending_request_generation <= request_count;
                                commit_pending <= 1'b1;
                                command_error <= 1'b0;
                            end else begin
                                command_error <= 1'b1;
                            end
                        end else if (write_strb[0] &&
                                     (write_data[1:0] == 2'b10)) begin
                            if (!commit_pending && !clear_pending) begin
                                clear_pending <= 1'b1;
                                clear_from_termination <= 1'b0;
                                command_error <= 1'b0;
                            end else begin
                                command_error <= 1'b1;
                            end
                        end else if (write_strb[0] &&
                                     (write_data[1:0] == 2'b11)) begin
                            command_error <= 1'b1;
                        end
                    end
                    6'h03: shadow_session_id <= merge_bytes(
                        shadow_session_id, write_data, write_strb);
                    6'h04: shadow_key[0] <= merge_bytes(
                        shadow_key[0], write_data, write_strb);
                    6'h05: shadow_key[1] <= merge_bytes(
                        shadow_key[1], write_data, write_strb);
                    6'h06: shadow_key[2] <= merge_bytes(
                        shadow_key[2], write_data, write_strb);
                    6'h07: shadow_key[3] <= merge_bytes(
                        shadow_key[3], write_data, write_strb);
                    6'h08: shadow_key[4] <= merge_bytes(
                        shadow_key[4], write_data, write_strb);
                    6'h09: shadow_key[5] <= merge_bytes(
                        shadow_key[5], write_data, write_strb);
                    6'h0a: shadow_key[6] <= merge_bytes(
                        shadow_key[6], write_data, write_strb);
                    6'h0b: shadow_key[7] <= merge_bytes(
                        shadow_key[7], write_data, write_strb);
                    default: begin end
                endcase
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            if (s_axi_arvalid && s_axi_arready)
                s_axi_rvalid <= 1'b1;
            else if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end
endmodule
