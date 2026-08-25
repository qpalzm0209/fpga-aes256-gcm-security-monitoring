set sim_dir [file dirname [file normalize [info script]]]
set aes_dir [file normalize [file join $sim_dir .. rtl aes256_gcm]]
set tx_dir [file normalize [file join $sim_dir .. rtl tx]]
set video_dir [file normalize [file join $sim_dir .. rtl video]]
set work_dir [file join $sim_dir xsim_camera_fifo_work]
file delete -force $work_dir
file mkdir $work_dir
cd $work_dir

set sources [list \
    [file join $aes_dir aes_key_rcon_pkg.sv] \
    [file join $aes_dir aes_sbox_pkg.sv] \
    [file join $aes_dir gcm_protocol_pkg.sv] \
    [file join $aes_dir aes_addroundkey.sv] \
    [file join $aes_dir aes_mixcolumns.sv] \
    [file join $aes_dir aes_next_round_key.sv] \
    [file join $aes_dir aes_round.sv] \
    [file join $aes_dir aes_shiftrows.sv] \
    [file join $aes_dir aes_subbytes.sv] \
    [file join $aes_dir aes_subword32.sv] \
    [file join $aes_dir aes256_iterative_core.sv] \
    [file join $aes_dir aes256_key_expansion.sv] \
    [file join $aes_dir aes256_key_transform.sv] \
    [file join $aes_dir ghash_mul16.sv] \
    [file join $aes_dir video_aes_gcm_tx_top.sv] \
    [file join $tx_dir axis_gcm_tx_frame_processor_v1.sv] \
    [file join $video_dir axis_video16_to_frame128.sv] \
    [file join $sim_dir tb_tx_camera_realtime_fifo.sv]]

foreach source $sources {
  if {[catch {exec xvlog -sv $source} output]} {
    puts $output
    error "xvlog failed: $source"
  }
}
if {[catch {exec xelab tb_tx_camera_realtime_fifo -timescale 1ns/1ps \
            -s tx_camera_fifo_sim} output]} {
  puts $output
  error "xelab failed"
}
if {[catch {exec xsim tx_camera_fifo_sim -runall} output]} {
  puts $output
  error "xsim failed"
}
puts $output

