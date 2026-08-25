# Zybo Z7-20 PCam connector.  The top-level port names are created by
# create_pcam_design.tcl's MIPI/I2C interface ports.
set_property INTERNAL_VREF 0.6 [get_iobanks 35]

set_property -dict {PACKAGE_PIN J19 IOSTANDARD HSUL_12} [get_ports dphy_clk_lp_n]
set_property -dict {PACKAGE_PIN H20 IOSTANDARD HSUL_12} [get_ports dphy_clk_lp_p]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD HSUL_12} [get_ports {dphy_data_lp_n[0]}]
set_property -dict {PACKAGE_PIN L19 IOSTANDARD HSUL_12} [get_ports {dphy_data_lp_p[0]}]
set_property -dict {PACKAGE_PIN L20 IOSTANDARD HSUL_12} [get_ports {dphy_data_lp_n[1]}]
set_property -dict {PACKAGE_PIN J20 IOSTANDARD HSUL_12} [get_ports {dphy_data_lp_p[1]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVDS_25} [get_ports dphy_clk_hs_n]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVDS_25} [get_ports dphy_clk_hs_p]
set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVDS_25} [get_ports {dphy_data_hs_n[0]}]
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVDS_25} [get_ports {dphy_data_hs_p[0]}]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVDS_25} [get_ports {dphy_data_hs_n[1]}]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVDS_25} [get_ports {dphy_data_hs_p[1]}]

set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33 PULLUP true} [get_ports pcam_iic_scl_io]
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33 PULLUP true} [get_ports pcam_iic_sda_io]
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33} [get_ports pcam_reset_n]

# Zybo Z7 Rev. B master XDC: SW3 is package pin T16.  The RTL synchronizes
# this asynchronous board input and samples it only at video frame boundaries.
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports sw3_encrypt]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports sw2_session_start]
# BTN3 (Y16) remains constrained for board compatibility, but the TX role
# wrapper disables the button input. Press/release has no session or key effect.
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} [get_ports btn3_session_terminate]

# The Linux Frame Buffer driver intentionally drives ap_rst_n from this AXI
# GPIO. It is an asynchronous reset control, not a 100 MHz to 150 MHz data
# transfer. Exclude only this single GPIO register's reset fanout; all video,
# AXI-Lite, AXI-MM, and clock-converter paths remain timed normally.
set_false_path -to [get_pins -hier -filter {NAME =~ *v_frmbuf_wr_0*/R}]
