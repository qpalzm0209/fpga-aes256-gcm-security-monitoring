set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
open_project [file join $vivado_dir project AES_GCM_RX.xpr]
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "synth_1 is not complete"
}
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
if {$impl_status ne "write_bitstream Complete!"} {
    error "implementation failed: $impl_status"
}
open_run impl_1
set worst_setup_slack [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
if {$worst_setup_slack < 0.0} {
    error "timing signoff failed: WNS=$worst_setup_slack ns"
}
set artifact_dir [file join $vivado_dir artifacts]
file mkdir $artifact_dir
write_bitstream -force [file join $artifact_dir AES_GCM_RX.bit]
write_hw_platform -fixed -include_bit -force -file [file join $artifact_dir AES_GCM_RX.xsa]
report_timing_summary -delay_type max -max_paths 20 -file [file join $artifact_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $artifact_dir utilization.rpt]
report_drc -file [file join $artifact_dir drc.rpt]
puts "AES_GCM_RX implementation and artifact export complete"
