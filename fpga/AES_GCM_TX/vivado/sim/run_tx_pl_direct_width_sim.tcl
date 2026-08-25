set sim_dir [file dirname [file normalize [info script]]]
set vivado_dir [file normalize [file join $sim_dir ..]]
set work_dir [file join $sim_dir xsim_tx_pl_direct_width_work]
file delete -force $work_dir
file mkdir $work_dir
cd $work_dir

set sources [list \
    [file join $vivado_dir rtl video axis_video16_to_frame128.sv] \
    [file join $vivado_dir rtl video axis_frame128_to_video16.sv] \
    [file join $vivado_dir tb tb_axis_video_frame_width_bridge.sv]]

foreach source $sources {
    if {[catch {exec xvlog -sv $source} output]} {
        puts $output
        error "xvlog failed: $source"
    }
}
if {[catch {exec xelab tb_axis_video_frame_width_bridge \
            -timescale 1ns/1ps -s tx_pl_direct_width_sim} output]} {
    puts $output
    error "xelab failed"
}
if {[catch {exec xsim tx_pl_direct_width_sim -runall} output]} {
    puts $output
    error "xsim failed"
}
puts $output
