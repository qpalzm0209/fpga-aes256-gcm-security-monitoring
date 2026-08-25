set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
open_project [file join $vivado_dir project AES_GCM_RX.xpr]
reset_run impl_1
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    error "implementation failed"
}
open_run impl_1
file mkdir [file join $vivado_dir artifacts]
write_bitstream -force [file join $vivado_dir artifacts AES_GCM_RX.bit]
write_hw_platform -fixed -include_bit -force -file [file join $vivado_dir artifacts AES_GCM_RX.xsa]
report_timing_summary -delay_type max -max_paths 20 -file [file join $vivado_dir artifacts timing_summary.rpt]
report_utilization -hierarchical -file [file join $vivado_dir artifacts utilization.rpt]
report_drc -file [file join $vivado_dir artifacts drc.rpt]
