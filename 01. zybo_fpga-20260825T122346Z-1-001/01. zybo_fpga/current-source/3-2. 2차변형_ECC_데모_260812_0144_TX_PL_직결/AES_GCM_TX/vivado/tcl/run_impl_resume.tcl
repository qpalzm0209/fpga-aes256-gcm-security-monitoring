set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]

open_project [file join $vivado_dir project AES_GCM_TX.xpr]

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "completed synth_1 checkpoint is required before implementation resume"
}

# Vivado 2025.2 on Windows can occasionally leave implementation queued after
# a long single-worker OOC synthesis batch.  Reset only the unstarted impl run;
# all completed synthesis checkpoints remain intact.
reset_run impl_1
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    error "implementation failed"
}

open_run impl_1
set worst_setup_path [get_timing_paths -delay_type max -max_paths 1]
if {![llength $worst_setup_path]} {error "no setup timing path found"}
set worst_setup_slack [get_property SLACK $worst_setup_path]
puts "AES_GCM_TX final setup WNS = $worst_setup_slack ns"
if {$worst_setup_slack < 0.0} {error "150 MHz implementation timing failed"}

set worst_hold_path [get_timing_paths -delay_type min -max_paths 1]
if {![llength $worst_hold_path]} {error "no hold timing path found"}
set worst_hold_slack [get_property SLACK $worst_hold_path]
puts "AES_GCM_TX final hold WHS = $worst_hold_slack ns"
if {$worst_hold_slack < 0.0} {error "implementation hold timing failed"}

file mkdir [file join $vivado_dir artifacts]
write_bitstream -force [file join $vivado_dir artifacts AES_GCM_TX.bit]
write_hw_platform -fixed -include_bit -force \
    -file [file join $vivado_dir artifacts AES_GCM_TX.xsa]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $vivado_dir artifacts timing_summary.rpt]
report_route_status -file [file join $vivado_dir artifacts route_status.rpt]
report_bus_skew -warn_on_violation \
    -file [file join $vivado_dir artifacts bus_skew.rpt]
report_utilization -hierarchical \
    -file [file join $vivado_dir artifacts utilization.rpt]
report_drc -file [file join $vivado_dir artifacts drc.rpt]

set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $drc_errors]} {error "implementation has DRC errors: $drc_errors"}

puts "AES_GCM_TX IMPLEMENTATION RESUME PASS"
close_project
exit
