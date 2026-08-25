
################################################################
# This is a generated script based on design: aes_gcm_rx_system
#
# Though there are limitations about the generated script,
# the main purpose of this utility is to make learning
# IP Integrator Tcl commands easier.
################################################################

namespace eval _tcl {
proc get_script_folder {} {
   set script_path [file normalize [info script]]
   set script_folder [file dirname $script_path]
   return $script_folder
}
}
variable script_folder
set script_folder [_tcl::get_script_folder]

################################################################
# Check if script is running in correct Vivado version.
################################################################
set scripts_vivado_version 2025.2
set current_vivado_version [version -short]

if { [string first $scripts_vivado_version $current_vivado_version] == -1 } {
   puts ""
   if { [string compare $scripts_vivado_version $current_vivado_version] > 0 } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2042 -severity "ERROR" " This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version> of Vivado. Sourcing the script failed since it was created with a future version of Vivado."}

   } else {
     catch {common::send_gid_msg -ssname BD::TCL -id 2041 -severity "ERROR" "This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version> of Vivado. Please run the script in Vivado <$scripts_vivado_version> then open the design in Vivado <$current_vivado_version>. Upgrade the design by running \"Tools => Report => Report IP Status...\", then run write_bd_tcl to create an updated script."}

   }

   return 1
}

################################################################
# START
################################################################

# To test this script, run the following commands from Vivado Tcl console:
# source aes_gcm_rx_system_script.tcl


# The design that will be created by this Tcl script contains the following 
# module references:
# axis_gcm_rx_frame_processor_bd, axis_yuyv32_to_rgb24, video_timing_720p, hdmi_status_pack, aes_session_key_regs_bd

# Please add the sources of those modules before sourcing this Tcl script.

# If there is no project opened, this script will create a
# project, but make sure you do not have an existing project
# <./myproj/project_1.xpr> in the current working folder.

set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
   create_project project_1 myproj -part xc7z020clg400-1
   set_property BOARD_PART digilentinc.com:zybo-z7-20:part0:1.2 [current_project]
}


# CHANGE DESIGN NAME HERE
variable design_name
set design_name aes_gcm_rx_system

# If you do not already have an existing IP Integrator design open,
# you can create a design using the following command:
#    create_bd_design $design_name

# Creating design if needed
set errMsg ""
set nRet 0

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

if { ${design_name} eq "" } {
   # USE CASES:
   #    1) Design_name not set

   set errMsg "Please set the variable <design_name> to a non-empty value."
   set nRet 1

} elseif { ${cur_design} ne "" && ${list_cells} eq "" } {
   # USE CASES:
   #    2): Current design opened AND is empty AND names same.
   #    3): Current design opened AND is empty AND names diff; design_name NOT in project.
   #    4): Current design opened AND is empty AND names diff; design_name exists in project.

   if { $cur_design ne $design_name } {
      common::send_gid_msg -ssname BD::TCL -id 2001 -severity "INFO" "Changing value of <design_name> from <$design_name> to <$cur_design> since current design is empty."
      set design_name [get_property NAME $cur_design]
   }
   common::send_gid_msg -ssname BD::TCL -id 2002 -severity "INFO" "Constructing design in IPI design <$cur_design>..."

} elseif { ${cur_design} ne "" && $list_cells ne "" && $cur_design eq $design_name } {
   # USE CASES:
   #    5) Current design opened AND has components AND same names.

   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 1
} elseif { [get_files -quiet ${design_name}.bd] ne "" } {
   # USE CASES: 
   #    6) Current opened design, has components, but diff names, design_name exists in project.
   #    7) No opened design, design_name exists in project.

   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 2

} else {
   # USE CASES:
   #    8) No opened design, design_name not in project.
   #    9) Current opened design, has components, but diff names, design_name not in project.

   common::send_gid_msg -ssname BD::TCL -id 2003 -severity "INFO" "Currently there is no design <$design_name> in project, so creating one..."

   create_bd_design $design_name

   common::send_gid_msg -ssname BD::TCL -id 2004 -severity "INFO" "Making design <$design_name> as current_bd_design."
   current_bd_design $design_name

}

common::send_gid_msg -ssname BD::TCL -id 2005 -severity "INFO" "Currently the variable <design_name> is equal to \"$design_name\"."

if { $nRet != 0 } {
   catch {common::send_gid_msg -ssname BD::TCL -id 2006 -severity "ERROR" $errMsg}
   return $nRet
}

set bCheckIPsPassed 1
##################################################################
# CHECK IPs
##################################################################
set bCheckIPs 1
if { $bCheckIPs == 1 } {
   set list_check_ips "\ 
xilinx.com:ip:processing_system7:5.5\
xilinx.com:ip:proc_sys_reset:5.0\
xilinx.com:ip:clk_wiz:6.0\
xilinx.com:ip:axi_dma:7.1\
xilinx.com:ip:axi_vdma:6.3\
xilinx.com:ip:axis_clock_converter:1.1\
xilinx.com:ip:v_axi4s_vid_out:4.0\
digilentinc.com:ip:rgb2dvi:1.4\
xilinx.com:ip:smartconnect:1.0\
xilinx.com:ip:axi_gpio:2.0\
xilinx.com:ip:xlconcat:2.1\
"

   set list_ips_missing ""
   common::send_gid_msg -ssname BD::TCL -id 2011 -severity "INFO" "Checking if the following IPs exist in the project's IP catalog: $list_check_ips ."

   foreach ip_vlnv $list_check_ips {
      set ip_obj [get_ipdefs -all $ip_vlnv]
      if { $ip_obj eq "" } {
         lappend list_ips_missing $ip_vlnv
      }
   }

   if { $list_ips_missing ne "" } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2012 -severity "ERROR" "The following IPs are not found in the IP Catalog:\n  $list_ips_missing\n\nResolution: Please add the repository containing the IP(s) to the project." }
      set bCheckIPsPassed 0
   }

}

