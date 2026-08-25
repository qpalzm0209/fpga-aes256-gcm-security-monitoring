# AES_GCM_TX reproducible build, Vivado 2025.2, Zybo Z7-20.
# The camera stream is encrypted in PL before the Frame Buffer Write reaches
# DDR.  The legacy DDR->DMA->AES-GCM->DMA->DDR round trip is not instantiated.

set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
set project_dir [file join $vivado_dir project]
set rtl_dir [file join $vivado_dir rtl]
set xdc_file [file join $vivado_dir constraints pcam_tx_pins.xdc]

create_project -force AES_GCM_TX $project_dir -part xc7z020clg400-1
# The global Windows IP cache can retain host paths containing spaces/Unicode
# and emit "Could not open 'C'".  A clean shared build must synthesize locally.
config_ip_cache -disable_cache
set_property BOARD_PART digilentinc.com:zybo-z7-20:part0:1.2 [current_project]
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

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
    [file join $rtl_dir aes256_gcm video_aes_gcm_tx_top.sv] \
    [file join $rtl_dir tx axis_gcm_tx_frame_processor_v1.sv] \
    [file join $rtl_dir video axis_video16_to_frame128.sv] \
    [file join $rtl_dir video axis_frame128_to_video16.sv] \
    [file join $rtl_dir session aes_session_key_regs.sv]]
add_files -norecurse $ordered_sv
add_files -norecurse [list \
    [file join $rtl_dir tx axis_gcm_tx_frame_processor_bd.v] \
    [file join $rtl_dir session aes_session_key_regs_bd.v] \
    [file join $rtl_dir video axis_video16_to_frame128_bd.v] \
    [file join $rtl_dir video axis_frame128_to_video16_bd.v] \
    [file join $rtl_dir video axis_video_aes_gcm_switch_bd.v] \
    [file join $rtl_dir video axis_metadata_bram_writer.v] \
    [file join $rtl_dir video metadata_status_cdc.v] \
    [file join $rtl_dir video tx_pipeline_health_status.v]]
set_property file_type SystemVerilog [get_files $ordered_sv]
add_files -fileset constrs_1 -norecurse $xdc_file
update_compile_order -fileset sources_1
set_property top axis_video_aes_gcm_switch_bd [current_fileset]
update_compile_order -fileset sources_1

source [file join $script_dir pcam_system_yuv422_base_bd.tcl]
current_bd_design pcam_system_yuv422
set sw2_session [create_bd_port -dir I sw2_session_start]
set btn3_terminate [create_bd_port -dir I btn3_session_terminate]

# Remove the old semantic-video bypass cell.  Its two AXIS endpoints are
# replaced by an explicit 16->128 packer, the frame GCM engine, and a
# 128->16 unpacker.  In encryption mode no camera plaintext reaches DDR.
set old_camera_net [get_bd_intf_nets -of_objects \
    [get_bd_intf_pins video_aes_gcm_switch/s_axis]]
set old_framebuffer_net [get_bd_intf_nets -of_objects \
    [get_bd_intf_pins video_aes_gcm_switch/m_axis]]
disconnect_bd_intf_net $old_camera_net \
    [get_bd_intf_pins video_aes_gcm_switch/s_axis]
disconnect_bd_intf_net $old_framebuffer_net \
    [get_bd_intf_pins video_aes_gcm_switch/m_axis]
delete_bd_objs $old_camera_net
delete_bd_objs $old_framebuffer_net
delete_bd_objs [get_bd_cells video_aes_gcm_switch]

# Add GP0 slaves for session/status GPIO and metadata RAM.  M07 is the
# session register bank; the former AXI DMA control port no longer exists.
set_property CONFIG.NUM_MI {8} [get_bd_cells ps7_0_axi_periph]
set_property CONFIG.NUM_SI {1} [get_bd_cells axi_mem_hp0]
set video_pack [create_bd_cell -type module \
    -reference axis_video16_to_frame128_bd video16_to_frame128]
set tx_slot [create_bd_cell -type module -reference axis_gcm_tx_frame_processor_bd gcm_tx_slot]
set video_unpack [create_bd_cell -type module \
    -reference axis_frame128_to_video16_bd frame128_to_video16]
set ingress_fifo [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axis_data_fifo:2.0 camera_to_gcm_fifo]
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {16} \
    CONFIG.FIFO_DEPTH {8192} \
    CONFIG.FIFO_MODE {1} \
    CONFIG.IS_ACLK_ASYNC {0} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.HAS_WR_DATA_COUNT {1} \
    CONFIG.HAS_PROG_FULL {1} \
    CONFIG.PROG_FULL_THRESH {7680} \
    CONFIG.FIFO_MEMORY_TYPE {block}] $ingress_fifo
