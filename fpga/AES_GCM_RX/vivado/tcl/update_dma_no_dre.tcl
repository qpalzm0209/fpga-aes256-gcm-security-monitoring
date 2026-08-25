set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
open_project [file join $vivado_dir project AES_GCM_RX.xpr]
open_bd_design [file join $vivado_dir project AES_GCM_RX.srcs sources_1 bd aes_gcm_rx_system aes_gcm_rx_system.bd]
set dma [get_bd_cells axi_dma_packet]
set_property -dict [list \
    CONFIG.c_include_mm2s_dre {0} \
    CONFIG.c_include_s2mm_dre {0} \
    CONFIG.c_sg_length_width {21}] $dma
validate_bd_design
save_bd_design
generate_target all [get_files aes_gcm_rx_system.bd]

set dma_run aes_gcm_rx_system_axi_dma_packet_0_synth_1
if {[llength [get_runs -quiet $dma_run]]} {reset_run $dma_run}
reset_run synth_1
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "DMA no-DRE synthesis failed"
}
puts "AXI DMA DRE disabled and synthesis complete"
