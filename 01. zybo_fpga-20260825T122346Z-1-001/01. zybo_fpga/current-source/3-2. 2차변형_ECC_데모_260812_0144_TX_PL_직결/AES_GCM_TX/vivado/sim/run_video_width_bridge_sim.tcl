set sim_dir [file dirname [file normalize [info script]]]
set rtl_dir [file normalize [file join $sim_dir .. rtl video]]
set tb_dir [file normalize [file join $sim_dir .. tb]]
set work_dir [file join $sim_dir xsim_width_bridge_work]
file delete -force $work_dir
file mkdir $work_dir
cd $work_dir

foreach source [list \
    [file join $rtl_dir axis_video16_to_frame128.sv] \
    [file join $rtl_dir axis_frame128_to_video16.sv] \
    [file join $tb_dir tb_axis_video_frame_width_bridge.sv]] {
  if {[catch {exec xvlog -sv $source} output]} {
    puts $output
    error "xvlog failed: $source"
  }
}
if {[catch {exec xelab tb_axis_video_frame_width_bridge \
            -timescale 1ns/1ps -s width_bridge_sim} output]} {
  puts $output
  error "xelab failed"
}
if {[catch {exec xsim width_bridge_sim -runall} output]} {
  puts $output
  error "xsim failed"
}
puts $output