##################################################################
# CHECK Modules
##################################################################
set bCheckModules 1
if { $bCheckModules == 1 } {
   set list_check_mods "\ 
axis_gcm_rx_frame_processor_bd\
axis_yuyv32_to_rgb24\
video_timing_720p\
hdmi_status_pack\
aes_session_key_regs_bd\
"

   set list_mods_missing ""
   common::send_gid_msg -ssname BD::TCL -id 2020 -severity "INFO" "Checking if the following modules exist in the project's sources: $list_check_mods ."

   foreach mod_vlnv $list_check_mods {
      if { [can_resolve_reference $mod_vlnv] == 0 } {
         lappend list_mods_missing $mod_vlnv
      }
   }

   if { $list_mods_missing ne "" } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2021 -severity "ERROR" "The following module(s) are not found in the project: $list_mods_missing" }
      common::send_gid_msg -ssname BD::TCL -id 2022 -severity "INFO" "Please add source files for the missing module(s) above."
      set bCheckIPsPassed 0
   }
}

if { $bCheckIPsPassed != 1 } {
  common::send_gid_msg -ssname BD::TCL -id 2023 -severity "WARNING" "Will not continue with creation of design due to the error(s) above."
  return 3
}

##################################################################
# DESIGN PROCs
##################################################################



