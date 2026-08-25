# Derived from the Digilent Zybo Z7 Rev. B master constraint definitions.
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports sw3_decrypt]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports sw2_session_start]

set_property -dict {PACKAGE_PIN H17 IOSTANDARD TMDS_33} [get_ports TMDS_clk_n]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD TMDS_33} [get_ports TMDS_clk_p]
set_property -dict {PACKAGE_PIN D20 IOSTANDARD TMDS_33} [get_ports {TMDS_data_n[0]}]
set_property -dict {PACKAGE_PIN D19 IOSTANDARD TMDS_33} [get_ports {TMDS_data_p[0]}]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD TMDS_33} [get_ports {TMDS_data_n[1]}]
set_property -dict {PACKAGE_PIN C20 IOSTANDARD TMDS_33} [get_ports {TMDS_data_p[1]}]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD TMDS_33} [get_ports {TMDS_data_n[2]}]
set_property -dict {PACKAGE_PIN B19 IOSTANDARD TMDS_33} [get_ports {TMDS_data_p[2]}]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
