set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
open_project [file join $vivado_dir project AES_GCM_TX.xpr]
foreach run_name {synth_1 impl_1} {
    set run [get_runs $run_name]
    puts "RUN_STATUS $run_name status=[get_property STATUS $run] progress=[get_property PROGRESS $run] needs_refresh=[get_property NEEDS_REFRESH $run]"
}