# Procedure to create entire design; Provide argument to make
# procedure reusable. If parentCell is "", will use root.
proc create_root_design { parentCell } {

  variable script_folder
  variable design_name

  if { $parentCell eq "" } {
     set parentCell [get_bd_cells /]
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj


  # Create interface ports
  set DDR [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR ]

  set FIXED_IO [ create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO ]

  set DDR_0 [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR_0 ]

  set FIXED_IO_0 [ create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO_0 ]

  set TMDS [ create_bd_intf_port -mode Master -vlnv digilentinc.com:interface:tmds_rtl:1.0 TMDS ]


  # Create ports
  set sw3_decrypt [ create_bd_port -dir I sw3_decrypt ]
  set sw2_session_start [ create_bd_port -dir I sw2_session_start ]

  # Create instance: processing_system7_0, and set properties
  set processing_system7_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0 ]
  set_property -dict [list \
    CONFIG.PCW_ACT_APU_PERIPHERAL_FREQMHZ {600.000000} \
    CONFIG.PCW_ACT_CAN_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_DCI_PERIPHERAL_FREQMHZ {10.158730} \
    CONFIG.PCW_ACT_ENET0_PERIPHERAL_FREQMHZ {125.000000} \
    CONFIG.PCW_ACT_ENET1_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ {150.000000} \
    CONFIG.PCW_ACT_FPGA1_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA2_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA3_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_PCAP_PERIPHERAL_FREQMHZ {200.000000} \
    CONFIG.PCW_ACT_QSPI_PERIPHERAL_FREQMHZ {200.000000} \
    CONFIG.PCW_ACT_SDIO_PERIPHERAL_FREQMHZ {50.000000} \
    CONFIG.PCW_ACT_SMC_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_SPI_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_TPIU_PERIPHERAL_FREQMHZ {200.000000} \
    CONFIG.PCW_ACT_TTC0_CLK0_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_ACT_TTC0_CLK1_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_ACT_TTC0_CLK2_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_ACT_TTC1_CLK0_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_ACT_TTC1_CLK1_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_ACT_TTC1_CLK2_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_ACT_UART_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_ACT_WDT_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_APU_CLK_RATIO_ENABLE {6:2:1} \
    CONFIG.PCW_APU_PERIPHERAL_FREQMHZ {600.000000} \
    CONFIG.PCW_CLK0_FREQ {150000000} \
    CONFIG.PCW_CLK1_FREQ {10000000} \
    CONFIG.PCW_CLK2_FREQ {10000000} \
    CONFIG.PCW_CLK3_FREQ {10000000} \
    CONFIG.PCW_CPU_CPU_6X4X_MAX_RANGE {667} \
    CONFIG.PCW_CPU_PERIPHERAL_CLKSRC {ARM PLL} \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
    CONFIG.PCW_DCI_PERIPHERAL_CLKSRC {DDR PLL} \
    CONFIG.PCW_DCI_PERIPHERAL_FREQMHZ {10.159} \
    CONFIG.PCW_DDR_PERIPHERAL_CLKSRC {DDR PLL} \
    CONFIG.PCW_DDR_RAM_HIGHADDR {0x3FFFFFFF} \
    CONFIG.PCW_ENET0_ENET0_IO {MIO 16 .. 27} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO {MIO 52 .. 53} \
    CONFIG.PCW_ENET0_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_ENET0_PERIPHERAL_FREQMHZ {1000 Mbps} \
    CONFIG.PCW_ENET0_RESET_ENABLE {0} \
    CONFIG.PCW_ENET1_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_ENET1_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_ENET_RESET_ENABLE {1} \
    CONFIG.PCW_ENET_RESET_POLARITY {Active Low} \
    CONFIG.PCW_ENET_RESET_SELECT {Share reset pin} \
    CONFIG.PCW_EN_4K_TIMER {0} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_ENET0 {1} \
    CONFIG.PCW_EN_GPIO {1} \
    CONFIG.PCW_EN_QSPI {1} \
    CONFIG.PCW_EN_SDIO0 {1} \
    CONFIG.PCW_EN_UART1 {1} \
    CONFIG.PCW_EN_USB0 {1} \
    CONFIG.PCW_FCLK0_PERIPHERAL_CLKSRC {ARM PLL} \
    CONFIG.PCW_FCLK_CLK0_BUF {TRUE} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {150.000000} \
    CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
    CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {1} \
    CONFIG.PCW_GPIO_MIO_GPIO_IO {MIO} \
    CONFIG.PCW_GPIO_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_I2C_RESET_ENABLE {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_IRQ_F2P_MODE {DIRECT} \
    CONFIG.PCW_MIO_0_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_0_PULLUP {enabled} \
    CONFIG.PCW_MIO_0_SLEW {slow} \
    CONFIG.PCW_MIO_10_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_10_PULLUP {enabled} \
    CONFIG.PCW_MIO_10_SLEW {slow} \
    CONFIG.PCW_MIO_11_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_11_PULLUP {enabled} \
    CONFIG.PCW_MIO_11_SLEW {slow} \
    CONFIG.PCW_MIO_12_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_12_PULLUP {enabled} \
    CONFIG.PCW_MIO_12_SLEW {slow} \
    CONFIG.PCW_MIO_13_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_13_PULLUP {enabled} \
    CONFIG.PCW_MIO_13_SLEW {slow} \
    CONFIG.PCW_MIO_14_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_14_PULLUP {enabled} \
    CONFIG.PCW_MIO_14_SLEW {slow} \
    CONFIG.PCW_MIO_15_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_15_PULLUP {enabled} \
    CONFIG.PCW_MIO_15_SLEW {slow} \
    CONFIG.PCW_MIO_16_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_16_PULLUP {enabled} \
    CONFIG.PCW_MIO_16_SLEW {fast} \
    CONFIG.PCW_MIO_17_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_17_PULLUP {enabled} \
    CONFIG.PCW_MIO_17_SLEW {fast} \
    CONFIG.PCW_MIO_18_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_18_PULLUP {enabled} \
    CONFIG.PCW_MIO_18_SLEW {fast} \
    CONFIG.PCW_MIO_19_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_19_PULLUP {enabled} \
    CONFIG.PCW_MIO_19_SLEW {fast} \
    CONFIG.PCW_MIO_1_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_1_PULLUP {enabled} \
    CONFIG.PCW_MIO_1_SLEW {slow} \
    CONFIG.PCW_MIO_20_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_20_PULLUP {enabled} \
    CONFIG.PCW_MIO_20_SLEW {fast} \
    CONFIG.PCW_MIO_21_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_21_PULLUP {enabled} \
    CONFIG.PCW_MIO_21_SLEW {fast} \
    CONFIG.PCW_MIO_22_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_22_PULLUP {enabled} \
    CONFIG.PCW_MIO_22_SLEW {fast} \
    CONFIG.PCW_MIO_23_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_23_PULLUP {enabled} \
    CONFIG.PCW_MIO_23_SLEW {fast} \
    CONFIG.PCW_MIO_24_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_24_PULLUP {enabled} \
    CONFIG.PCW_MIO_24_SLEW {fast} \
    CONFIG.PCW_MIO_25_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_25_PULLUP {enabled} \
    CONFIG.PCW_MIO_25_SLEW {fast} \
    CONFIG.PCW_MIO_26_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_26_PULLUP {enabled} \
    CONFIG.PCW_MIO_26_SLEW {fast} \
    CONFIG.PCW_MIO_27_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_27_PULLUP {enabled} \
    CONFIG.PCW_MIO_27_SLEW {fast} \
    CONFIG.PCW_MIO_28_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_28_PULLUP {enabled} \
    CONFIG.PCW_MIO_28_SLEW {fast} \
    CONFIG.PCW_MIO_29_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_29_PULLUP {enabled} \
    CONFIG.PCW_MIO_29_SLEW {fast} \
    CONFIG.PCW_MIO_2_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_2_SLEW {slow} \
    CONFIG.PCW_MIO_30_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_30_PULLUP {enabled} \
    CONFIG.PCW_MIO_30_SLEW {fast} \
    CONFIG.PCW_MIO_31_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_31_PULLUP {enabled} \
    CONFIG.PCW_MIO_31_SLEW {fast} \
    CONFIG.PCW_MIO_32_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_32_PULLUP {enabled} \
    CONFIG.PCW_MIO_32_SLEW {fast} \
    CONFIG.PCW_MIO_33_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_33_PULLUP {enabled} \
    CONFIG.PCW_MIO_33_SLEW {fast} \
    CONFIG.PCW_MIO_34_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_34_PULLUP {enabled} \
    CONFIG.PCW_MIO_34_SLEW {fast} \
    CONFIG.PCW_MIO_35_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_35_PULLUP {enabled} \
    CONFIG.PCW_MIO_35_SLEW {fast} \
    CONFIG.PCW_MIO_36_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_36_PULLUP {enabled} \
    CONFIG.PCW_MIO_36_SLEW {fast} \
    CONFIG.PCW_MIO_37_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_37_PULLUP {enabled} \
    CONFIG.PCW_MIO_37_SLEW {fast} \
    CONFIG.PCW_MIO_38_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_38_PULLUP {enabled} \
    CONFIG.PCW_MIO_38_SLEW {fast} \
    CONFIG.PCW_MIO_39_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_39_PULLUP {enabled} \
    CONFIG.PCW_MIO_39_SLEW {fast} \
    CONFIG.PCW_MIO_3_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_3_SLEW {slow} \
    CONFIG.PCW_MIO_40_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_40_PULLUP {enabled} \
    CONFIG.PCW_MIO_40_SLEW {slow} \
    CONFIG.PCW_MIO_41_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_41_PULLUP {enabled} \
    CONFIG.PCW_MIO_41_SLEW {slow} \
    CONFIG.PCW_MIO_42_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_42_PULLUP {enabled} \
    CONFIG.PCW_MIO_42_SLEW {slow} \
    CONFIG.PCW_MIO_43_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_43_PULLUP {enabled} \
    CONFIG.PCW_MIO_43_SLEW {slow} \
    CONFIG.PCW_MIO_44_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_44_PULLUP {enabled} \
    CONFIG.PCW_MIO_44_SLEW {slow} \
    CONFIG.PCW_MIO_45_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_45_PULLUP {enabled} \
    CONFIG.PCW_MIO_45_SLEW {slow} \
    CONFIG.PCW_MIO_46_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_46_PULLUP {enabled} \
    CONFIG.PCW_MIO_46_SLEW {slow} \
    CONFIG.PCW_MIO_47_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_47_PULLUP {enabled} \
    CONFIG.PCW_MIO_47_SLEW {slow} \
    CONFIG.PCW_MIO_48_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_48_PULLUP {enabled} \
    CONFIG.PCW_MIO_48_SLEW {slow} \
    CONFIG.PCW_MIO_49_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_49_PULLUP {enabled} \
    CONFIG.PCW_MIO_49_SLEW {slow} \
    CONFIG.PCW_MIO_4_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_4_SLEW {slow} \
    CONFIG.PCW_MIO_50_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_50_PULLUP {enabled} \
    CONFIG.PCW_MIO_50_SLEW {slow} \
    CONFIG.PCW_MIO_51_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_51_PULLUP {enabled} \
    CONFIG.PCW_MIO_51_SLEW {slow} \
    CONFIG.PCW_MIO_52_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_52_PULLUP {enabled} \
    CONFIG.PCW_MIO_52_SLEW {slow} \
    CONFIG.PCW_MIO_53_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_53_PULLUP {enabled} \
    CONFIG.PCW_MIO_53_SLEW {slow} \
    CONFIG.PCW_MIO_5_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_5_SLEW {slow} \
    CONFIG.PCW_MIO_6_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_6_SLEW {slow} \
    CONFIG.PCW_MIO_7_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_7_SLEW {slow} \
    CONFIG.PCW_MIO_8_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_8_SLEW {slow} \
    CONFIG.PCW_MIO_9_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_9_PULLUP {enabled} \
    CONFIG.PCW_MIO_9_SLEW {slow} \
    CONFIG.PCW_MIO_TREE_PERIPHERALS {GPIO#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#GPIO#Quad SPI Flash#GPIO#GPIO#GPIO#GPIO#GPIO#GPIO#GPIO#Enet 0#Enet 0#Enet\
0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#SD 0#SD 0#SD 0#SD 0#SD 0#SD 0#USB Reset#SD 0#UART 1#UART 1#GPIO#GPIO#Enet\
0#Enet 0} \
    CONFIG.PCW_MIO_TREE_SIGNALS {gpio[0]#qspi0_ss_b#qspi0_io[0]#qspi0_io[1]#qspi0_io[2]#qspi0_io[3]/HOLD_B#qspi0_sclk#gpio[7]#qspi_fbclk#gpio[9]#gpio[10]#gpio[11]#gpio[12]#gpio[13]#gpio[14]#gpio[15]#tx_clk#txd[0]#txd[1]#txd[2]#txd[3]#tx_ctl#rx_clk#rxd[0]#rxd[1]#rxd[2]#rxd[3]#rx_ctl#data[4]#dir#stp#nxt#data[0]#data[1]#data[2]#data[3]#clk#data[5]#data[6]#data[7]#clk#cmd#data[0]#data[1]#data[2]#data[3]#reset#cd#tx#rx#gpio[50]#gpio[51]#mdc#mdio}\
\
    CONFIG.PCW_OVERRIDE_BASIC_CLOCK {0} \
    CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY0 {0.221} \
    CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY1 {0.222} \
    CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY2 {0.217} \
    CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY3 {0.244} \
    CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_0 {-0.050} \
    CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_1 {-0.044} \
    CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_2 {-0.035} \
    CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_3 {-0.100} \
    CONFIG.PCW_PCAP_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_PCAP_PERIPHERAL_FREQMHZ {200} \
    CONFIG.PCW_PJTAG_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_PLL_BYPASSMODE_ENABLE {0} \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} \
    CONFIG.PCW_QSPI_GRP_FBCLK_ENABLE {1} \
    CONFIG.PCW_QSPI_GRP_FBCLK_IO {MIO 8} \
    CONFIG.PCW_QSPI_GRP_IO1_ENABLE {0} \
    CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE {1} \
    CONFIG.PCW_QSPI_GRP_SINGLE_SS_IO {MIO 1 .. 6} \
    CONFIG.PCW_QSPI_GRP_SS1_ENABLE {0} \
    CONFIG.PCW_QSPI_INTERNAL_HIGHADDRESS {0xFCFFFFFF} \
    CONFIG.PCW_QSPI_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_QSPI_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_QSPI_PERIPHERAL_FREQMHZ {200} \
    CONFIG.PCW_QSPI_QSPI_IO {MIO 1 .. 6} \
    CONFIG.PCW_SD0_GRP_CD_ENABLE {1} \
    CONFIG.PCW_SD0_GRP_CD_IO {MIO 47} \
    CONFIG.PCW_SD0_GRP_POW_ENABLE {0} \
    CONFIG.PCW_SD0_GRP_WP_ENABLE {0} \
    CONFIG.PCW_SD0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_SD0_SD0_IO {MIO 40 .. 45} \
    CONFIG.PCW_SDIO_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_SDIO_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_SDIO_PERIPHERAL_VALID {1} \
    CONFIG.PCW_SINGLE_QSPI_DATA_MODE {x4} \
    CONFIG.PCW_SMC_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_S_AXI_ACP_ARUSER_VAL {1} \
    CONFIG.PCW_S_AXI_ACP_AWUSER_VAL {1} \
    CONFIG.PCW_TPIU_PERIPHERAL_CLKSRC {External} \
    CONFIG.PCW_UART0_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_UART1_BAUD_RATE {115200} \
    CONFIG.PCW_UART1_GRP_FULL_ENABLE {0} \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART1_UART1_IO {MIO 48 .. 49} \
    CONFIG.PCW_UART_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_UART_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_UART_PERIPHERAL_VALID {1} \
    CONFIG.PCW_UIPARAM_ACT_DDR_FREQ_MHZ {533.333374} \
    CONFIG.PCW_UIPARAM_DDR_ADV_ENABLE {0} \
    CONFIG.PCW_UIPARAM_DDR_AL {0} \
    CONFIG.PCW_UIPARAM_DDR_BL {8} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY0 {0.221} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY1 {0.222} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY2 {0.217} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY3 {0.244} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {32 Bit} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_0_LENGTH_MM {18.8} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_0_PACKAGE_LENGTH {80.4535} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_0_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_1_LENGTH_MM {18.8} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_1_PACKAGE_LENGTH {80.4535} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_1_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_2_LENGTH_MM {18.8} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_2_PACKAGE_LENGTH {80.4535} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_2_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_3_LENGTH_MM {18.8} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_3_PACKAGE_LENGTH {80.4535} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_3_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_CLOCK_STOP_EN {0} \
    CONFIG.PCW_UIPARAM_DDR_DQS_0_LENGTH_MM {22.8} \
    CONFIG.PCW_UIPARAM_DDR_DQS_0_PACKAGE_LENGTH {105.056} \
    CONFIG.PCW_UIPARAM_DDR_DQS_0_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_DQS_1_LENGTH_MM {27.9} \
    CONFIG.PCW_UIPARAM_DDR_DQS_1_PACKAGE_LENGTH {66.904} \
    CONFIG.PCW_UIPARAM_DDR_DQS_1_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_DQS_2_LENGTH_MM {22.9} \
    CONFIG.PCW_UIPARAM_DDR_DQS_2_PACKAGE_LENGTH {89.1715} \
    CONFIG.PCW_UIPARAM_DDR_DQS_2_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_DQS_3_LENGTH_MM {29.4} \
    CONFIG.PCW_UIPARAM_DDR_DQS_3_PACKAGE_LENGTH {113.63} \
    CONFIG.PCW_UIPARAM_DDR_DQS_3_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_0 {-0.050} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_1 {-0.044} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_2 {-0.035} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_3 {-0.100} \
    CONFIG.PCW_UIPARAM_DDR_DQ_0_LENGTH_MM {22.8} \
    CONFIG.PCW_UIPARAM_DDR_DQ_0_PACKAGE_LENGTH {98.503} \
    CONFIG.PCW_UIPARAM_DDR_DQ_0_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_DQ_1_LENGTH_MM {27.9} \
    CONFIG.PCW_UIPARAM_DDR_DQ_1_PACKAGE_LENGTH {68.5855} \
    CONFIG.PCW_UIPARAM_DDR_DQ_1_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_DQ_2_LENGTH_MM {22.9} \
    CONFIG.PCW_UIPARAM_DDR_DQ_2_PACKAGE_LENGTH {90.295} \
    CONFIG.PCW_UIPARAM_DDR_DQ_2_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_DQ_3_LENGTH_MM {29.4} \
    CONFIG.PCW_UIPARAM_DDR_DQ_3_PACKAGE_LENGTH {103.977} \
    CONFIG.PCW_UIPARAM_DDR_DQ_3_PROPOGATION_DELAY {160} \
    CONFIG.PCW_UIPARAM_DDR_ENABLE {1} \
    CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ {533.333333} \
    CONFIG.PCW_UIPARAM_DDR_HIGH_TEMP {Normal (0-85)} \
    CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3 (Low Voltage)} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE {1} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE {1} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL {1} \
    CONFIG.PCW_UIPARAM_DDR_USE_INTERNAL_VREF {0} \
    CONFIG.PCW_USB0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_USB0_RESET_ENABLE {1} \
    CONFIG.PCW_USB0_RESET_IO {MIO 46} \
    CONFIG.PCW_USB0_USB0_IO {MIO 28 .. 39} \
    CONFIG.PCW_USB_RESET_ENABLE {1} \
    CONFIG.PCW_USB_RESET_POLARITY {Active Low} \
    CONFIG.PCW_USB_RESET_SELECT {Share reset pin} \
    CONFIG.PCW_USE_AXI_NONSECURE {0} \
    CONFIG.PCW_USE_CROSS_TRIGGER {0} \
    CONFIG.PCW_USE_DEFAULT_ACP_USER_VAL {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_ACP {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {0} \
    CONFIG.PCW_USE_S_AXI_HP1 {1} \
  ] $processing_system7_0


  # Create instance: rst_150m, and set properties
  set rst_150m [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_150m ]

  # Create instance: video_clk_74m25, and set properties
  set video_clk_74m25 [ create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 video_clk_74m25 ]
  set_property -dict [list \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {74.250} \
    CONFIG.NUM_OUT_CLKS {1} \
    CONFIG.PRIM_IN_FREQ {150.000} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {true} \
  ] $video_clk_74m25


  # Create instance: rst_video, and set properties
  set rst_video [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_video ]

  # Create instance: axi_dma_packet, and set properties
  set axi_dma_packet [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_packet ]
  set_property -dict [list \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_mm2s_dre {0} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_include_s2mm_dre {0} \
    CONFIG.c_include_sg {0} \
    CONFIG.c_m_axi_mm2s_data_width {128} \
    CONFIG.c_m_axi_s2mm_data_width {128} \
    CONFIG.c_m_axis_mm2s_tdata_width {128} \
    CONFIG.c_mm2s_burst_size {16} \
    CONFIG.c_s2mm_burst_size {16} \
    CONFIG.c_s_axis_s2mm_tdata_width {128} \
    CONFIG.c_sg_length_width {21} \
  ] $axi_dma_packet


  # Create instance: gcm_rx_slot, and set properties
  set block_name axis_gcm_rx_frame_processor_bd
  set block_cell_name gcm_rx_slot
  if { [catch {set gcm_rx_slot [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $gcm_rx_slot eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: axi_vdma_display, and set properties
  set axi_vdma_display [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma:6.3 axi_vdma_display ]
  set_property -dict [list \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_mm2s_dre {1} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_num_fstores {3} \
  ] $axi_vdma_display


  # Create instance: video_axis_150_to_74, and set properties
  set video_axis_150_to_74 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter:1.1 video_axis_150_to_74 ]
  set_property -dict [list \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.IS_ACLK_ASYNC {1} \
    CONFIG.SYNCHRONIZATION_STAGES {3} \
    CONFIG.TDATA_NUM_BYTES {4} \
    CONFIG.TUSER_WIDTH {1} \
  ] $video_axis_150_to_74


  # Create instance: yuyv_to_rgb, and set properties
  set block_name axis_yuyv32_to_rgb24
  set block_cell_name yuyv_to_rgb
  if { [catch {set yuyv_to_rgb [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $yuyv_to_rgb eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: axi4s_to_video, and set properties
  set axi4s_to_video [ create_bd_cell -type ip -vlnv xilinx.com:ip:v_axi4s_vid_out:4.0 axi4s_to_video ]
  set_property -dict [list \
    CONFIG.C_HAS_ASYNC_CLK {0} \
    CONFIG.C_NATIVE_COMPONENT_WIDTH {8} \
    CONFIG.C_S_AXIS_VIDEO_DATA_WIDTH {8} \
  ] $axi4s_to_video


  # Create instance: video_timing_720p, and set properties
  set block_name video_timing_720p
  set block_cell_name video_timing_720p
  if { [catch {set video_timing_720p [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $video_timing_720p eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: hdmi_status_pack, and set properties
  set block_name hdmi_status_pack
  set block_cell_name hdmi_status_pack
  if { [catch {set hdmi_status_pack [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $hdmi_status_pack eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: rgb2dvi_0, and set properties
  set rgb2dvi_0 [ create_bd_cell -type ip -vlnv digilentinc.com:ip:rgb2dvi:1.4 rgb2dvi_0 ]
  set_property -dict [list \
    CONFIG.kClkPrimitive {MMCM} \
    CONFIG.kClkRange {2} \
    CONFIG.kGenerateSerialClk {true} \
    CONFIG.kRstActiveHigh {false} \
  ] $rgb2dvi_0


  # Create instance: axi_hp0, and set properties
  set axi_hp0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_hp0 ]
  set_property -dict [list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {2} \
  ] $axi_hp0


  # Create instance: axi_hp1, and set properties
  set axi_hp1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_hp1 ]
  set_property -dict [list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {1} \
  ] $axi_hp1


  # Create instance: axi_gp0, and set properties
  set axi_gp0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_gp0 ]
  set_property -dict [list \
    CONFIG.NUM_MI {6} \
    CONFIG.NUM_SI {1} \
  ] $axi_gp0


  # Create instance: rx_status_gpio, and set properties
  set rx_status_gpio [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 rx_status_gpio ]
  set_property -dict [list \
    CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_GPIO_WIDTH {32} \
  ] $rx_status_gpio


  # Create instance: hdmi_status_gpio, and set properties
  set hdmi_status_gpio [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 hdmi_status_gpio ]
  set_property -dict [list \
    CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_GPIO_WIDTH {32} \
  ] $hdmi_status_gpio


  # Create instance: aes_session_key_regs_0, and set properties
  set block_name aes_session_key_regs_bd
  set block_cell_name aes_session_key_regs_0
  if { [catch {set aes_session_key_regs_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $aes_session_key_regs_0 eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: rx_error_gpio, and set properties
  set rx_error_gpio [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 rx_error_gpio ]
  set_property -dict [list \
    CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_ALL_OUTPUTS_2 {1} \
    CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_GPIO_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} \
  ] $rx_error_gpio


  # Create instance: irq_concat, and set properties
  set irq_concat [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 irq_concat ]
  set_property CONFIG.NUM_PORTS {3} $irq_concat


  # Create interface connections
  connect_bd_intf_net -intf_net axi4s_to_video_vid_io_out [get_bd_intf_pins axi4s_to_video/vid_io_out] [get_bd_intf_pins rgb2dvi_0/RGB]
  connect_bd_intf_net -intf_net axi_dma_packet_M_AXIS_MM2S [get_bd_intf_pins axi_dma_packet/M_AXIS_MM2S] [get_bd_intf_pins gcm_rx_slot/s_axis]
  connect_bd_intf_net -intf_net axi_dma_packet_M_AXI_MM2S [get_bd_intf_pins axi_dma_packet/M_AXI_MM2S] [get_bd_intf_pins axi_hp0/S00_AXI]
  connect_bd_intf_net -intf_net axi_dma_packet_M_AXI_S2MM [get_bd_intf_pins axi_dma_packet/M_AXI_S2MM] [get_bd_intf_pins axi_hp0/S01_AXI]
  connect_bd_intf_net -intf_net axi_gp0_M00_AXI [get_bd_intf_pins axi_gp0/M00_AXI] [get_bd_intf_pins axi_dma_packet/S_AXI_LITE]
  connect_bd_intf_net -intf_net axi_gp0_M01_AXI [get_bd_intf_pins axi_gp0/M01_AXI] [get_bd_intf_pins axi_vdma_display/S_AXI_LITE]
  connect_bd_intf_net -intf_net axi_gp0_M02_AXI [get_bd_intf_pins axi_gp0/M02_AXI] [get_bd_intf_pins rx_status_gpio/S_AXI]
  connect_bd_intf_net -intf_net axi_gp0_M03_AXI [get_bd_intf_pins axi_gp0/M03_AXI] [get_bd_intf_pins hdmi_status_gpio/S_AXI]
  connect_bd_intf_net -intf_net axi_gp0_M04_AXI [get_bd_intf_pins axi_gp0/M04_AXI] [get_bd_intf_pins aes_session_key_regs_0/S_AXI]
  connect_bd_intf_net -intf_net axi_gp0_M05_AXI [get_bd_intf_pins axi_gp0/M05_AXI] [get_bd_intf_pins rx_error_gpio/S_AXI]
  connect_bd_intf_net -intf_net axi_hp0_M00_AXI [get_bd_intf_pins axi_hp0/M00_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_ACP]
  connect_bd_intf_net -intf_net axi_hp1_M00_AXI [get_bd_intf_pins axi_hp1/M00_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP1]
  connect_bd_intf_net -intf_net axi_vdma_display_M_AXIS_MM2S [get_bd_intf_pins axi_vdma_display/M_AXIS_MM2S] [get_bd_intf_pins video_axis_150_to_74/S_AXIS]
  connect_bd_intf_net -intf_net axi_vdma_display_M_AXI_MM2S [get_bd_intf_pins axi_vdma_display/M_AXI_MM2S] [get_bd_intf_pins axi_hp1/S00_AXI]
  connect_bd_intf_net -intf_net gcm_rx_slot_m_axis [get_bd_intf_pins gcm_rx_slot/m_axis] [get_bd_intf_pins axi_dma_packet/S_AXIS_S2MM]
  connect_bd_intf_net -intf_net processing_system7_0_DDR [get_bd_intf_ports DDR_0] [get_bd_intf_pins processing_system7_0/DDR]
  connect_bd_intf_net -intf_net processing_system7_0_FIXED_IO [get_bd_intf_ports FIXED_IO_0] [get_bd_intf_pins processing_system7_0/FIXED_IO]
  connect_bd_intf_net -intf_net processing_system7_0_M_AXI_GP0 [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_gp0/S00_AXI]
  connect_bd_intf_net -intf_net rgb2dvi_0_TMDS [get_bd_intf_ports TMDS] [get_bd_intf_pins rgb2dvi_0/TMDS]
  connect_bd_intf_net -intf_net video_axis_150_to_74_M_AXIS [get_bd_intf_pins video_axis_150_to_74/M_AXIS] [get_bd_intf_pins yuyv_to_rgb/s_axis]
  connect_bd_intf_net -intf_net yuyv_to_rgb_m_axis [get_bd_intf_pins yuyv_to_rgb/m_axis] [get_bd_intf_pins axi4s_to_video/video_in]

  # Create port connections
  connect_bd_net -net aes_session_key_regs_0_active_key  [get_bd_pins aes_session_key_regs_0/active_key] \
  [get_bd_pins gcm_rx_slot/session_key]
  connect_bd_net -net aes_session_key_regs_0_active_key_valid  [get_bd_pins aes_session_key_regs_0/active_key_valid] \
  [get_bd_pins gcm_rx_slot/session_key_valid]
  connect_bd_net -net aes_session_key_regs_0_active_session_id  [get_bd_pins aes_session_key_regs_0/active_session_id] \
  [get_bd_pins gcm_rx_slot/session_id]
  connect_bd_net -net aes_session_key_regs_0_key_clear_pulse  [get_bd_pins aes_session_key_regs_0/key_clear_pulse] \
  [get_bd_pins gcm_rx_slot/key_clear]
  connect_bd_net -net aes_session_key_regs_0_key_commit_pulse  [get_bd_pins aes_session_key_regs_0/key_commit_pulse] \
  [get_bd_pins gcm_rx_slot/key_commit]
  connect_bd_net -net aes_session_key_regs_0_key_epoch  [get_bd_pins aes_session_key_regs_0/key_epoch] \
  [get_bd_pins gcm_rx_slot/key_epoch]
  connect_bd_net -net axi4s_to_video_locked  [get_bd_pins axi4s_to_video/locked] \
  [get_bd_pins hdmi_status_pack/vid_locked]
  connect_bd_net -net axi4s_to_video_overflow  [get_bd_pins axi4s_to_video/overflow] \
  [get_bd_pins hdmi_status_pack/overflow]
  connect_bd_net -net axi4s_to_video_underflow  [get_bd_pins axi4s_to_video/underflow] \
  [get_bd_pins hdmi_status_pack/underflow]
  connect_bd_net -net axi4s_to_video_vtg_ce  [get_bd_pins axi4s_to_video/vtg_ce] \
  [get_bd_pins video_timing_720p/clken] \
  [get_bd_pins hdmi_status_pack/vtg_ce]
  connect_bd_net -net axi_dma_packet_mm2s_introut  [get_bd_pins axi_dma_packet/mm2s_introut] \
  [get_bd_pins irq_concat/In0]
  connect_bd_net -net axi_dma_packet_s2mm_introut  [get_bd_pins axi_dma_packet/s2mm_introut] \
  [get_bd_pins irq_concat/In1]
  connect_bd_net -net axi_vdma_display_mm2s_introut  [get_bd_pins axi_vdma_display/mm2s_introut] \
  [get_bd_pins irq_concat/In2]
  connect_bd_net -net gcm_rx_slot_busy  [get_bd_pins gcm_rx_slot/busy] \
  [get_bd_pins aes_session_key_regs_0/engine_busy]
  connect_bd_net -net gcm_rx_slot_error_status  [get_bd_pins gcm_rx_slot/error_status] \
  [get_bd_pins rx_error_gpio/gpio_io_i]
  connect_bd_net -net gcm_rx_slot_frame_status  [get_bd_pins gcm_rx_slot/frame_status] \
  [get_bd_pins rx_status_gpio/gpio_io_i]
  connect_bd_net -net gcm_rx_slot_key_ready  [get_bd_pins gcm_rx_slot/key_ready] \
  [get_bd_pins aes_session_key_regs_0/engine_key_ready]
  connect_bd_net -net hdmi_status_pack_status  [get_bd_pins hdmi_status_pack/status] \
  [get_bd_pins hdmi_status_gpio/gpio_io_i]
  connect_bd_net -net irq_concat_dout  [get_bd_pins irq_concat/dout] \
  [get_bd_pins processing_system7_0/IRQ_F2P]
  connect_bd_net -net processing_system7_0_FCLK_CLK0  [get_bd_pins processing_system7_0/FCLK_CLK0] \
  [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
  [get_bd_pins processing_system7_0/S_AXI_ACP_ACLK] \
  [get_bd_pins processing_system7_0/S_AXI_HP1_ACLK] \
  [get_bd_pins rst_150m/slowest_sync_clk] \
  [get_bd_pins axi_dma_packet/s_axi_lite_aclk] \
  [get_bd_pins axi_dma_packet/m_axi_mm2s_aclk] \
  [get_bd_pins axi_dma_packet/m_axi_s2mm_aclk] \
  [get_bd_pins gcm_rx_slot/aclk] \
  [get_bd_pins axi_vdma_display/s_axi_lite_aclk] \
  [get_bd_pins axi_vdma_display/m_axi_mm2s_aclk] \
  [get_bd_pins axi_vdma_display/m_axis_mm2s_aclk] \
  [get_bd_pins video_axis_150_to_74/s_axis_aclk] \
  [get_bd_pins axi_hp0/aclk] \
  [get_bd_pins axi_hp1/aclk] \
  [get_bd_pins axi_gp0/aclk] \
  [get_bd_pins rx_status_gpio/s_axi_aclk] \
  [get_bd_pins hdmi_status_gpio/s_axi_aclk] \
  [get_bd_pins aes_session_key_regs_0/s_axi_aclk] \
  [get_bd_pins rx_error_gpio/s_axi_aclk] \
  [get_bd_pins video_clk_74m25/clk_in1]
  connect_bd_net -net processing_system7_0_FCLK_RESET0_N  [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
  [get_bd_pins rst_150m/ext_reset_in] \
  [get_bd_pins rst_video/ext_reset_in]
  connect_bd_net -net rst_150m_peripheral_aresetn  [get_bd_pins rst_150m/peripheral_aresetn] \
  [get_bd_pins axi_dma_packet/axi_resetn] \
  [get_bd_pins gcm_rx_slot/aresetn] \
  [get_bd_pins axi_vdma_display/axi_resetn] \
  [get_bd_pins video_axis_150_to_74/s_axis_aresetn] \
  [get_bd_pins axi_hp0/aresetn] \
  [get_bd_pins axi_hp1/aresetn] \
  [get_bd_pins axi_gp0/aresetn] \
  [get_bd_pins rx_status_gpio/s_axi_aresetn] \
  [get_bd_pins hdmi_status_gpio/s_axi_aresetn] \
  [get_bd_pins aes_session_key_regs_0/s_axi_aresetn] \
  [get_bd_pins rx_error_gpio/s_axi_aresetn]
  connect_bd_net -net rst_150m_peripheral_reset  [get_bd_pins rst_150m/peripheral_reset] \
  [get_bd_pins video_clk_74m25/reset]
  connect_bd_net -net rst_video_peripheral_aresetn  [get_bd_pins rst_video/peripheral_aresetn] \
  [get_bd_pins video_axis_150_to_74/m_axis_aresetn] \
  [get_bd_pins yuyv_to_rgb/aresetn] \
  [get_bd_pins axi4s_to_video/aresetn] \
  [get_bd_pins video_timing_720p/aresetn] \
  [get_bd_pins hdmi_status_pack/aresetn] \
  [get_bd_pins rgb2dvi_0/aRst_n]
  connect_bd_net -net rx_error_gpio_gpio2_io_o  [get_bd_pins rx_error_gpio/gpio2_io_o] \
  [get_bd_pins gcm_rx_slot/error_control]
  connect_bd_net -net sw2_session_start_1  [get_bd_ports sw2_session_start] \
  [get_bd_pins aes_session_key_regs_0/session_start_switch]
  connect_bd_net -net sw3_decrypt_1  [get_bd_ports sw3_decrypt] \
  [get_bd_pins gcm_rx_slot/sw3_decrypt]
  connect_bd_net -net video_clk_74m25_clk_out1  [get_bd_pins video_clk_74m25/clk_out1] \
  [get_bd_pins rst_video/slowest_sync_clk] \
  [get_bd_pins video_axis_150_to_74/m_axis_aclk] \
  [get_bd_pins yuyv_to_rgb/aclk] \
  [get_bd_pins axi4s_to_video/aclk] \
  [get_bd_pins video_timing_720p/aclk] \
  [get_bd_pins hdmi_status_pack/aclk] \
  [get_bd_pins rgb2dvi_0/PixelClk]
  connect_bd_net -net video_clk_74m25_locked  [get_bd_pins video_clk_74m25/locked] \
  [get_bd_pins hdmi_status_pack/video_clk_locked] \
  [get_bd_pins rst_video/dcm_locked]
  connect_bd_net -net video_timing_720p_active_video  [get_bd_pins video_timing_720p/active_video] \
  [get_bd_pins axi4s_to_video/vtg_active_video] \
  [get_bd_pins hdmi_status_pack/active_video]
  connect_bd_net -net video_timing_720p_field_id  [get_bd_pins video_timing_720p/field_id] \
  [get_bd_pins axi4s_to_video/vtg_field_id]
  connect_bd_net -net video_timing_720p_frame_toggle  [get_bd_pins video_timing_720p/frame_toggle] \
  [get_bd_pins hdmi_status_pack/frame_toggle]
  connect_bd_net -net video_timing_720p_hblank  [get_bd_pins video_timing_720p/hblank] \
  [get_bd_pins axi4s_to_video/vtg_hblank]
  connect_bd_net -net video_timing_720p_hsync  [get_bd_pins video_timing_720p/hsync] \
  [get_bd_pins axi4s_to_video/vtg_hsync]
  connect_bd_net -net video_timing_720p_vblank  [get_bd_pins video_timing_720p/vblank] \
  [get_bd_pins axi4s_to_video/vtg_vblank]
  connect_bd_net -net video_timing_720p_vsync  [get_bd_pins video_timing_720p/vsync] \
  [get_bd_pins axi4s_to_video/vtg_vsync]

  # Create address segments
  assign_bd_address -offset 0x43D00000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs aes_session_key_regs_0/S_AXI/reg0] -force
  assign_bd_address -offset 0x40400000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs axi_dma_packet/S_AXI_LITE/Reg] -force
  assign_bd_address -offset 0x43000000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs axi_vdma_display/S_AXI_LITE/Reg] -force
  assign_bd_address -offset 0x41210000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs hdmi_status_gpio/S_AXI/Reg] -force
  assign_bd_address -offset 0x41220000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs rx_error_gpio/S_AXI/Reg] -force
  assign_bd_address -offset 0x41200000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs rx_status_gpio/S_AXI/Reg] -force
  assign_bd_address -offset 0x00000000 -range 0x40000000 -target_address_space [get_bd_addr_spaces axi_dma_packet/Data_MM2S] [get_bd_addr_segs processing_system7_0/S_AXI_ACP/ACP_DDR_LOWOCM] -force
  assign_bd_address -offset 0x00000000 -range 0x40000000 -target_address_space [get_bd_addr_spaces axi_dma_packet/Data_S2MM] [get_bd_addr_segs processing_system7_0/S_AXI_ACP/ACP_DDR_LOWOCM] -force
  assign_bd_address -offset 0x00000000 -range 0x40000000 -target_address_space [get_bd_addr_spaces axi_vdma_display/Data_MM2S] [get_bd_addr_segs processing_system7_0/S_AXI_HP1/HP1_DDR_LOWOCM] -force


  # Restore current instance
  current_bd_instance $oldCurInst

  validate_bd_design
  save_bd_design
}
# End of create_root_design()


##################################################################
# MAIN FLOW
##################################################################

create_root_design ""


