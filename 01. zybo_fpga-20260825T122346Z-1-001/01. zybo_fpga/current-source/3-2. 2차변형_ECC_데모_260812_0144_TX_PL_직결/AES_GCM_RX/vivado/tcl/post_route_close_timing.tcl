set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
set project_dir [file join $vivado_dir project]
set run_dir [file join $project_dir AES_GCM_RX.runs impl_1]
set artifacts [file join $vivado_dir artifacts]

open_project [file join $project_dir AES_GCM_RX.xpr]
open_checkpoint [file join $run_dir aes_gcm_rx_system_wrapper_routed.dcp]

phys_opt_design -directive AggressiveExplore
set worst_path [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
set wns [get_property SLACK $worst_path]
puts "POST_ROUTE_WNS=$wns"
if {$wns < 0.0} {
    error "150 MHz timing still fails after post-route physical optimization: WNS=$wns"
}

file mkdir $artifacts
write_checkpoint -force [file join $artifacts AES_GCM_RX_routed.dcp]
write_bitstream -force [file join $artifacts AES_GCM_RX.bit]
write_hw_platform -fixed -include_bit -force \
    -file [file join $artifacts AES_GCM_RX.xsa]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $artifacts timing_summary.rpt]
report_utilization -hierarchical \
    -file [file join $artifacts utilization.rpt]
report_drc -file [file join $artifacts drc.rpt]
puts "POST_ROUTE_ARTIFACTS_READY=1"
