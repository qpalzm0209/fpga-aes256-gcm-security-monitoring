`timescale 1ns/1ps

// Four-frame metadata ring in the existing 128-KiB BRAM.
// Each 32-KiB bank stores packet-0 AAD once, followed by 1280 TAGs:
//   +0x0000 : 16-byte packet-0 AAD (session/frame/mode identity)
//   +0x0010 : TAG[0]
//   +0x0020 : TAG[1]
//   ...
//   +0x5000 : TAG[1279]
// AAD for packets 1..1279 is deterministic and reconstructed by software.
module axis_metadata_bram_writer (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_meta, ASSOCIATED_RESET aresetn, FREQ_HZ 150000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    input aclk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    input aresetn,
    input [31:0] frame_id,
    input frame_encrypted,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_meta TDATA" *) input [127:0] s_meta_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_meta TKEEP" *) input [15:0] s_meta_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_meta TVALID" *) input s_meta_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_meta TREADY" *) output s_meta_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_meta TLAST" *) input s_meta_tlast,

    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME bram, MASTER_TYPE BRAM_CTRL, MEM_SIZE 131072" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram CLK" *) output bram_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram RST" *) output bram_rst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram EN" *) output bram_en,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram WE" *) output [3:0] bram_we,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram ADDR" *) output [16:0] bram_addr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram DIN" *) output [31:0] bram_wrdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram DOUT" *) input [31:0] bram_rddata,

    // [31]=completion toggle, [30:29]=completed bank, [28]=mode,
    // [15:0]=completed frame ID low bits.
    output [31:0] status
);
    reg [127:0] data_reg;
    reg [1:0] word_index;
    reg [12:0] word_offset;
    reg [10:0] packet_index;
    reg meta_phase;
    reg last_reg;
    reg [1:0] write_bank;
    reg complete_toggle;
    reg [1:0] complete_bank;
    reg complete_mode;
    reg [15:0] complete_frame_low;
    reg latched_mode;
    reg [15:0] latched_frame_low;
    reg busy;

    assign s_meta_tready = !busy;
    assign bram_clk = aclk;
    assign bram_rst = !aresetn;
    assign bram_en = busy;
    assign bram_we = busy ? 4'hf : 4'h0;
    assign bram_addr = {write_bank, word_offset + word_index, 2'b00};
    assign bram_wrdata = data_reg[word_index*32 +: 32];
    assign status = {complete_toggle, complete_bank, complete_mode,
                     12'd0, complete_frame_low};

    always @(posedge aclk) begin
        if (!aresetn) begin
            data_reg <= 128'd0;
            word_index <= 2'd0;
            word_offset <= 13'd0;
            packet_index <= 11'd0;
            meta_phase <= 1'b0;
            last_reg <= 1'b0;
            write_bank <= 2'd0;
            complete_toggle <= 1'b0;
            complete_bank <= 2'd0;
            complete_mode <= 1'b0;
            complete_frame_low <= 16'd0;
            latched_mode <= 1'b0;
            latched_frame_low <= 16'd0;
            busy <= 1'b0;
        end else begin
            if (!busy && s_meta_tvalid) begin
                if (!meta_phase) begin
                    // Only packet-0 AAD is retained.  All later AAD words
                    // are deterministic from this header and packet index.
                    meta_phase <= 1'b1;
                    if (packet_index == 11'd0) begin
                        data_reg <= s_meta_tdata;
                        word_offset <= 13'd0;
                        word_index <= 2'd0;
                        latched_mode <= frame_encrypted;
                        latched_frame_low <= frame_id[15:0];
                        busy <= 1'b1;
                    end
                end else begin
                    // Four words per TAG, starting after the 16-byte AAD.
                    meta_phase <= 1'b0;
                    data_reg <= s_meta_tdata;
                    word_offset <= 13'd4 + {packet_index, 2'b00};
                    word_index <= 2'd0;
                    last_reg <= s_meta_tlast;
                    busy <= 1'b1;
                    if (s_meta_tlast)
                        packet_index <= 11'd0;
                    else
                        packet_index <= packet_index + 11'd1;
                end
            end else if (busy) begin
                if (word_index == 2'd3) begin
                    busy <= 1'b0;
                    word_index <= 2'd0;
                    if (last_reg) begin
                        last_reg <= 1'b0;
                        complete_toggle <= !complete_toggle;
                        complete_bank <= write_bank;
                        complete_mode <= latched_mode;
                        complete_frame_low <= latched_frame_low;
                        write_bank <= write_bank + 2'd1;
                    end
                end else begin
                    word_index <= word_index + 2'd1;
                end
            end
        end
    end

    wire unused = &{1'b0, s_meta_tkeep, bram_rddata};
endmodule
