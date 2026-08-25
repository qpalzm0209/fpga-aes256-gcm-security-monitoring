set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]

open_project [file join $vivado_dir project AES_GCM_TX.xpr]
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

# Opening a project while generated products were absent marks the top stale.
# Re-run only the top synthesis; completed OOC children remain intact.
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!" ||
    [get_property NEEDS_REFRESH [get_runs synth_1]]} {
    reset_run synth_1
    launch_runs synth_1 -jobs 2
    wait_on_run synth_1
}
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "synth_1 is not complete"
}

reset_run impl_1
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
if {$impl_status ne "write_bitstream Complete!"} {
    error "implementation failed: $impl_status"
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
puts "AES_GCM_TX implementation and artifact export complete"
