set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
set artifact_dir [file join $vivado_dir artifacts]

open_project [file join $vivado_dir project AES_GCM_RX.xpr]

set hp0_run aes_gcm_rx_system_axi_hp0_0_synth_1
reset_run $hp0_run
launch_runs $hp0_run -jobs 1
wait_on_run $hp0_run
if {[get_property STATUS [get_runs $hp0_run]] ne "synth_design Complete!"} {
    error "HP0 OOC synthesis failed: [get_property STATUS [get_runs $hp0_run]]"
}

reset_run synth_1
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "top synthesis failed: [get_property STATUS [get_runs synth_1]]"
}

set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    error "implementation failed: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
file mkdir $artifact_dir
write_bitstream -force [file join $artifact_dir AES_GCM_RX.bit]
write_hw_platform -fixed -include_bit -force \
    -file [file join $artifact_dir AES_GCM_RX.xsa]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $artifact_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $artifact_dir utilization.rpt]
report_drc -file [file join $artifact_dir drc.rpt]
puts "RX_HDMI_REBUILD_COMPLETE=1"
