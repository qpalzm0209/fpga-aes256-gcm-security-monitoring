set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
open_project [file join $vivado_dir project AES_GCM_TX.xpr]

# Only the module-reference TX slot changed.  Preserve all unrelated camera,
# PS, DMA and clocking OOC checkpoints, but force both the slot and parent
# netlist to consume the edited RTL.
reset_run synth_1
set slot_run pcam_system_yuv422_gcm_tx_slot_0_synth_1
if {![llength [get_runs -quiet $slot_run]]} {
    error "missing TX slot synthesis run"
}
reset_run $slot_run
launch_runs synth_1 -jobs 2
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "TX slot/top synthesis failed"
}

reset_run impl_1
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    error "TX slot implementation failed"
}

open_run impl_1
set worst_setup_path [get_timing_paths -delay_type max -max_paths 1]
if {![llength $worst_setup_path]} {error "no setup timing path found"}
set worst_setup_slack [get_property SLACK $worst_setup_path]
puts "AES_GCM_TX final setup WNS = $worst_setup_slack ns"
if {$worst_setup_slack < 0.0} {error "150 MHz implementation timing failed"}

set artifact_dir [file join $vivado_dir artifacts]
file mkdir $artifact_dir
write_bitstream -force [file join $artifact_dir AES_GCM_TX.bit]
write_hw_platform -fixed -include_bit -force -file [file join $artifact_dir AES_GCM_TX.xsa]
report_timing_summary -delay_type max -max_paths 20 -file [file join $artifact_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $artifact_dir utilization.rpt]
report_drc -file [file join $artifact_dir drc.rpt]
puts "AES_GCM_TX slot rebuild and artifact export complete"
