`timescale 1ns/1ps

module axis_gcm_tx_frame_processor_bd (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_axis:m_axis:m_meta, ASSOCIATED_RESET aresetn, FREQ_HZ 150000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *) input aclk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *) input aresetn,
    input sw3_encrypt,
    input [31:0] session_id,
    input [255:0] session_key,
    input session_key_valid,
    input key_commit,
    input key_clear,

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

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_meta TDATA" *) output [127:0] m_meta_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_meta TKEEP" *) output [15:0] m_meta_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_meta TVALID" *) output m_meta_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_meta TREADY" *) input m_meta_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_meta TLAST" *) output m_meta_tlast,
    output [31:0] active_frame_id,
    output active_frame_encrypted,
    output [31:0] debug_status,
    output key_ready,
    output busy,
    output protocol_error
);
    axis_gcm_tx_frame_processor u_impl (
        .aclk(aclk), .aresetn(aresetn), .sw3_encrypt(sw3_encrypt),
        .session_id(session_id), .session_key(session_key),
        .session_key_valid(session_key_valid), .key_commit(key_commit),
        .key_clear(key_clear),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .m_meta_tdata(m_meta_tdata), .m_meta_tkeep(m_meta_tkeep),
        .m_meta_tvalid(m_meta_tvalid), .m_meta_tready(m_meta_tready),
        .m_meta_tlast(m_meta_tlast),
        .active_frame_id(active_frame_id),
        .active_frame_encrypted(active_frame_encrypted),
        .debug_status(debug_status),
        .key_ready(key_ready), .busy(busy),
        .protocol_error(protocol_error)
    );
endmodule