set key_regs [create_bd_cell -type module -reference aes_session_key_regs_bd aes_session_key_regs_0]
set health_status [create_bd_cell -type module \
    -reference tx_pipeline_health_status tx_health]
set crypto_runtime_reset [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_crypto_runtime_150M]
set_property -dict [list CONFIG.C_AUX_RESET_HIGH {0} \
    CONFIG.RESET_BOARD_INTERFACE {Custom}] $crypto_runtime_reset

set meta_gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 meta_session_status_gpio]
set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {32} \
    CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_ALL_INPUTS_2 {1}] $meta_gpio

set bram_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 metadata_bram_ctrl]
set_property -dict [list \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.ECC_TYPE {0}] $bram_ctrl

set meta_mem [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 metadata_bram]
set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Use_Byte_Write_Enable {true} \
    CONFIG.Byte_Size {8} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Write_Depth_A {32768} \
    CONFIG.Read_Width_A {32} \
    CONFIG.Write_Width_B {32} \
    CONFIG.Read_Width_B {32} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false}] $meta_mem

set meta_writer [create_bd_cell -type module -reference axis_metadata_bram_writer metadata_writer]
set status_cdc [create_bd_cell -type module -reference metadata_status_cdc metadata_status_cdc_0]

connect_bd_intf_net [get_bd_intf_pins yuv422_axis_norm/M_AXIS] \
    [get_bd_intf_pins $video_pack/s_axis]
connect_bd_intf_net [get_bd_intf_pins $video_pack/m_axis] \
    [get_bd_intf_pins $ingress_fifo/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins $ingress_fifo/M_AXIS] \
    [get_bd_intf_pins $tx_slot/s_axis]
connect_bd_intf_net [get_bd_intf_pins $tx_slot/m_axis] \
    [get_bd_intf_pins $video_unpack/s_axis]
connect_bd_intf_net [get_bd_intf_pins $video_unpack/m_axis] \
    [get_bd_intf_pins axis_yuv422_16_to_24/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M07_AXI] \
    [get_bd_intf_pins $key_regs/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $tx_slot/m_meta] [get_bd_intf_pins metadata_writer/s_meta]
connect_bd_intf_net [get_bd_intf_pins metadata_writer/bram] [get_bd_intf_pins metadata_bram/BRAM_PORTB]
connect_bd_intf_net [get_bd_intf_pins metadata_bram_ctrl/BRAM_PORTA] [get_bd_intf_pins metadata_bram/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M05_AXI] [get_bd_intf_pins meta_session_status_gpio/S_AXI]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M06_AXI] [get_bd_intf_pins metadata_bram_ctrl/S_AXI]

connect_bd_net [get_bd_pins $key_regs/active_session_id] [get_bd_pins $tx_slot/session_id]
connect_bd_net [get_bd_pins $health_status/status] \
    [get_bd_pins meta_session_status_gpio/gpio_io_i]
connect_bd_net [get_bd_pins $ingress_fifo/axis_wr_data_count] \
    [get_bd_pins $health_status/fifo_level]
connect_bd_net [get_bd_pins $ingress_fifo/prog_full] \
    [get_bd_pins $health_status/fifo_near_full]
connect_bd_net [get_bd_pins $video_pack/protocol_error] \
    [get_bd_pins $health_status/pack_protocol_error]
connect_bd_net [get_bd_pins $tx_slot/protocol_error] \
    [get_bd_pins $health_status/crypto_protocol_error]
connect_bd_net [get_bd_pins $video_unpack/protocol_error] \
    [get_bd_pins $health_status/unpack_protocol_error]
