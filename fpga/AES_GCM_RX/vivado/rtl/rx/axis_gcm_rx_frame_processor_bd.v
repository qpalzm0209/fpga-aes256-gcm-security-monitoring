`timescale 1ns/1ps

module axis_gcm_rx_frame_processor_bd (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn, FREQ_HZ 150000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *) input aclk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *) input aresetn,
    input sw3_decrypt,
    input [31:0] session_id,
    input [255:0] session_key,
    input session_key_valid,
    input key_commit,
    input key_clear,
    input [15:0] key_epoch,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *) input [127:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TKEEP" *) input [15:0] s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *) input s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *) output s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *) input s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *) output [127:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TKEEP" *) output [15:0] m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *) output m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *) input m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *) output m_axis_tlast,
    output [31:0] frame_status,
    output key_ready,
    output busy,
    input  [31:0] error_control,
    output [31:0] error_status,
    output        error_irq,
    output        err_valid,
    output [4:0]  err_flags,
    output [2:0]  err_code,
    output [4:0]  err_sticky
);
    wire [191:0] err_record_unused;

    axis_gcm_rx_frame_processor u_impl (
        .aclk(aclk), .aresetn(aresetn), .sw3_decrypt(sw3_decrypt),
        .session_id(session_id),
        .session_key(session_key), .session_key_valid(session_key_valid),
        .key_commit(key_commit), .key_clear(key_clear),
        .key_epoch(key_epoch),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast), .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep), .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
        .frame_status(frame_status), .key_ready(key_ready), .busy(busy),
        .error_control(error_control), .error_status(error_status),
        .error_irq(error_irq),
        .err_valid(err_valid), .err_flags(err_flags),
        .err_code(err_code), .err_sticky(err_sticky),
        .err_record(err_record_unused)
    );
endmodule

