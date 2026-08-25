`timescale 1ns/1ps

module axis_video_aes_gcm_switch_bd (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_axis:m_axis:m_meta, ASSOCIATED_RESET aresetn, FREQ_HZ 150000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    input aclk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    input aresetn,
    input sw3_encrypt,
    input [31:0] session_id,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *) input [15:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TKEEP" *) input [1:0] s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TSTRB" *) input [1:0] s_axis_tstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TUSER" *) input s_axis_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *) input s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TID" *) input s_axis_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDEST" *) input s_axis_tdest,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *) input s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *) output s_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *) output [15:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TKEEP" *) output [1:0] m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TSTRB" *) output [1:0] m_axis_tstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TUSER" *) output m_axis_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *) output m_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TID" *) output m_axis_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDEST" *) output m_axis_tdest,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *) output m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *) input m_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_meta TDATA" *) output [127:0] m_meta_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_meta TKEEP" *) output [15:0] m_meta_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_meta TVALID" *) output m_meta_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_meta TREADY" *) input m_meta_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_meta TLAST" *) output m_meta_tlast,
    output [31:0] active_frame_id,
    output active_frame_encrypted
);
    // The verified camera/V4L2 path is always plaintext.  Encryption now
    // happens only in the byte-transparent raw-frame DMA slot.
    assign s_axis_tready = m_axis_tready && aresetn;
    assign m_axis_tdata = s_axis_tdata;
    assign m_axis_tkeep = s_axis_tkeep;
    assign m_axis_tstrb = s_axis_tstrb;
    assign m_axis_tuser = s_axis_tuser;
    assign m_axis_tlast = s_axis_tlast;
    assign m_axis_tid = s_axis_tid;
    assign m_axis_tdest = s_axis_tdest;
    assign m_axis_tvalid = s_axis_tvalid && aresetn;
    assign m_meta_tdata = 128'd0;
    assign m_meta_tkeep = 16'd0;
    assign m_meta_tvalid = 1'b0;
    assign m_meta_tlast = 1'b0;
    assign active_frame_id = 32'd0;
    assign active_frame_encrypted = 1'b0;

    wire unused = &{1'b0, aclk, sw3_encrypt, session_id, m_meta_tready};
endmodule
