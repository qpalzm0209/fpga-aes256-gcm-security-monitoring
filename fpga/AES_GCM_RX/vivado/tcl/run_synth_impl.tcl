set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
open_project [file join $vivado_dir project AES_GCM_RX.xpr]
set reuse_synth [expr {[lsearch -exact $argv -reuse_synth] >= 0}]
# Clear an interrupted parent first; otherwise Vivado can refuse to reset an
# OOC child while synth_1 is still recorded as Queued/Running.
if {!$reuse_synth} {
    reset_run synth_1
    foreach custom_run {
        aes_gcm_rx_system_gcm_rx_slot_0_synth_1
        aes_gcm_rx_system_aes_session_key_regs_0_0_synth_1
        aes_gcm_rx_system_yuyv_to_rgb_0_synth_1
    } {
        if {[llength [get_runs -quiet $custom_run]]} {reset_run $custom_run}
    }
    # Vivado 2025.2 on Windows intermittently corrupts the Tcl-app temporary
    # path when two OOC runs overlap ("Failed to create directory 'C'").
    # Keep the complete RX synthesis reproducible by allowing one worker only.
    launch_runs synth_1 -jobs 1
    wait_on_run synth_1
}
set synth_status [get_property STATUS [get_runs synth_1]]
puts "AES_GCM_RX synth status = $synth_status"
if {!$reuse_synth && $synth_status ne "synth_design Complete!"} {error "synthesis failed"}
if {$reuse_synth && ![llength [glob -nocomplain [file join $vivado_dir project \
        AES_GCM_RX.runs synth_1 *.dcp]]]} {error "reusable top synthesis DCP is missing"}
# Publish module-reference checkpoints into the BD generated products. Vivado
# 2025.2 can leave only the OOC-run copy for large SystemVerilog references and
# then reject the integrated implementation as a black box.
foreach component {
    aes_gcm_rx_system_aes_session_key_regs_0_0
    aes_gcm_rx_system_gcm_rx_slot_0
} {
    set run_name ${component}_synth_1
    set dcp_name ${component}.dcp
    set run_dcp [file join $vivado_dir project AES_GCM_RX.runs \
        $run_name $dcp_name]
    set gen_dir [file join $vivado_dir project AES_GCM_RX.gen sources_1 bd \
        aes_gcm_rx_system ip $component]
    if {![file exists $run_dcp]} {error "missing completed module DCP: $run_dcp"}
    file mkdir $gen_dir
    open_run $run_name
    write_checkpoint -force [file join $gen_dir $dcp_name]
    write_verilog -force -mode synth_stub [file join $gen_dir ${component}_stub.v]
    write_vhdl -force -mode synth_stub [file join $gen_dir ${component}_stub.vhdl]
    write_verilog -force -mode funcsim [file join $gen_dir ${component}_sim_netlist.v]
    write_vhdl -force -mode funcsim [file join $gen_dir ${component}_sim_netlist.vhdl]
    close_design
}
# The integrated RX design is routing-constrained around the AES key scheduler.
# Run post-route physical optimization so the delivered 150 MHz build must close,
# rather than accepting a functionally generated bitstream with negative slack.
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {error "implementation failed"}
open_run impl_1
set worst_setup_path [get_timing_paths -delay_type max -max_paths 1]
if {![llength $worst_setup_path]} {error "no setup timing path found"}
set worst_setup_slack [get_property SLACK $worst_setup_path]
puts "AES_GCM_RX final setup WNS = $worst_setup_slack ns"
if {$worst_setup_slack < 0.0} {error "150 MHz implementation timing failed"}
set worst_hold_path [get_timing_paths -delay_type min -max_paths 1]
if {![llength $worst_hold_path]} {error "no hold timing path found"}
set worst_hold_slack [get_property SLACK $worst_hold_path]
puts "AES_GCM_RX final hold WHS = $worst_hold_slack ns"
if {$worst_hold_slack < 0.0} {error "implementation hold timing failed"}
file mkdir [file join $vivado_dir artifacts]
write_bitstream -force [file join $vivado_dir artifacts AES_GCM_RX.bit]
write_hw_platform -fixed -include_bit -force -file [file join $vivado_dir artifacts AES_GCM_RX.xsa]
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $vivado_dir artifacts timing_summary.rpt]
report_route_status -file [file join $vivado_dir artifacts route_status.rpt]
report_bus_skew -warn_on_violation -file [file join $vivado_dir artifacts bus_skew.rpt]
report_utilization -hierarchical -file [file join $vivado_dir artifacts utilization.rpt]
report_drc -file [file join $vivado_dir artifacts drc.rpt]
set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $drc_errors]} {error "implementation has DRC errors: $drc_errors"}
