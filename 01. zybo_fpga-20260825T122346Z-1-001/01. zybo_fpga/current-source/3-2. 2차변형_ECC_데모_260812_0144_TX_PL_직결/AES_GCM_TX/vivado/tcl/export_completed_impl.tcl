set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
open_project [file join $vivado_dir project AES_GCM_TX.xpr]
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    error "impl_1 is not complete"
}
open_run impl_1
set artifact_dir [file join $vivado_dir artifacts]
file mkdir $artifact_dir
write_bitstream -force [file join $artifact_dir AES_GCM_TX.bit]
write_hw_platform -fixed -include_bit -force -file [file join $artifact_dir AES_GCM_TX.xsa]
report_timing_summary -delay_type max -max_paths 20 -file [file join $artifact_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $artifact_dir utilization.rpt]
report_drc -file [file join $artifact_dir drc.rpt]
puts "AES_GCM_TX completed implementation exported"
