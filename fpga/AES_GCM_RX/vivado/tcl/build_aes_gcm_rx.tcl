# AES_GCM_RX reproducible project, Vivado 2025.2, Zybo Z7-20.

set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
set project_dir [file join $vivado_dir project]
set rtl_dir [file join $vivado_dir rtl]
set ip_repo [file join $vivado_dir ip_repo vivado-library]

create_project -force AES_GCM_RX $project_dir -part xc7z020clg400-1
config_ip_cache -disable_cache
set_property BOARD_PART digilentinc.com:zybo-z7-20:part0:1.2 [current_project]
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property ip_repo_paths $ip_repo [current_project]
update_ip_catalog

set ordered_sv [list \
    [file join $rtl_dir aes256_gcm aes_key_rcon_pkg.sv] \
    [file join $rtl_dir aes256_gcm aes_sbox_pkg.sv] \
    [file join $rtl_dir aes256_gcm gcm_protocol_pkg.sv] \
    [file join $rtl_dir aes256_gcm aes_addroundkey.sv] \
    [file join $rtl_dir aes256_gcm aes_mixcolumns.sv] \
    [file join $rtl_dir aes256_gcm aes_next_round_key.sv] \
    [file join $rtl_dir aes256_gcm aes_round.sv] \
    [file join $rtl_dir aes256_gcm aes_shiftrows.sv] \
    [file join $rtl_dir aes256_gcm aes_subbytes.sv] \
    [file join $rtl_dir aes256_gcm aes_subword32.sv] \
    [file join $rtl_dir aes256_gcm aes256_iterative_core.sv] \
    [file join $rtl_dir aes256_gcm aes256_key_expansion.sv] \
    [file join $rtl_dir aes256_gcm aes256_key_transform.sv] \
    [file join $rtl_dir aes256_gcm ghash_mul16.sv] \
    [file join $rtl_dir aes256_gcm packet_buffer_bram.sv] \
    [file join $rtl_dir aes256_gcm video_aes_gcm_rx_top.sv] \
    [file join $rtl_dir rx gcm_rx_error_detector.sv] \
    [file join $rtl_dir rx axis_gcm_rx_frame_processor_v2.sv] \
    [file join $rtl_dir session aes_session_key_regs.sv]]
add_files -norecurse $ordered_sv
set_property file_type SystemVerilog [get_files $ordered_sv]
add_files -norecurse [list \
    [file join $rtl_dir rx axis_gcm_rx_frame_processor_bd.v] \
    [file join $rtl_dir session aes_session_key_regs_bd.v] \
    [file join $rtl_dir video axis_yuyv32_to_rgb24.v] \
    [file join $rtl_dir video video_timing_720p.v] \
    [file join $rtl_dir video hdmi_status_pack.v]]
add_files -fileset constrs_1 -norecurse [file join $vivado_dir constraints rx_pins.xdc]
set_property top axis_gcm_rx_frame_processor_bd [current_fileset]
update_compile_order -fileset sources_1

create_bd_design aes_gcm_rx_system

set DDR [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR]
set FIXED_IO [create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO]
set sw3 [create_bd_port -dir I sw3_decrypt]
set sw2 [create_bd_port -dir I sw2_session_start]

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {apply_board_preset "1" make_external "FIXED_IO, DDR" Master "Disable" Slave "Disable"} $ps
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {0} \
    CONFIG.PCW_USE_S_AXI_HP1 {1} \
    CONFIG.PCW_USE_S_AXI_ACP {1} \
    CONFIG.PCW_USE_DEFAULT_ACP_USER_VAL {1} \
    CONFIG.PCW_S_AXI_ACP_ARUSER_VAL {1} \
    CONFIG.PCW_S_AXI_ACP_AWUSER_VAL {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_FCLK0_PERIPHERAL_CLKSRC {ARM PLL} \
    CONFIG.PCW_APU_PERIPHERAL_FREQMHZ {600.000000} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {150.000000} \
    CONFIG.PCW_CLK0_FREQ {150000000} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_IRQ_F2P_MODE {DIRECT} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1}] $ps

set rst150 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_150m]
set video_clk [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 video_clk_74m25]
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {150.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {74.250} \
    CONFIG.NUM_OUT_CLKS {1} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {true}] $video_clk
set rst_video [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_video]

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_packet]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axi_mm2s_data_width {128} \
    CONFIG.c_m_axis_mm2s_tdata_width {128} \
    CONFIG.c_m_axi_s2mm_data_width {128} \
    CONFIG.c_s_axis_s2mm_tdata_width {128} \
    CONFIG.c_include_mm2s_dre {0} \
    CONFIG.c_include_s2mm_dre {0} \
    CONFIG.c_mm2s_burst_size {16} \
    CONFIG.c_s2mm_burst_size {16} \
    CONFIG.c_sg_length_width {21}] $dma

