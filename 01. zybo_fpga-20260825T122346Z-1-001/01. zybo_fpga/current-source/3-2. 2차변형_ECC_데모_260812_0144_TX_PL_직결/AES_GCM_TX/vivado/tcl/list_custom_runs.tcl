set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $script_dir ..]]
open_project [file join $vivado_dir project AES_GCM_TX.xpr]
foreach run [get_runs -filter {IS_SYNTHESIS == 1}] {
    set name [get_property NAME $run]
    if {[string match "*gcm*" $name] || [string match "*metadata*" $name]} {
        puts "CUSTOM_RUN $name"
    }
}
