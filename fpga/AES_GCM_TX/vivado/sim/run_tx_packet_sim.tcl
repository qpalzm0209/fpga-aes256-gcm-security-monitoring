set sim_dir [file dirname [file normalize [info script]]]
set rtl_dir [file normalize [file join $sim_dir .. rtl aes256_gcm]]
set work_dir [file join $sim_dir xsim_work]
file delete -force $work_dir
file mkdir $work_dir
cd $work_dir

set sources [list \
    [file join $rtl_dir aes_key_rcon_pkg.sv] \
    [file join $rtl_dir aes_sbox_pkg.sv] \
    [file join $rtl_dir gcm_protocol_pkg.sv] \
    [file join $rtl_dir aes_addroundkey.sv] \
    [file join $rtl_dir aes_mixcolumns.sv] \
    [file join $rtl_dir aes_next_round_key.sv] \
    [file join $rtl_dir aes_round.sv] \
    [file join $rtl_dir aes_shiftrows.sv] \
    [file join $rtl_dir aes_subbytes.sv] \
    [file join $rtl_dir aes_subword32.sv] \
    [file join $rtl_dir aes256_iterative_core.sv] \
    [file join $rtl_dir aes256_key_expansion.sv] \
    [file join $rtl_dir aes256_key_transform.sv] \
    [file join $rtl_dir ghash_mul16.sv] \
    [file join $rtl_dir video_aes_gcm_tx_top.sv] \
    [file join $sim_dir tb_video_aes_gcm_tx_top.sv]]

foreach source $sources {
  if {[catch {exec xvlog -sv $source} output]} {
    puts $output
    error "xvlog failed: $source"
  }
}
if {[catch {exec xelab tb_video_aes_gcm_tx_top -timescale 1ns/1ps -s tx_packet_sim} output]} {
  puts $output
  error "xelab failed"
}
if {[catch {exec xsim tx_packet_sim -runall} output]} {
  puts $output
  error "xsim failed"
}
puts $output