set rx [create_bd_cell -type module -reference axis_gcm_rx_frame_processor_bd gcm_rx_slot]

set vdma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma:6.3 axi_vdma_display]
set_property -dict [list \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_include_mm2s_dre {1} \
    CONFIG.c_num_fstores {3}] $vdma

set video_cdc [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter:1.1 video_axis_150_to_74]
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {4} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.TUSER_WIDTH {1} \
    CONFIG.IS_ACLK_ASYNC {1} \
    CONFIG.SYNCHRONIZATION_STAGES {3}] $video_cdc
set yuyv_rgb [create_bd_cell -type module -reference axis_yuyv32_to_rgb24 yuyv_to_rgb]
set vid_out [create_bd_cell -type ip -vlnv xilinx.com:ip:v_axi4s_vid_out:4.0 axi4s_to_video]
set_property -dict [list \
    CONFIG.C_HAS_ASYNC_CLK {0} \
    CONFIG.C_NATIVE_COMPONENT_WIDTH {8} \
    CONFIG.C_S_AXIS_VIDEO_DATA_WIDTH {8}] $vid_out
set timing [create_bd_cell -type module -reference video_timing_720p video_timing_720p]
set hdmi_diag [create_bd_cell -type module -reference hdmi_status_pack hdmi_status_pack]
set dvi [create_bd_cell -type ip -vlnv digilentinc.com:ip:rgb2dvi:1.4 rgb2dvi_0]
set_property -dict [list \
    CONFIG.kGenerateSerialClk {true} \
    CONFIG.kClkPrimitive {MMCM} \
    CONFIG.kClkRange {2} \
    CONFIG.kRstActiveHigh {false}] $dvi
make_bd_intf_pins_external [get_bd_intf_pins $dvi/TMDS]
set_property name TMDS [get_bd_intf_ports TMDS_0]

set hp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_hp0]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $hp0
set hp1 [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_hp1]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $hp1
set gp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_gp0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {6}] $gp0
set status_gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 rx_status_gpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1}] $status_gpio
set hdmi_gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 hdmi_status_gpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1}] $hdmi_gpio
set key_regs [create_bd_cell -type module -reference aes_session_key_regs_bd aes_session_key_regs_0]
# 에러 검출기: channel 1 = error_status 읽기, channel 2 = error_control 쓰기.
set error_gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 rx_error_gpio]
set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {32} CONFIG.C_ALL_OUTPUTS_2 {1}] $error_gpio
set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 irq_concat]
set_property CONFIG.NUM_PORTS {3} $irq_concat

connect_bd_intf_net [get_bd_intf_pins $dma/M_AXIS_MM2S] [get_bd_intf_pins $rx/s_axis]
connect_bd_intf_net [get_bd_intf_pins $rx/m_axis] [get_bd_intf_pins $dma/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_MM2S] [get_bd_intf_pins $hp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_S2MM] [get_bd_intf_pins $hp0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins $hp0/M00_AXI] [get_bd_intf_pins $ps/S_AXI_ACP]
connect_bd_intf_net [get_bd_intf_pins $vdma/M_AXI_MM2S] [get_bd_intf_pins $hp1/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $hp1/M00_AXI] [get_bd_intf_pins $ps/S_AXI_HP1]

connect_bd_intf_net [get_bd_intf_pins $vdma/M_AXIS_MM2S] [get_bd_intf_pins $video_cdc/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins $video_cdc/M_AXIS] [get_bd_intf_pins $yuyv_rgb/s_axis]
connect_bd_intf_net [get_bd_intf_pins $yuyv_rgb/m_axis] [get_bd_intf_pins $vid_out/video_in]
connect_bd_intf_net [get_bd_intf_pins $vid_out/vid_io_out] [get_bd_intf_pins $dvi/RGB]
connect_bd_net [get_bd_pins $timing/active_video] [get_bd_pins $vid_out/vtg_active_video]
connect_bd_net [get_bd_pins $timing/hblank] [get_bd_pins $vid_out/vtg_hblank]
connect_bd_net [get_bd_pins $timing/hsync] [get_bd_pins $vid_out/vtg_hsync]
connect_bd_net [get_bd_pins $timing/vblank] [get_bd_pins $vid_out/vtg_vblank]
connect_bd_net [get_bd_pins $timing/vsync] [get_bd_pins $vid_out/vtg_vsync]
connect_bd_net [get_bd_pins $timing/field_id] [get_bd_pins $vid_out/vtg_field_id]
connect_bd_net [get_bd_pins $vid_out/vtg_ce] \
    [get_bd_pins $timing/clken] [get_bd_pins $hdmi_diag/vtg_ce]
