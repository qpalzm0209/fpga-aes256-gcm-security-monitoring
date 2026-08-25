`timescale 1ns/1ps

// Read-only TX video-pipeline health word exposed through the existing
// meta-session AXI GPIO channel 1.  None of these signals participates in
// the data path; they make camera/AES backpressure failures observable.
//
// [31]    sticky 16->128 packer protocol error
// [30]    sticky ingress FIFO programmable-full indication
// [29]    sticky AES-GCM frame processor protocol error
// [28]    sticky 128->16 unpacker protocol error
// [27:14] ingress FIFO high-water mark (128-bit beats)
// [13:0]  ingress FIFO current occupancy (128-bit beats)
module tx_pipeline_health_status (
    input         aclk,
    input         aresetn,
    input  [31:0] fifo_level,
    input         fifo_near_full,
    input         pack_protocol_error,
    input         crypto_protocol_error,
    input         unpack_protocol_error,
    output [31:0] status
);
    reg [3:0]  sticky_errors;
    reg [13:0] fifo_high_water;

    wire [13:0] fifo_level_clamped =
        (|fifo_level[31:14]) ? 14'h3fff : fifo_level[13:0];

    // axis_data_fifo can pulse prog_full while its internal reset is being
    // released even though the exported occupancy is still near zero.  A
    // sticky diagnostic must not turn that reset transient into a permanent
    // pipeline fault.  Derive the threshold from the valid write count; keep
    // fifo_near_full in the interface only for BD compatibility/observation.
    wire fifo_near_full_from_level =
        (fifo_level_clamped >= 14'd7680);

    always @(posedge aclk) begin
        if (!aresetn) begin
            sticky_errors <= 4'd0;
            fifo_high_water <= 14'd0;
        end else begin
            sticky_errors <= sticky_errors |
                {pack_protocol_error, fifo_near_full_from_level,
                 crypto_protocol_error, unpack_protocol_error};
            if (fifo_level_clamped > fifo_high_water)
                fifo_high_water <= fifo_level_clamped;
        end
    end

    assign status = {sticky_errors, fifo_high_water, fifo_level_clamped};
endmodule
