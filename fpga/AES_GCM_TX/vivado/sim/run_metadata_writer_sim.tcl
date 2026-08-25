set sim_dir [file dirname [file normalize [info script]]]
set work_dir [file join $sim_dir metadata_writer_work]
file delete -force $work_dir
file mkdir $work_dir
cd $work_dir
exec xvlog [file normalize [file join $sim_dir .. rtl video axis_metadata_bram_writer.v]]
exec xvlog -sv [file join $sim_dir tb_axis_metadata_bram_writer.sv]
exec xelab tb_axis_metadata_bram_writer -timescale 1ns/1ps -s metadata_writer_sim
if {[catch {exec xsim metadata_writer_sim -runall} output]} {
  puts $output
  error "metadata writer simulation failed"
}
puts $output
