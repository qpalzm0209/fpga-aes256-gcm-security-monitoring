set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
open_project [file join $vivado_dir project AES_GCM_TX.xpr]
# The AES wrapper is synthesized out-of-context inside the block design.
# Reset it explicitly so edits to the engine/adapter cannot leave a stale DCP
# in an otherwise fresh top-level bitstream.
# Clear an interrupted parent run first; Vivado otherwise refuses to reset
# an OOC child while synth_1 is left in the Queued state.
reset_run synth_1
foreach custom_run {
    pcam_system_yuv422_tx_health_0_synth_1
    pcam_system_yuv422_video16_to_frame128_0_synth_1
    pcam_system_yuv422_gcm_tx_slot_0_synth_1
    pcam_system_yuv422_frame128_to_video16_0_synth_1
    pcam_system_yuv422_aes_session_key_regs_0_0_synth_1
    pcam_system_yuv422_metadata_writer_0_synth_1
} {
    if {[llength [get_runs -quiet $custom_run]]} {reset_run $custom_run}
}
# Vivado 2025.2 on Windows can corrupt concurrent OOC Tcl-app temp paths
# ("Could not open 'C'" / "Failed to create directory 'C'").  A single
# worker is deliberate: -jobs 2 still launches two OOC Vivado processes.
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "synthesis failed"
}
# Vivado 2025.2 can leave a module-reference OOC checkpoint in the run
# directory without publishing its generated products into the BD directory.
# Top synthesis tolerates the stub, but implementation rejects the black box.
set key_dcp_name pcam_system_yuv422_aes_session_key_regs_0_0.dcp
set key_run_dcp [file join $vivado_dir project AES_GCM_TX.runs \
    pcam_system_yuv422_aes_session_key_regs_0_0_synth_1 $key_dcp_name]
set key_gen_dir [file join $vivado_dir project AES_GCM_TX.gen sources_1 bd \
    pcam_system_yuv422 ip pcam_system_yuv422_aes_session_key_regs_0_0]
if {![file exists $key_run_dcp]} {error "missing completed key-register DCP"}
file mkdir $key_gen_dir
open_run pcam_system_yuv422_aes_session_key_regs_0_0_synth_1
write_checkpoint -force [file join $key_gen_dir $key_dcp_name]
write_verilog -force -mode synth_stub [file join $key_gen_dir \
    pcam_system_yuv422_aes_session_key_regs_0_0_stub.v]
write_vhdl -force -mode synth_stub [file join $key_gen_dir \
    pcam_system_yuv422_aes_session_key_regs_0_0_stub.vhdl]
write_verilog -force -mode funcsim [file join $key_gen_dir \
    pcam_system_yuv422_aes_session_key_regs_0_0_sim_netlist.v]
write_vhdl -force -mode funcsim [file join $key_gen_dir \
    pcam_system_yuv422_aes_session_key_regs_0_0_sim_netlist.vhdl]
close_design
# Keep the integrated 150 MHz AES path timing-clean after placement with the
# camera/DDR system, including a post-route physical optimization pass.
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
write_hw_platform -fixed -include_bit -force -file [file join $vivado_dir artifacts AES_GCM_TX.xsa]
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $vivado_dir artifacts timing_summary.rpt]
report_route_status -file [file join $vivado_dir artifacts route_status.rpt]
report_bus_skew -warn_on_violation -file [file join $vivado_dir artifacts bus_skew.rpt]
report_utilization -hierarchical -file [file join $vivado_dir artifacts utilization.rpt]
report_drc -file [file join $vivado_dir artifacts drc.rpt]
set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $drc_errors]} {error "implementation has DRC errors: $drc_errors"}
