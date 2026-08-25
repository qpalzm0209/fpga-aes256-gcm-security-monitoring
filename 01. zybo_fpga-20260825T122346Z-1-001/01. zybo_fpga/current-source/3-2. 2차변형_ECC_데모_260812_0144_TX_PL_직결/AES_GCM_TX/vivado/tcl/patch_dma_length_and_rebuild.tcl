set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
set project_file [file join $vivado_dir project AES_GCM_TX.xpr]
set bd_file [file join $vivado_dir project AES_GCM_TX.srcs sources_1 bd pcam_system_yuv422 pcam_system_yuv422.bd]

open_project $project_file
open_bd_design $bd_file
set dma [get_bd_cells axi_dma_gcm_tx]
set_property CONFIG.c_sg_length_width {23} $dma
validate_bd_design
save_bd_design
generate_target all [get_files $bd_file]

# The interface is unchanged, so only the DMA OOC checkpoint and the parent
# synthesis/implementation runs need rebuilding.  All other OOC DCPs remain
# valid and are reused.
reset_run synth_1
set dma_run pcam_system_yuv422_axi_dma_gcm_tx_0_synth_1
if {[llength [get_runs -quiet $dma_run]]} {
    reset_run $dma_run
}
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "synthesis failed"
}

set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "implementation failed"
}

open_run impl_1
file mkdir [file join $vivado_dir artifacts]
write_bitstream -force [file join $vivado_dir artifacts AES_GCM_TX.bit]
write_hw_platform -fixed -include_bit -force -file [file join $vivado_dir artifacts AES_GCM_TX.xsa]
report_timing_summary -delay_type max -max_paths 20 -file [file join $vivado_dir artifacts timing_summary.rpt]
report_utilization -hierarchical -file [file join $vivado_dir artifacts utilization.rpt]
report_drc -file [file join $vivado_dir artifacts drc.rpt]