connect_bd_net [get_bd_pins $video_clk/locked] [get_bd_pins $hdmi_diag/video_clk_locked]
connect_bd_net [get_bd_pins $vid_out/locked] [get_bd_pins $hdmi_diag/vid_locked]
connect_bd_net [get_bd_pins $vid_out/underflow] [get_bd_pins $hdmi_diag/underflow]
connect_bd_net [get_bd_pins $vid_out/overflow] [get_bd_pins $hdmi_diag/overflow]
connect_bd_net [get_bd_pins $timing/active_video] [get_bd_pins $hdmi_diag/active_video]
connect_bd_net [get_bd_pins $timing/frame_toggle] [get_bd_pins $hdmi_diag/frame_toggle]
connect_bd_net [get_bd_pins $hdmi_diag/status] [get_bd_pins $hdmi_gpio/gpio_io_i]

connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_GP0] [get_bd_intf_pins $gp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $gp0/M00_AXI] [get_bd_intf_pins $dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins $gp0/M01_AXI] [get_bd_intf_pins $vdma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins $gp0/M02_AXI] [get_bd_intf_pins $status_gpio/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $gp0/M03_AXI] [get_bd_intf_pins $hdmi_gpio/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $gp0/M04_AXI] [get_bd_intf_pins $key_regs/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $gp0/M05_AXI] [get_bd_intf_pins $error_gpio/S_AXI]

connect_bd_net [get_bd_ports sw3_decrypt] [get_bd_pins $rx/sw3_decrypt]
connect_bd_net [get_bd_ports sw2_session_start] [get_bd_pins $key_regs/session_start_switch]
connect_bd_net [get_bd_pins $key_regs/active_session_id] [get_bd_pins $rx/session_id]
connect_bd_net [get_bd_pins $key_regs/active_key] [get_bd_pins $rx/session_key]
connect_bd_net [get_bd_pins $key_regs/active_key_valid] [get_bd_pins $rx/session_key_valid]
connect_bd_net [get_bd_pins $key_regs/key_commit_pulse] [get_bd_pins $rx/key_commit]
connect_bd_net [get_bd_pins $key_regs/key_clear_pulse] [get_bd_pins $rx/key_clear]
connect_bd_net [get_bd_pins $key_regs/key_epoch] [get_bd_pins $rx/key_epoch]
connect_bd_net [get_bd_pins $rx/error_status] [get_bd_pins $error_gpio/gpio_io_i]
connect_bd_net [get_bd_pins $error_gpio/gpio2_io_o] [get_bd_pins $rx/error_control]
connect_bd_net [get_bd_pins $rx/key_ready] [get_bd_pins $key_regs/engine_key_ready]
connect_bd_net [get_bd_pins $rx/busy] [get_bd_pins $key_regs/engine_busy]
connect_bd_net [get_bd_pins $rx/frame_status] [get_bd_pins $status_gpio/gpio_io_i]
connect_bd_net [get_bd_pins $dma/mm2s_introut] [get_bd_pins $irq_concat/In0]
connect_bd_net [get_bd_pins $dma/s2mm_introut] [get_bd_pins $irq_concat/In1]
connect_bd_net [get_bd_pins $vdma/mm2s_introut] [get_bd_pins $irq_concat/In2]
connect_bd_net [get_bd_pins $irq_concat/dout] [get_bd_pins $ps/IRQ_F2P]

set clk150 [get_bd_pins $ps/FCLK_CLK0]
set rst150n [get_bd_pins $rst150/peripheral_aresetn]
set rst150h [get_bd_pins $rst150/peripheral_reset]
connect_bd_net $clk150 \
    [get_bd_pins $ps/M_AXI_GP0_ACLK] [get_bd_pins $ps/S_AXI_ACP_ACLK] \
    [get_bd_pins $ps/S_AXI_HP1_ACLK] [get_bd_pins $rst150/slowest_sync_clk] \
    [get_bd_pins $dma/s_axi_lite_aclk] [get_bd_pins $dma/m_axi_mm2s_aclk] \
    [get_bd_pins $dma/m_axi_s2mm_aclk] [get_bd_pins $rx/aclk] \
    [get_bd_pins $vdma/s_axi_lite_aclk] [get_bd_pins $vdma/m_axi_mm2s_aclk] \
    [get_bd_pins $vdma/m_axis_mm2s_aclk] \
    [get_bd_pins $video_cdc/s_axis_aclk] [get_bd_pins $hp0/aclk] \
    [get_bd_pins $hp1/aclk] [get_bd_pins $gp0/aclk] \
    [get_bd_pins $status_gpio/s_axi_aclk] [get_bd_pins $hdmi_gpio/s_axi_aclk] \
    [get_bd_pins $key_regs/s_axi_aclk] [get_bd_pins $error_gpio/s_axi_aclk] \
    [get_bd_pins $video_clk/clk_in1]
