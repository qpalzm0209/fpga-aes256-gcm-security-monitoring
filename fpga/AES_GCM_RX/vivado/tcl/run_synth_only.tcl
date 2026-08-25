set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
open_project [file join $vivado_dir project AES_GCM_RX.xpr]
# Module-reference OOC runs do not always notice an edited source timestamp on
# Windows.  Reset the two local RTL modules explicitly; vendor IP stays cached.
foreach custom_run {
    aes_gcm_rx_system_gcm_rx_slot_0_synth_1
    aes_gcm_rx_system_yuyv_to_rgb_0_synth_1
} {
    if {[llength [get_runs -quiet $custom_run]]} {reset_run $custom_run}
}
reset_run synth_1
# Vivado 2025.2 on Windows can race while parallel OOC workers load the
# per-user Tcl app cache (symptom: "Could not open 'C' for writing").
launch_runs synth_1 -jobs 1
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {$synth_status ne "synth_design Complete!"} {
    error "synthesis failed: $synth_status"
}
puts "AES_GCM_RX synthesis complete"