connect_bd_net [get_bd_pins $key_regs/active_key] [get_bd_pins $tx_slot/session_key]
connect_bd_net [get_bd_pins $key_regs/active_key_valid] [get_bd_pins $tx_slot/session_key_valid]
connect_bd_net [get_bd_pins $key_regs/key_commit_pulse] [get_bd_pins $tx_slot/key_commit]
connect_bd_net [get_bd_pins $key_regs/key_clear_pulse] [get_bd_pins $tx_slot/key_clear]
connect_bd_net [get_bd_pins $tx_slot/key_ready] [get_bd_pins $key_regs/engine_key_ready]
connect_bd_net [get_bd_pins $tx_slot/busy] [get_bd_pins $key_regs/engine_busy]
connect_bd_net $sw2_session [get_bd_pins $key_regs/session_start_switch]
connect_bd_net $btn3_terminate [get_bd_pins $key_regs/session_terminate_button]
connect_bd_net [get_bd_ports sw3_encrypt] [get_bd_pins $tx_slot/sw3_encrypt]
connect_bd_net [get_bd_pins $tx_slot/active_frame_id] [get_bd_pins metadata_writer/frame_id]
connect_bd_net [get_bd_pins $tx_slot/active_frame_encrypted] [get_bd_pins metadata_writer/frame_encrypted]
connect_bd_net [get_bd_pins metadata_writer/status] [get_bd_pins metadata_status_cdc_0/src_status]
connect_bd_net [get_bd_pins metadata_status_cdc_0/dst_status] [get_bd_pins meta_session_status_gpio/gpio2_io_i]
set clk100 [get_bd_pins processing_system7_0/FCLK_CLK0]
set clk150 [get_bd_pins clk_wiz_video_150/clk_out1]
set rst100n [get_bd_pins rst_ps7_0_100M/peripheral_aresetn]
set rst150n [get_bd_pins rst_video_150M/peripheral_aresetn]
connect_bd_net $clk150 \
    [get_bd_pins $video_pack/aclk] [get_bd_pins $tx_slot/aclk] \
    [get_bd_pins $video_unpack/aclk] [get_bd_pins $ingress_fifo/s_axis_aclk] \
    [get_bd_pins $health_status/aclk] [get_bd_pins metadata_writer/aclk] \
    [get_bd_pins $key_regs/s_axi_aclk] [get_bd_pins ps7_0_axi_periph/M07_ACLK] \
    [get_bd_pins metadata_status_cdc_0/src_clk] \
    [get_bd_pins $crypto_runtime_reset/slowest_sync_clk]
connect_bd_net $rst150n \
    [get_bd_pins $key_regs/s_axi_aresetn] \
    [get_bd_pins ps7_0_axi_periph/M07_ARESETN]
connect_bd_net [get_bd_pins $crypto_runtime_reset/peripheral_aresetn] \
    [get_bd_pins $video_pack/aresetn] [get_bd_pins $tx_slot/aresetn] \
    [get_bd_pins $video_unpack/aresetn] [get_bd_pins $ingress_fifo/s_axis_aresetn] \
    [get_bd_pins $health_status/aresetn] [get_bd_pins metadata_writer/aresetn]
connect_bd_net [get_bd_pins clk_wiz_video_150/locked] \
    [get_bd_pins $crypto_runtime_reset/dcm_locked]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
    [get_bd_pins $crypto_runtime_reset/ext_reset_in]
connect_bd_net [get_bd_pins axi_gpio_frmbuf_reset/gpio_io_o] \
    [get_bd_pins $crypto_runtime_reset/aux_reset_in]
connect_bd_net $clk100 \
    [get_bd_pins meta_session_status_gpio/s_axi_aclk] \
    [get_bd_pins metadata_bram_ctrl/s_axi_aclk] \
    [get_bd_pins metadata_status_cdc_0/dst_clk] \
    [get_bd_pins ps7_0_axi_periph/M05_ACLK] \
    [get_bd_pins ps7_0_axi_periph/M06_ACLK]
connect_bd_net $rst100n \
    [get_bd_pins meta_session_status_gpio/s_axi_aresetn] \
    [get_bd_pins metadata_bram_ctrl/s_axi_aresetn] \
    [get_bd_pins metadata_status_cdc_0/dst_resetn] \
    [get_bd_pins ps7_0_axi_periph/M05_ARESETN] \
    [get_bd_pins ps7_0_axi_periph/M06_ARESETN]

assign_bd_address -offset 0x41220000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs meta_session_status_gpio/S_AXI/Reg] -force
assign_bd_address -offset 0x42000000 -range 0x00020000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs metadata_bram_ctrl/S_AXI/Mem0] -force
assign_bd_address -offset 0x43d00000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs -of_objects [get_bd_intf_pins $key_regs/S_AXI]] -force

validate_bd_design
save_bd_design
generate_target all [get_files pcam_system_yuv422.bd]
make_wrapper -files [get_files pcam_system_yuv422.bd] -top
add_files -norecurse [file join $project_dir AES_GCM_TX.gen sources_1 bd pcam_system_yuv422 hdl pcam_system_yuv422_wrapper.v]
set_property top pcam_system_yuv422_wrapper [current_fileset]
update_compile_order -fileset sources_1

write_bd_tcl -force [file join $script_dir AES_GCM_TX_bd.tcl]
file mkdir [file join $vivado_dir artifacts]
write_hw_platform -fixed -force -file [file join $vivado_dir artifacts AES_GCM_TX_prebuild.xsa]
puts "AES_GCM_TX project created at $project_dir"