connect_bd_net [get_bd_pins $ps/FCLK_RESET0_N] [get_bd_pins $rst150/ext_reset_in]
connect_bd_net $rst150h [get_bd_pins $video_clk/reset]
connect_bd_net $rst150n \
    [get_bd_pins $dma/axi_resetn] [get_bd_pins $rx/aresetn] \
    [get_bd_pins $vdma/axi_resetn] [get_bd_pins $video_cdc/s_axis_aresetn] \
    [get_bd_pins $hp0/aresetn] [get_bd_pins $hp1/aresetn] \
    [get_bd_pins $gp0/aresetn] [get_bd_pins $status_gpio/s_axi_aresetn] \
    [get_bd_pins $hdmi_gpio/s_axi_aresetn] [get_bd_pins $key_regs/s_axi_aresetn] \
    [get_bd_pins $error_gpio/s_axi_aresetn]

set pixclk [get_bd_pins $video_clk/clk_out1]
set pixrstn [get_bd_pins $rst_video/peripheral_aresetn]
connect_bd_net $pixclk \
    [get_bd_pins $rst_video/slowest_sync_clk] \
    [get_bd_pins $video_cdc/m_axis_aclk] \
    [get_bd_pins $yuyv_rgb/aclk] [get_bd_pins $vid_out/aclk] \
    [get_bd_pins $timing/aclk] [get_bd_pins $hdmi_diag/aclk] \
    [get_bd_pins $dvi/PixelClk]
connect_bd_net [get_bd_pins $video_clk/locked] [get_bd_pins $rst_video/dcm_locked]
connect_bd_net [get_bd_pins $ps/FCLK_RESET0_N] [get_bd_pins $rst_video/ext_reset_in]
connect_bd_net $pixrstn [get_bd_pins $video_cdc/m_axis_aresetn] \
    [get_bd_pins $yuyv_rgb/aresetn] [get_bd_pins $vid_out/aresetn] \
    [get_bd_pins $timing/aresetn] [get_bd_pins $hdmi_diag/aresetn] \
    [get_bd_pins $dvi/aRst_n]
assign_bd_address -offset 0x40400000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps/Data] [get_bd_addr_segs $dma/S_AXI_LITE/Reg] -force
assign_bd_address -offset 0x43000000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps/Data] [get_bd_addr_segs $vdma/S_AXI_LITE/Reg] -force
assign_bd_address -offset 0x41200000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps/Data] [get_bd_addr_segs $status_gpio/S_AXI/Reg] -force
assign_bd_address -offset 0x41220000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps/Data] [get_bd_addr_segs $error_gpio/S_AXI/Reg] -force
assign_bd_address -offset 0x41210000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps/Data] [get_bd_addr_segs $hdmi_gpio/S_AXI/Reg] -force
assign_bd_address -offset 0x43d00000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps/Data] \
    [get_bd_addr_segs -of_objects [get_bd_intf_pins $key_regs/S_AXI]] -force
assign_bd_address -offset 0x00000000 -range 0x40000000 \
    -target_address_space [get_bd_addr_spaces $dma/Data_MM2S] [get_bd_addr_segs $ps/S_AXI_ACP/ACP_DDR_LOWOCM] -force
assign_bd_address -offset 0x00000000 -range 0x40000000 \
    -target_address_space [get_bd_addr_spaces $dma/Data_S2MM] [get_bd_addr_segs $ps/S_AXI_ACP/ACP_DDR_LOWOCM] -force
assign_bd_address -offset 0x00000000 -range 0x40000000 \
    -target_address_space [get_bd_addr_spaces $vdma/Data_MM2S] [get_bd_addr_segs $ps/S_AXI_HP1/HP1_DDR_LOWOCM] -force

validate_bd_design
save_bd_design
generate_target all [get_files aes_gcm_rx_system.bd]
make_wrapper -files [get_files aes_gcm_rx_system.bd] -top
add_files -norecurse [file join $project_dir AES_GCM_RX.gen sources_1 bd aes_gcm_rx_system hdl aes_gcm_rx_system_wrapper.v]
set_property top aes_gcm_rx_system_wrapper [current_fileset]
update_compile_order -fileset sources_1
write_bd_tcl -force [file join $script_dir AES_GCM_RX_bd.tcl]
file mkdir [file join $vivado_dir artifacts]
write_hw_platform -fixed -force -file [file join $vivado_dir artifacts AES_GCM_RX_prebuild.xsa]
puts "AES_GCM_RX project created at $project_dir"

