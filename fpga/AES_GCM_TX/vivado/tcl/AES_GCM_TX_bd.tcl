
################################################################
# This is a generated script based on design: pcam_system_yuv422
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
# source pcam_system_yuv422_script.tcl


# The design that will be created by this Tcl script contains the following 
# module references:
# axis_video16_to_frame128_bd, axis_gcm_tx_frame_processor_bd, axis_frame128_to_video16_bd, aes_session_key_regs_bd, tx_pipeline_health_status, axis_metadata_bram_writer, metadata_status_cdc

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
set design_name pcam_system_yuv422

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
xilinx.com:ip:axi_iic:2.1\
xilinx.com:ip:axi_gpio:2.0\
xilinx.com:ip:mipi_csi2_rx_subsystem:6.0\
xilinx.com:ip:smartconnect:1.0\
xilinx.com:ip:xlconcat:2.1\
xilinx.com:ip:axis_subset_converter:1.1\
xilinx.com:ip:axis_clock_converter:1.1\
xilinx.com:ip:v_frmbuf_wr:3.0\
xilinx.com:ip:axis_data_fifo:2.0\
xilinx.com:ip:axi_bram_ctrl:4.1\
xilinx.com:ip:blk_mem_gen:8.4\
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
axis_video16_to_frame128_bd\
axis_gcm_tx_frame_processor_bd\
axis_frame128_to_video16_bd\
aes_session_key_regs_bd\
tx_pipeline_health_status\
axis_metadata_bram_writer\
metadata_status_cdc\
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

  set pcam_iic [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 pcam_iic ]

  set dphy [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 dphy ]


  # Create ports
  set pcam_reset_n [ create_bd_port -dir O -from 0 -to 0 pcam_reset_n ]
  set sw3_encrypt [ create_bd_port -dir I sw3_encrypt ]
  set sw2_session_start [ create_bd_port -dir I sw2_session_start ]
  set btn3_session_terminate [ create_bd_port -dir I btn3_session_terminate ]

  # Create instance: processing_system7_0, and set properties
  set processing_system7_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0 ]
  set_property -dict [list \
    CONFIG.PCW_ACT_APU_PERIPHERAL_FREQMHZ {666.666687} \
    CONFIG.PCW_ACT_CAN0_PERIPHERAL_FREQMHZ {23.8095} \
    CONFIG.PCW_ACT_CAN1_PERIPHERAL_FREQMHZ {23.8095} \
    CONFIG.PCW_ACT_CAN_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_DCI_PERIPHERAL_FREQMHZ {10.158730} \
    CONFIG.PCW_ACT_ENET0_PERIPHERAL_FREQMHZ {125.000000} \
    CONFIG.PCW_ACT_ENET1_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_ACT_FPGA1_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA2_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA3_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_I2C_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_ACT_PCAP_PERIPHERAL_FREQMHZ {200.000000} \
    CONFIG.PCW_ACT_QSPI_PERIPHERAL_FREQMHZ {200.000000} \
    CONFIG.PCW_ACT_SDIO_PERIPHERAL_FREQMHZ {50.000000} \
    CONFIG.PCW_ACT_SMC_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_SPI_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_TPIU_PERIPHERAL_FREQMHZ {200.000000} \
    CONFIG.PCW_ACT_TTC0_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC0_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC0_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC1_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC1_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC1_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_ACT_UART_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_ACT_USB0_PERIPHERAL_FREQMHZ {60} \
    CONFIG.PCW_ACT_USB1_PERIPHERAL_FREQMHZ {60} \
    CONFIG.PCW_ACT_WDT_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_APU_CLK_RATIO_ENABLE {6:2:1} \
    CONFIG.PCW_APU_PERIPHERAL_FREQMHZ {666.666666} \
    CONFIG.PCW_CAN0_PERIPHERAL_CLKSRC {External} \
    CONFIG.PCW_CAN0_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_CAN1_PERIPHERAL_CLKSRC {External} \
    CONFIG.PCW_CAN1_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_CAN_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_CAN_PERIPHERAL_VALID {0} \
    CONFIG.PCW_CLK0_FREQ {100000000} \
    CONFIG.PCW_CLK1_FREQ {10000000} \
    CONFIG.PCW_CLK2_FREQ {10000000} \
    CONFIG.PCW_CLK3_FREQ {10000000} \
    CONFIG.PCW_CORE0_FIQ_INTR {0} \
    CONFIG.PCW_CORE0_IRQ_INTR {0} \
    CONFIG.PCW_CORE1_FIQ_INTR {0} \
    CONFIG.PCW_CORE1_IRQ_INTR {0} \
    CONFIG.PCW_CPU_CPU_6X4X_MAX_RANGE {667} \
    CONFIG.PCW_CPU_PERIPHERAL_CLKSRC {ARM PLL} \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
    CONFIG.PCW_DCI_PERIPHERAL_CLKSRC {DDR PLL} \
    CONFIG.PCW_DCI_PERIPHERAL_FREQMHZ {10.159} \
    CONFIG.PCW_DDR_PERIPHERAL_CLKSRC {DDR PLL} \
    CONFIG.PCW_DDR_RAM_BASEADDR {0x00100000} \
    CONFIG.PCW_DDR_RAM_HIGHADDR {0x3FFFFFFF} \
    CONFIG.PCW_DM_WIDTH {4} \
    CONFIG.PCW_DQS_WIDTH {4} \
    CONFIG.PCW_DQ_WIDTH {32} \
    CONFIG.PCW_ENET0_BASEADDR {0xE000B000} \
    CONFIG.PCW_ENET0_ENET0_IO {MIO 16 .. 27} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO {MIO 52 .. 53} \
    CONFIG.PCW_ENET0_HIGHADDR {0xE000BFFF} \
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
    CONFIG.PCW_EN_CAN0 {0} \
    CONFIG.PCW_EN_CAN1 {0} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_CLK1_PORT {0} \
    CONFIG.PCW_EN_CLK2_PORT {0} \
    CONFIG.PCW_EN_CLK3_PORT {0} \
    CONFIG.PCW_EN_CLKTRIG0_PORT {0} \
    CONFIG.PCW_EN_CLKTRIG1_PORT {0} \
    CONFIG.PCW_EN_CLKTRIG2_PORT {0} \
    CONFIG.PCW_EN_CLKTRIG3_PORT {0} \
    CONFIG.PCW_EN_DDR {1} \
    CONFIG.PCW_EN_EMIO_CAN0 {0} \
    CONFIG.PCW_EN_EMIO_CAN1 {0} \
    CONFIG.PCW_EN_EMIO_CD_SDIO0 {0} \
    CONFIG.PCW_EN_EMIO_CD_SDIO1 {0} \
    CONFIG.PCW_EN_EMIO_ENET0 {0} \
    CONFIG.PCW_EN_EMIO_ENET1 {0} \
    CONFIG.PCW_EN_EMIO_GPIO {0} \
    CONFIG.PCW_EN_EMIO_I2C0 {0} \
    CONFIG.PCW_EN_EMIO_I2C1 {0} \
    CONFIG.PCW_EN_EMIO_MODEM_UART0 {0} \
    CONFIG.PCW_EN_EMIO_MODEM_UART1 {0} \
    CONFIG.PCW_EN_EMIO_PJTAG {0} \
    CONFIG.PCW_EN_EMIO_SDIO0 {0} \
    CONFIG.PCW_EN_EMIO_SDIO1 {0} \
    CONFIG.PCW_EN_EMIO_SPI0 {0} \
    CONFIG.PCW_EN_EMIO_SPI1 {0} \
    CONFIG.PCW_EN_EMIO_SRAM_INT {0} \
    CONFIG.PCW_EN_EMIO_TRACE {0} \
    CONFIG.PCW_EN_EMIO_TTC0 {0} \
    CONFIG.PCW_EN_EMIO_TTC1 {0} \
    CONFIG.PCW_EN_EMIO_UART0 {0} \
    CONFIG.PCW_EN_EMIO_UART1 {0} \
    CONFIG.PCW_EN_EMIO_WDT {0} \
    CONFIG.PCW_EN_EMIO_WP_SDIO0 {0} \
    CONFIG.PCW_EN_EMIO_WP_SDIO1 {0} \
    CONFIG.PCW_EN_ENET0 {1} \
    CONFIG.PCW_EN_ENET1 {0} \
    CONFIG.PCW_EN_GPIO {1} \
    CONFIG.PCW_EN_I2C0 {0} \
    CONFIG.PCW_EN_I2C1 {0} \
    CONFIG.PCW_EN_MODEM_UART0 {0} \
    CONFIG.PCW_EN_MODEM_UART1 {0} \
    CONFIG.PCW_EN_PJTAG {0} \
    CONFIG.PCW_EN_PTP_ENET0 {0} \
    CONFIG.PCW_EN_PTP_ENET1 {0} \
    CONFIG.PCW_EN_QSPI {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_EN_RST1_PORT {0} \
    CONFIG.PCW_EN_RST2_PORT {0} \
    CONFIG.PCW_EN_RST3_PORT {0} \
    CONFIG.PCW_EN_SDIO0 {1} \
    CONFIG.PCW_EN_SDIO1 {0} \
    CONFIG.PCW_EN_SMC {0} \
    CONFIG.PCW_EN_SPI0 {0} \
    CONFIG.PCW_EN_SPI1 {0} \
    CONFIG.PCW_EN_TRACE {0} \
    CONFIG.PCW_EN_TTC0 {0} \
    CONFIG.PCW_EN_TTC1 {0} \
    CONFIG.PCW_EN_UART0 {0} \
    CONFIG.PCW_EN_UART1 {1} \
    CONFIG.PCW_EN_USB0 {1} \
    CONFIG.PCW_EN_USB1 {0} \
    CONFIG.PCW_EN_WDT {0} \
    CONFIG.PCW_FCLK0_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_FCLK1_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_FCLK2_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_FCLK3_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_FCLK_CLK0_BUF {TRUE} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_FPGA3_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
    CONFIG.PCW_GP0_EN_MODIFIABLE_TXN {1} \
    CONFIG.PCW_GP0_NUM_READ_THREADS {4} \
    CONFIG.PCW_GP0_NUM_WRITE_THREADS {4} \
    CONFIG.PCW_GP1_EN_MODIFIABLE_TXN {1} \
    CONFIG.PCW_GP1_NUM_READ_THREADS {4} \
    CONFIG.PCW_GP1_NUM_WRITE_THREADS {4} \
    CONFIG.PCW_GPIO_BASEADDR {0xE000A000} \
    CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE {0} \
    CONFIG.PCW_GPIO_HIGHADDR {0xE000AFFF} \
    CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {1} \
    CONFIG.PCW_GPIO_MIO_GPIO_IO {MIO} \
    CONFIG.PCW_GPIO_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_I2C0_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_I2C1_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_I2C_RESET_ENABLE {1} \
    CONFIG.PCW_I2C_RESET_POLARITY {Active Low} \
    CONFIG.PCW_IMPORT_BOARD_PRESET {None} \
    CONFIG.PCW_INCLUDE_ACP_TRANS_CHECK {0} \
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
    CONFIG.PCW_MIO_PRIMITIVE {54} \
    CONFIG.PCW_MIO_TREE_PERIPHERALS {GPIO#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#GPIO#Quad SPI Flash#GPIO#GPIO#GPIO#GPIO#GPIO#GPIO#GPIO#Enet 0#Enet 0#Enet\
0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#SD 0#SD 0#SD 0#SD 0#SD 0#SD 0#USB Reset#SD 0#UART 1#UART 1#GPIO#GPIO#Enet\
0#Enet 0} \
    CONFIG.PCW_MIO_TREE_SIGNALS {gpio[0]#qspi0_ss_b#qspi0_io[0]#qspi0_io[1]#qspi0_io[2]#qspi0_io[3]/HOLD_B#qspi0_sclk#gpio[7]#qspi_fbclk#gpio[9]#gpio[10]#gpio[11]#gpio[12]#gpio[13]#gpio[14]#gpio[15]#tx_clk#txd[0]#txd[1]#txd[2]#txd[3]#tx_ctl#rx_clk#rxd[0]#rxd[1]#rxd[2]#rxd[3]#rx_ctl#data[4]#dir#stp#nxt#data[0]#data[1]#data[2]#data[3]#clk#data[5]#data[6]#data[7]#clk#cmd#data[0]#data[1]#data[2]#data[3]#reset#cd#tx#rx#gpio[50]#gpio[51]#mdc#mdio}\
\
    CONFIG.PCW_M_AXI_GP0_ENABLE_STATIC_REMAP {0} \
    CONFIG.PCW_M_AXI_GP0_ID_WIDTH {12} \
    CONFIG.PCW_M_AXI_GP0_SUPPORT_NARROW_BURST {0} \
    CONFIG.PCW_M_AXI_GP0_THREAD_ID_WIDTH {12} \
    CONFIG.PCW_NAND_CYCLES_T_AR {1} \
    CONFIG.PCW_NAND_CYCLES_T_CLR {1} \
    CONFIG.PCW_NAND_CYCLES_T_RC {11} \
    CONFIG.PCW_NAND_CYCLES_T_REA {1} \
    CONFIG.PCW_NAND_CYCLES_T_RR {1} \
    CONFIG.PCW_NAND_CYCLES_T_WC {11} \
    CONFIG.PCW_NAND_CYCLES_T_WP {1} \
    CONFIG.PCW_NOR_CS0_T_CEOE {1} \
    CONFIG.PCW_NOR_CS0_T_PC {1} \
    CONFIG.PCW_NOR_CS0_T_RC {11} \
    CONFIG.PCW_NOR_CS0_T_TR {1} \
    CONFIG.PCW_NOR_CS0_T_WC {11} \
    CONFIG.PCW_NOR_CS0_T_WP {1} \
    CONFIG.PCW_NOR_CS0_WE_TIME {0} \
    CONFIG.PCW_NOR_CS1_T_CEOE {1} \
    CONFIG.PCW_NOR_CS1_T_PC {1} \
    CONFIG.PCW_NOR_CS1_T_RC {11} \
    CONFIG.PCW_NOR_CS1_T_TR {1} \
    CONFIG.PCW_NOR_CS1_T_WC {11} \
    CONFIG.PCW_NOR_CS1_T_WP {1} \
    CONFIG.PCW_NOR_CS1_WE_TIME {0} \
    CONFIG.PCW_NOR_SRAM_CS0_T_CEOE {1} \
    CONFIG.PCW_NOR_SRAM_CS0_T_PC {1} \
    CONFIG.PCW_NOR_SRAM_CS0_T_RC {11} \
    CONFIG.PCW_NOR_SRAM_CS0_T_TR {1} \
    CONFIG.PCW_NOR_SRAM_CS0_T_WC {11} \
    CONFIG.PCW_NOR_SRAM_CS0_T_WP {1} \
    CONFIG.PCW_NOR_SRAM_CS0_WE_TIME {0} \
    CONFIG.PCW_NOR_SRAM_CS1_T_CEOE {1} \
    CONFIG.PCW_NOR_SRAM_CS1_T_PC {1} \
    CONFIG.PCW_NOR_SRAM_CS1_T_RC {11} \
    CONFIG.PCW_NOR_SRAM_CS1_T_TR {1} \
    CONFIG.PCW_NOR_SRAM_CS1_T_WC {11} \
    CONFIG.PCW_NOR_SRAM_CS1_T_WP {1} \
    CONFIG.PCW_NOR_SRAM_CS1_WE_TIME {0} \
    CONFIG.PCW_OVERRIDE_BASIC_CLOCK {0} \
    CONFIG.PCW_P2F_ENET0_INTR {0} \
    CONFIG.PCW_P2F_GPIO_INTR {0} \
    CONFIG.PCW_P2F_QSPI_INTR {0} \
    CONFIG.PCW_P2F_SDIO0_INTR {0} \
    CONFIG.PCW_P2F_UART1_INTR {0} \
    CONFIG.PCW_P2F_USB0_INTR {0} \
    CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY0 {0.221} \
    CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY1 {0.222} \
    CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY2 {0.217} \
    CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY3 {0.244} \
    CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_0 {-0.050} \
    CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_1 {-0.044} \
    CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_2 {-0.035} \
    CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_3 {-0.100} \
    CONFIG.PCW_PACKAGE_NAME {clg400} \
    CONFIG.PCW_PCAP_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_PCAP_PERIPHERAL_FREQMHZ {200} \
    CONFIG.PCW_PERIPHERAL_BOARD_PRESET {part0} \
    CONFIG.PCW_PJTAG_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_PLL_BYPASSMODE_ENABLE {0} \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} \
    CONFIG.PCW_PS7_SI_REV {PRODUCTION} \
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
    CONFIG.PCW_SD1_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_SDIO0_BASEADDR {0xE0100000} \
    CONFIG.PCW_SDIO0_HIGHADDR {0xE0100FFF} \
    CONFIG.PCW_SDIO_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_SDIO_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_SDIO_PERIPHERAL_VALID {1} \
    CONFIG.PCW_SINGLE_QSPI_DATA_MODE {x4} \
    CONFIG.PCW_SMC_CYCLE_T0 {NA} \
    CONFIG.PCW_SMC_CYCLE_T1 {NA} \
    CONFIG.PCW_SMC_CYCLE_T2 {NA} \
    CONFIG.PCW_SMC_CYCLE_T3 {NA} \
    CONFIG.PCW_SMC_CYCLE_T4 {NA} \
    CONFIG.PCW_SMC_CYCLE_T5 {NA} \
    CONFIG.PCW_SMC_CYCLE_T6 {NA} \
    CONFIG.PCW_SMC_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_SMC_PERIPHERAL_VALID {0} \
    CONFIG.PCW_SPI0_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_SPI1_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_SPI_PERIPHERAL_CLKSRC {IO PLL} \
    CONFIG.PCW_SPI_PERIPHERAL_VALID {0} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_S_AXI_HP0_ID_WIDTH {6} \
    CONFIG.PCW_TPIU_PERIPHERAL_CLKSRC {External} \
    CONFIG.PCW_TRACE_INTERNAL_WIDTH {2} \
    CONFIG.PCW_TRACE_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_TTC0_CLK0_PERIPHERAL_CLKSRC {CPU_1X} \
    CONFIG.PCW_TTC0_CLK0_PERIPHERAL_DIVISOR0 {1} \
    CONFIG.PCW_TTC0_CLK1_PERIPHERAL_CLKSRC {CPU_1X} \
    CONFIG.PCW_TTC0_CLK1_PERIPHERAL_DIVISOR0 {1} \
    CONFIG.PCW_TTC0_CLK2_PERIPHERAL_CLKSRC {CPU_1X} \
    CONFIG.PCW_TTC0_CLK2_PERIPHERAL_DIVISOR0 {1} \
    CONFIG.PCW_TTC0_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_TTC1_CLK0_PERIPHERAL_CLKSRC {CPU_1X} \
    CONFIG.PCW_TTC1_CLK0_PERIPHERAL_DIVISOR0 {1} \
    CONFIG.PCW_TTC1_CLK1_PERIPHERAL_CLKSRC {CPU_1X} \
    CONFIG.PCW_TTC1_CLK1_PERIPHERAL_DIVISOR0 {1} \
    CONFIG.PCW_TTC1_CLK2_PERIPHERAL_CLKSRC {CPU_1X} \
    CONFIG.PCW_TTC1_CLK2_PERIPHERAL_DIVISOR0 {1} \
    CONFIG.PCW_TTC1_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_UART0_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_UART1_BASEADDR {0xE0001000} \
    CONFIG.PCW_UART1_BAUD_RATE {115200} \
    CONFIG.PCW_UART1_GRP_FULL_ENABLE {0} \
    CONFIG.PCW_UART1_HIGHADDR {0xE0001FFF} \
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
    CONFIG.PCW_UIPARAM_GENERATE_SUMMARY {NA} \
    CONFIG.PCW_USB0_BASEADDR {0xE0102000} \
    CONFIG.PCW_USB0_HIGHADDR {0xE0102fff} \
    CONFIG.PCW_USB0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_USB0_RESET_ENABLE {1} \
    CONFIG.PCW_USB0_RESET_IO {MIO 46} \
    CONFIG.PCW_USB0_USB0_IO {MIO 28 .. 39} \
    CONFIG.PCW_USB1_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_USB_RESET_ENABLE {1} \
    CONFIG.PCW_USB_RESET_POLARITY {Active Low} \
    CONFIG.PCW_USB_RESET_SELECT {Share reset pin} \
    CONFIG.PCW_USE_AXI_FABRIC_IDLE {0} \
    CONFIG.PCW_USE_AXI_NONSECURE {0} \
    CONFIG.PCW_USE_CORESIGHT {0} \
    CONFIG.PCW_USE_CROSS_TRIGGER {0} \
    CONFIG.PCW_USE_CR_FABRIC {1} \
    CONFIG.PCW_USE_DDR_BYPASS {0} \
    CONFIG.PCW_USE_DEBUG {0} \
    CONFIG.PCW_USE_DMA0 {0} \
    CONFIG.PCW_USE_DMA1 {0} \
    CONFIG.PCW_USE_DMA2 {0} \
    CONFIG.PCW_USE_DMA3 {0} \
    CONFIG.PCW_USE_EXPANDED_IOP {0} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_USE_HIGH_OCM {0} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_M_AXI_GP1 {0} \
    CONFIG.PCW_USE_PROC_EVENT_BUS {0} \
    CONFIG.PCW_USE_PS_SLCR_REGISTERS {0} \
    CONFIG.PCW_USE_S_AXI_ACP {0} \
    CONFIG.PCW_USE_S_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_GP1 {0} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP1 {0} \
    CONFIG.PCW_USE_S_AXI_HP2 {0} \
    CONFIG.PCW_USE_S_AXI_HP3 {0} \
    CONFIG.PCW_USE_TRACE {0} \
    CONFIG.PCW_VALUE_SILVERSION {3} \
    CONFIG.PCW_WDT_PERIPHERAL_CLKSRC {CPU_1X} \
    CONFIG.PCW_WDT_PERIPHERAL_DIVISOR0 {1} \
    CONFIG.PCW_WDT_PERIPHERAL_ENABLE {0} \
  ] $processing_system7_0


  # Create instance: rst_ps7_0_100M, and set properties
  set rst_ps7_0_100M [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_100M ]

  # Create instance: clk_wiz_dphy, and set properties
  set clk_wiz_dphy [ create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_dphy ]
  set_property -dict [list \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.PRIM_IN_FREQ {100.000} \
  ] $clk_wiz_dphy


  # Create instance: axi_iic_pcam, and set properties
  set axi_iic_pcam [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 axi_iic_pcam ]
  set_property CONFIG.IIC_FREQ_KHZ {100} $axi_iic_pcam


  # Create instance: axi_gpio_pcam, and set properties
  set axi_gpio_pcam [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_pcam ]
  set_property -dict [list \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_GPIO_WIDTH {1} \
  ] $axi_gpio_pcam


  # Create instance: mipi_csi2_rx_subsystem_0, and set properties
  set mipi_csi2_rx_subsystem_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:mipi_csi2_rx_subsystem:6.0 mipi_csi2_rx_subsystem_0 ]
  set_property -dict [list \
    CONFIG.CMN_NUM_LANES {2} \
    CONFIG.CMN_NUM_PIXELS {1} \
    CONFIG.CMN_PXL_FORMAT {YUV422_8bit} \
    CONFIG.CSI_BUF_DEPTH {4096} \
    CONFIG.C_CAL_MODE {FIXED} \
    CONFIG.C_DPHY_LANES {2} \
    CONFIG.C_HS_LINE_RATE {496} \
    CONFIG.C_HS_SETTLE_NS {155} \
    CONFIG.C_IDLY_TAP {2} \
    CONFIG.C_SHARE_IDLYCTRL {true} \
    CONFIG.DPY_EN_REG_IF {true} \
    CONFIG.DPY_LINE_RATE {496} \
  ] $mipi_csi2_rx_subsystem_0


  # Create instance: ps7_0_axi_periph, and set properties
  set ps7_0_axi_periph [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 ps7_0_axi_periph ]
  set_property CONFIG.NUM_MI {8} $ps7_0_axi_periph


  # Create instance: axi_mem_hp0, and set properties
  set axi_mem_hp0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_mem_hp0 ]
  set_property -dict [list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {1} \
  ] $axi_mem_hp0


  # Create instance: xlconcat_irq, and set properties
  set xlconcat_irq [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_irq ]
  set_property CONFIG.NUM_PORTS {3} $xlconcat_irq


  # Create instance: axi_gpio_frmbuf_reset, and set properties
  set axi_gpio_frmbuf_reset [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_frmbuf_reset ]
  set_property -dict [list \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_DOUT_DEFAULT {0x00000001} \
    CONFIG.C_GPIO_WIDTH {1} \
  ] $axi_gpio_frmbuf_reset


  # Create instance: clk_wiz_video_150, and set properties
  set clk_wiz_video_150 [ create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_video_150 ]
  set_property -dict [list \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {150.000} \
    CONFIG.CLKOUT1_USED {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {125.000} \
    CONFIG.CLKOUT2_USED {true} \
    CONFIG.NUM_OUT_CLKS {2} \
    CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {true} \
  ] $clk_wiz_video_150


  # Create instance: rst_video_150M, and set properties
  set rst_video_150M [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_video_150M ]
  set_property CONFIG.RESET_BOARD_INTERFACE {Custom} $rst_video_150M


  # Create instance: yuv422_axis_norm, and set properties
  set yuv422_axis_norm [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_subset_converter:1.1 yuv422_axis_norm ]
  set_property -dict [list \
    CONFIG.M_HAS_TKEEP {1} \
    CONFIG.M_HAS_TLAST {1} \
    CONFIG.M_HAS_TREADY {1} \
    CONFIG.M_HAS_TSTRB {1} \
    CONFIG.M_TDATA_NUM_BYTES {2} \
    CONFIG.M_TDEST_WIDTH {1} \
    CONFIG.M_TID_WIDTH {1} \
    CONFIG.M_TUSER_WIDTH {1} \
    CONFIG.S_HAS_TKEEP {0} \
    CONFIG.S_HAS_TLAST {1} \
    CONFIG.S_HAS_TREADY {1} \
    CONFIG.S_HAS_TSTRB {0} \
    CONFIG.S_TDATA_NUM_BYTES {2} \
    CONFIG.S_TDEST_WIDTH {10} \
    CONFIG.S_TID_WIDTH {0} \
    CONFIG.S_TUSER_WIDTH {1} \
    CONFIG.TDATA_REMAP {tdata[15:0]} \
    CONFIG.TDEST_REMAP {1'b0} \
    CONFIG.TID_REMAP {1'b0} \
    CONFIG.TKEEP_REMAP {2'b11} \
    CONFIG.TLAST_REMAP {tlast[0]} \
    CONFIG.TSTRB_REMAP {2'b11} \
    CONFIG.TUSER_REMAP {tuser[0]} \
  ] $yuv422_axis_norm


  # Create instance: axis_yuv422_16_to_24, and set properties
  set axis_yuv422_16_to_24 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_subset_converter:1.1 axis_yuv422_16_to_24 ]
  set_property -dict [list \
    CONFIG.M_HAS_TKEEP {1} \
    CONFIG.M_HAS_TLAST {1} \
    CONFIG.M_HAS_TREADY {1} \
    CONFIG.M_HAS_TSTRB {1} \
    CONFIG.M_TDATA_NUM_BYTES {3} \
    CONFIG.M_TDEST_WIDTH {1} \
    CONFIG.M_TID_WIDTH {1} \
    CONFIG.M_TUSER_WIDTH {1} \
    CONFIG.S_HAS_TKEEP {1} \
    CONFIG.S_HAS_TLAST {1} \
    CONFIG.S_HAS_TREADY {1} \
    CONFIG.S_HAS_TSTRB {1} \
    CONFIG.S_TDATA_NUM_BYTES {2} \
    CONFIG.S_TDEST_WIDTH {1} \
    CONFIG.S_TID_WIDTH {1} \
    CONFIG.S_TUSER_WIDTH {1} \
    CONFIG.TDATA_REMAP {8'b00000000,tdata[15:0]} \
    CONFIG.TDEST_REMAP {tdest[0]} \
    CONFIG.TID_REMAP {tid[0]} \
    CONFIG.TKEEP_REMAP {3'b111} \
    CONFIG.TLAST_REMAP {tlast[0]} \
    CONFIG.TSTRB_REMAP {3'b111} \
    CONFIG.TUSER_REMAP {tuser[0]} \
  ] $axis_yuv422_16_to_24


  # Create instance: video_axis_cdc_150_to_125, and set properties
  set video_axis_cdc_150_to_125 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter:1.1 video_axis_cdc_150_to_125 ]
  set_property -dict [list \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.HAS_TSTRB {1} \
    CONFIG.IS_ACLK_ASYNC {1} \
    CONFIG.SYNCHRONIZATION_STAGES {3} \
    CONFIG.TDATA_NUM_BYTES {3} \
    CONFIG.TDEST_WIDTH {1} \
    CONFIG.TID_WIDTH {1} \
    CONFIG.TUSER_WIDTH {1} \
  ] $video_axis_cdc_150_to_125


  # Create instance: v_frmbuf_wr_0, and set properties
  set v_frmbuf_wr_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:v_frmbuf_wr:3.0 v_frmbuf_wr_0 ]
  set_property -dict [list \
    CONFIG.AXIMM_ADDR_WIDTH {32} \
    CONFIG.AXIMM_BURST_LENGTH {16} \
    CONFIG.AXIMM_DATA_WIDTH {64} \
    CONFIG.AXIMM_NUM_OUTSTANDING {4} \
    CONFIG.C_M_AXI_MM_VIDEO_DATA_WIDTH {64} \
    CONFIG.HAS_BGR8 {0} \
    CONFIG.HAS_RGB8 {0} \
    CONFIG.HAS_UYVY8 {0} \
    CONFIG.HAS_YUV8 {0} \
    CONFIG.HAS_YUYV8 {1} \
    CONFIG.HAS_Y_UV8 {0} \
    CONFIG.MAX_COLS {1280} \
    CONFIG.MAX_DATA_WIDTH {8} \
    CONFIG.MAX_NR_PLANES {1} \
    CONFIG.MAX_ROWS {720} \
    CONFIG.SAMPLES_PER_CLOCK {1} \
  ] $v_frmbuf_wr_0


  # Create instance: rst_capture_125M, and set properties
  set rst_capture_125M [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_capture_125M ]
  set_property CONFIG.RESET_BOARD_INTERFACE {Custom} $rst_capture_125M


  # Create instance: rst_frmbuf_runtime_125M, and set properties
  set rst_frmbuf_runtime_125M [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_frmbuf_runtime_125M ]
  set_property -dict [list \
    CONFIG.C_AUX_RESET_HIGH {0} \
    CONFIG.RESET_BOARD_INTERFACE {Custom} \
  ] $rst_frmbuf_runtime_125M


  # Create instance: video16_to_frame128, and set properties
  set block_name axis_video16_to_frame128_bd
  set block_cell_name video16_to_frame128
  if { [catch {set video16_to_frame128 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $video16_to_frame128 eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: gcm_tx_slot, and set properties
  set block_name axis_gcm_tx_frame_processor_bd
  set block_cell_name gcm_tx_slot
  if { [catch {set gcm_tx_slot [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $gcm_tx_slot eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: frame128_to_video16, and set properties
  set block_name axis_frame128_to_video16_bd
  set block_cell_name frame128_to_video16
  if { [catch {set frame128_to_video16 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $frame128_to_video16 eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: camera_to_gcm_fifo, and set properties
  set camera_to_gcm_fifo [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 camera_to_gcm_fifo ]
  set_property -dict [list \
    CONFIG.FIFO_DEPTH {8192} \
    CONFIG.FIFO_MEMORY_TYPE {block} \
    CONFIG.FIFO_MODE {1} \
    CONFIG.HAS_PROG_FULL {1} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.HAS_WR_DATA_COUNT {1} \
    CONFIG.IS_ACLK_ASYNC {0} \
    CONFIG.PROG_FULL_THRESH {7680} \
    CONFIG.TDATA_NUM_BYTES {16} \
  ] $camera_to_gcm_fifo


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
  
  # Create instance: tx_health, and set properties
  set block_name tx_pipeline_health_status
  set block_cell_name tx_health
  if { [catch {set tx_health [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $tx_health eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: rst_crypto_runtime_150M, and set properties
  set rst_crypto_runtime_150M [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_crypto_runtime_150M ]
  set_property -dict [list \
    CONFIG.C_AUX_RESET_HIGH {0} \
    CONFIG.RESET_BOARD_INTERFACE {Custom} \
  ] $rst_crypto_runtime_150M


  # Create instance: meta_session_status_gpio, and set properties
  set meta_session_status_gpio [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 meta_session_status_gpio ]
  set_property -dict [list \
    CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_GPIO_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} \
  ] $meta_session_status_gpio


  # Create instance: metadata_bram_ctrl, and set properties
  set metadata_bram_ctrl [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 metadata_bram_ctrl ]
  set_property -dict [list \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.SINGLE_PORT_BRAM {1} \
  ] $metadata_bram_ctrl


  # Create instance: metadata_bram, and set properties
  set metadata_bram [ create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 metadata_bram ]
  set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Read_Width_A {32} \
    CONFIG.Read_Width_B {32} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Write_Width_B {32} \
  ] $metadata_bram


  # Create instance: metadata_writer, and set properties
  set block_name axis_metadata_bram_writer
  set block_cell_name metadata_writer
  if { [catch {set metadata_writer [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $metadata_writer eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: metadata_status_cdc_0, and set properties
  set block_name metadata_status_cdc
  set block_cell_name metadata_status_cdc_0
  if { [catch {set metadata_status_cdc_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $metadata_status_cdc_0 eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create interface connections
  connect_bd_intf_net -intf_net axi_iic_pcam_IIC [get_bd_intf_ports pcam_iic] [get_bd_intf_pins axi_iic_pcam/IIC]
  connect_bd_intf_net -intf_net axi_mem_hp0_M00_AXI [get_bd_intf_pins axi_mem_hp0/M00_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]
  connect_bd_intf_net -intf_net camera_to_gcm_fifo_M_AXIS [get_bd_intf_pins camera_to_gcm_fifo/M_AXIS] [get_bd_intf_pins gcm_tx_slot/s_axis]
  connect_bd_intf_net -intf_net cdc_to_frmbuf [get_bd_intf_pins video_axis_cdc_150_to_125/M_AXIS] [get_bd_intf_pins v_frmbuf_wr_0/s_axis_video]
  connect_bd_intf_net -intf_net dphy_1 [get_bd_intf_ports dphy] [get_bd_intf_pins mipi_csi2_rx_subsystem_0/mipi_phy_if]
  connect_bd_intf_net -intf_net frame128_to_video16_m_axis [get_bd_intf_pins frame128_to_video16/m_axis] [get_bd_intf_pins axis_yuv422_16_to_24/S_AXIS]
  connect_bd_intf_net -intf_net frmbuf_to_hp0 [get_bd_intf_pins v_frmbuf_wr_0/m_axi_mm_video] [get_bd_intf_pins axi_mem_hp0/S00_AXI]
  connect_bd_intf_net -intf_net gcm_tx_slot_m_axis [get_bd_intf_pins gcm_tx_slot/m_axis] [get_bd_intf_pins frame128_to_video16/s_axis]
  connect_bd_intf_net -intf_net gcm_tx_slot_m_meta [get_bd_intf_pins gcm_tx_slot/m_meta] [get_bd_intf_pins metadata_writer/s_meta]
  connect_bd_intf_net -intf_net gp0_to_frmbuf_ctrl [get_bd_intf_pins ps7_0_axi_periph/M03_AXI] [get_bd_intf_pins v_frmbuf_wr_0/s_axi_CTRL]
  connect_bd_intf_net -intf_net metadata_bram_ctrl_BRAM_PORTA [get_bd_intf_pins metadata_bram_ctrl/BRAM_PORTA] [get_bd_intf_pins metadata_bram/BRAM_PORTA]
  connect_bd_intf_net -intf_net metadata_writer_bram [get_bd_intf_pins metadata_writer/bram] [get_bd_intf_pins metadata_bram/BRAM_PORTB]
  connect_bd_intf_net -intf_net processing_system7_0_DDR [get_bd_intf_ports DDR] [get_bd_intf_pins processing_system7_0/DDR]
  connect_bd_intf_net -intf_net processing_system7_0_FIXED_IO [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins processing_system7_0/FIXED_IO]
  connect_bd_intf_net -intf_net processing_system7_0_M_AXI_GP0 [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins ps7_0_axi_periph/S00_AXI]
  connect_bd_intf_net -intf_net ps7_0_axi_periph_M00_AXI [get_bd_intf_pins ps7_0_axi_periph/M00_AXI] [get_bd_intf_pins axi_iic_pcam/S_AXI]
  connect_bd_intf_net -intf_net ps7_0_axi_periph_M01_AXI [get_bd_intf_pins ps7_0_axi_periph/M01_AXI] [get_bd_intf_pins axi_gpio_pcam/S_AXI]
  connect_bd_intf_net -intf_net ps7_0_axi_periph_M02_AXI [get_bd_intf_pins ps7_0_axi_periph/M02_AXI] [get_bd_intf_pins mipi_csi2_rx_subsystem_0/csirxss_s_axi]
  connect_bd_intf_net -intf_net ps7_0_axi_periph_M04_AXI [get_bd_intf_pins ps7_0_axi_periph/M04_AXI] [get_bd_intf_pins axi_gpio_frmbuf_reset/S_AXI]
  connect_bd_intf_net -intf_net ps7_0_axi_periph_M05_AXI [get_bd_intf_pins ps7_0_axi_periph/M05_AXI] [get_bd_intf_pins meta_session_status_gpio/S_AXI]
  connect_bd_intf_net -intf_net ps7_0_axi_periph_M06_AXI [get_bd_intf_pins ps7_0_axi_periph/M06_AXI] [get_bd_intf_pins metadata_bram_ctrl/S_AXI]
  connect_bd_intf_net -intf_net ps7_0_axi_periph_M07_AXI [get_bd_intf_pins ps7_0_axi_periph/M07_AXI] [get_bd_intf_pins aes_session_key_regs_0/S_AXI]
  connect_bd_intf_net -intf_net video16_to_frame128_m_axis [get_bd_intf_pins video16_to_frame128/m_axis] [get_bd_intf_pins camera_to_gcm_fifo/S_AXIS]
  connect_bd_intf_net -intf_net yuv422_axis_norm_M_AXIS [get_bd_intf_pins yuv422_axis_norm/M_AXIS] [get_bd_intf_pins video16_to_frame128/s_axis]
  connect_bd_intf_net -intf_net yuv422_csi_to_norm [get_bd_intf_pins mipi_csi2_rx_subsystem_0/video_out] [get_bd_intf_pins yuv422_axis_norm/S_AXIS]
  connect_bd_intf_net -intf_net yuv_pack_to_cdc [get_bd_intf_pins axis_yuv422_16_to_24/M_AXIS] [get_bd_intf_pins video_axis_cdc_150_to_125/S_AXIS]

  # Create port connections
  connect_bd_net -net aes_session_key_regs_0_active_key  [get_bd_pins aes_session_key_regs_0/active_key] \
  [get_bd_pins gcm_tx_slot/session_key]
  connect_bd_net -net aes_session_key_regs_0_active_key_valid  [get_bd_pins aes_session_key_regs_0/active_key_valid] \
  [get_bd_pins gcm_tx_slot/session_key_valid]
  connect_bd_net -net aes_session_key_regs_0_active_session_id  [get_bd_pins aes_session_key_regs_0/active_session_id] \
  [get_bd_pins gcm_tx_slot/session_id]
  connect_bd_net -net aes_session_key_regs_0_key_clear_pulse  [get_bd_pins aes_session_key_regs_0/key_clear_pulse] \
  [get_bd_pins gcm_tx_slot/key_clear]
  connect_bd_net -net aes_session_key_regs_0_key_commit_pulse  [get_bd_pins aes_session_key_regs_0/key_commit_pulse] \
  [get_bd_pins gcm_tx_slot/key_commit]
  connect_bd_net -net axi_gpio_frmbuf_reset_gpio_io_o  [get_bd_pins axi_gpio_frmbuf_reset/gpio_io_o] \
  [get_bd_pins rst_frmbuf_runtime_125M/aux_reset_in] \
  [get_bd_pins rst_crypto_runtime_150M/aux_reset_in]
  connect_bd_net -net axi_gpio_pcam_gpio_io_o  [get_bd_pins axi_gpio_pcam/gpio_io_o] \
  [get_bd_ports pcam_reset_n]
  connect_bd_net -net btn3_session_terminate_1  [get_bd_ports btn3_session_terminate] \
  [get_bd_pins aes_session_key_regs_0/session_terminate_button]
  connect_bd_net -net camera_to_gcm_fifo_axis_wr_data_count  [get_bd_pins camera_to_gcm_fifo/axis_wr_data_count] \
  [get_bd_pins tx_health/fifo_level]
  connect_bd_net -net camera_to_gcm_fifo_prog_full  [get_bd_pins camera_to_gcm_fifo/prog_full] \
  [get_bd_pins tx_health/fifo_near_full]
  connect_bd_net -net clk_wiz_dphy_clk_out1  [get_bd_pins clk_wiz_dphy/clk_out1] \
  [get_bd_pins mipi_csi2_rx_subsystem_0/dphy_clk_200M]
  connect_bd_net -net clk_wiz_video_150_clk_out1  [get_bd_pins clk_wiz_video_150/clk_out1] \
  [get_bd_pins rst_video_150M/slowest_sync_clk] \
  [get_bd_pins mipi_csi2_rx_subsystem_0/video_aclk] \
  [get_bd_pins yuv422_axis_norm/aclk] \
  [get_bd_pins axis_yuv422_16_to_24/aclk] \
  [get_bd_pins video_axis_cdc_150_to_125/s_axis_aclk] \
  [get_bd_pins video16_to_frame128/aclk] \
  [get_bd_pins gcm_tx_slot/aclk] \
  [get_bd_pins frame128_to_video16/aclk] \
  [get_bd_pins camera_to_gcm_fifo/s_axis_aclk] \
  [get_bd_pins tx_health/aclk] \
  [get_bd_pins metadata_writer/aclk] \
  [get_bd_pins aes_session_key_regs_0/s_axi_aclk] \
  [get_bd_pins ps7_0_axi_periph/M07_ACLK] \
  [get_bd_pins metadata_status_cdc_0/src_clk] \
  [get_bd_pins rst_crypto_runtime_150M/slowest_sync_clk]
  connect_bd_net -net clk_wiz_video_150_clk_out2  [get_bd_pins clk_wiz_video_150/clk_out2] \
  [get_bd_pins rst_capture_125M/slowest_sync_clk] \
  [get_bd_pins video_axis_cdc_150_to_125/m_axis_aclk] \
  [get_bd_pins v_frmbuf_wr_0/ap_clk] \
  [get_bd_pins axi_mem_hp0/aclk] \
  [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK] \
  [get_bd_pins ps7_0_axi_periph/M03_ACLK] \
  [get_bd_pins rst_frmbuf_runtime_125M/slowest_sync_clk]
  connect_bd_net -net clk_wiz_video_150_locked  [get_bd_pins clk_wiz_video_150/locked] \
  [get_bd_pins rst_video_150M/dcm_locked] \
  [get_bd_pins rst_capture_125M/dcm_locked] \
  [get_bd_pins rst_frmbuf_runtime_125M/dcm_locked] \
  [get_bd_pins rst_crypto_runtime_150M/dcm_locked]
  connect_bd_net -net frame128_to_video16_protocol_error  [get_bd_pins frame128_to_video16/protocol_error] \
  [get_bd_pins tx_health/unpack_protocol_error]
  connect_bd_net -net gcm_tx_slot_active_frame_encrypted  [get_bd_pins gcm_tx_slot/active_frame_encrypted] \
  [get_bd_pins metadata_writer/frame_encrypted]
  connect_bd_net -net gcm_tx_slot_active_frame_id  [get_bd_pins gcm_tx_slot/active_frame_id] \
  [get_bd_pins metadata_writer/frame_id]
  connect_bd_net -net gcm_tx_slot_busy  [get_bd_pins gcm_tx_slot/busy] \
  [get_bd_pins aes_session_key_regs_0/engine_busy]
  connect_bd_net -net gcm_tx_slot_key_ready  [get_bd_pins gcm_tx_slot/key_ready] \
  [get_bd_pins aes_session_key_regs_0/engine_key_ready]
  connect_bd_net -net gcm_tx_slot_protocol_error  [get_bd_pins gcm_tx_slot/protocol_error] \
  [get_bd_pins tx_health/crypto_protocol_error]
  connect_bd_net -net iic_irq_pcam  [get_bd_pins axi_iic_pcam/iic2intc_irpt] \
  [get_bd_pins xlconcat_irq/In2]
  connect_bd_net -net metadata_status_cdc_0_dst_status  [get_bd_pins metadata_status_cdc_0/dst_status] \
  [get_bd_pins meta_session_status_gpio/gpio2_io_i]
  connect_bd_net -net metadata_writer_status  [get_bd_pins metadata_writer/status] \
  [get_bd_pins metadata_status_cdc_0/src_status]
  connect_bd_net -net mipi_csi2_rx_subsystem_0_csirxss_csi_irq  [get_bd_pins mipi_csi2_rx_subsystem_0/csirxss_csi_irq] \
  [get_bd_pins xlconcat_irq/In0]
  connect_bd_net -net processing_system7_0_FCLK_CLK0  [get_bd_pins processing_system7_0/FCLK_CLK0] \
  [get_bd_pins rst_ps7_0_100M/slowest_sync_clk] \
  [get_bd_pins clk_wiz_dphy/clk_in1] \
  [get_bd_pins mipi_csi2_rx_subsystem_0/lite_aclk] \
  [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
  [get_bd_pins ps7_0_axi_periph/S00_ACLK] \
  [get_bd_pins axi_iic_pcam/s_axi_aclk] \
  [get_bd_pins ps7_0_axi_periph/M00_ACLK] \
  [get_bd_pins ps7_0_axi_periph/ACLK] \
  [get_bd_pins axi_gpio_pcam/s_axi_aclk] \
  [get_bd_pins ps7_0_axi_periph/M01_ACLK] \
  [get_bd_pins ps7_0_axi_periph/M02_ACLK] \
  [get_bd_pins axi_gpio_frmbuf_reset/s_axi_aclk] \
  [get_bd_pins ps7_0_axi_periph/M04_ACLK] \
  [get_bd_pins clk_wiz_video_150/clk_in1] \
  [get_bd_pins meta_session_status_gpio/s_axi_aclk] \
  [get_bd_pins metadata_bram_ctrl/s_axi_aclk] \
  [get_bd_pins metadata_status_cdc_0/dst_clk] \
  [get_bd_pins ps7_0_axi_periph/M05_ACLK] \
  [get_bd_pins ps7_0_axi_periph/M06_ACLK]
  connect_bd_net -net processing_system7_0_FCLK_RESET0_N  [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
  [get_bd_pins rst_ps7_0_100M/ext_reset_in] \
  [get_bd_pins rst_video_150M/ext_reset_in] \
  [get_bd_pins rst_capture_125M/ext_reset_in] \
  [get_bd_pins rst_frmbuf_runtime_125M/ext_reset_in] \
  [get_bd_pins rst_crypto_runtime_150M/ext_reset_in]
  connect_bd_net -net rst_capture_125M_peripheral_aresetn1  [get_bd_pins rst_capture_125M/peripheral_aresetn] \
  [get_bd_pins video_axis_cdc_150_to_125/m_axis_aresetn] \
  [get_bd_pins axi_mem_hp0/aresetn] \
  [get_bd_pins ps7_0_axi_periph/M03_ARESETN]
  connect_bd_net -net rst_crypto_runtime_150M_peripheral_aresetn  [get_bd_pins rst_crypto_runtime_150M/peripheral_aresetn] \
  [get_bd_pins video16_to_frame128/aresetn] \
  [get_bd_pins gcm_tx_slot/aresetn] \
  [get_bd_pins frame128_to_video16/aresetn] \
  [get_bd_pins camera_to_gcm_fifo/s_axis_aresetn] \
  [get_bd_pins tx_health/aresetn] \
  [get_bd_pins metadata_writer/aresetn]
  connect_bd_net -net rst_frmbuf_runtime_125M_peripheral_aresetn  [get_bd_pins rst_frmbuf_runtime_125M/peripheral_aresetn] \
  [get_bd_pins v_frmbuf_wr_0/ap_rst_n]
  connect_bd_net -net rst_ps7_0_100M_interconnect_aresetn  [get_bd_pins rst_ps7_0_100M/interconnect_aresetn]
  connect_bd_net -net rst_ps7_0_100M_peripheral_aresetn  [get_bd_pins rst_ps7_0_100M/peripheral_aresetn] \
  [get_bd_pins mipi_csi2_rx_subsystem_0/lite_aresetn] \
  [get_bd_pins ps7_0_axi_periph/S00_ARESETN] \
  [get_bd_pins axi_iic_pcam/s_axi_aresetn] \
  [get_bd_pins ps7_0_axi_periph/M00_ARESETN] \
  [get_bd_pins ps7_0_axi_periph/ARESETN] \
  [get_bd_pins axi_gpio_pcam/s_axi_aresetn] \
  [get_bd_pins ps7_0_axi_periph/M01_ARESETN] \
  [get_bd_pins ps7_0_axi_periph/M02_ARESETN] \
  [get_bd_pins axi_gpio_frmbuf_reset/s_axi_aresetn] \
  [get_bd_pins ps7_0_axi_periph/M04_ARESETN] \
  [get_bd_pins meta_session_status_gpio/s_axi_aresetn] \
  [get_bd_pins metadata_bram_ctrl/s_axi_aresetn] \
  [get_bd_pins metadata_status_cdc_0/dst_resetn] \
  [get_bd_pins ps7_0_axi_periph/M05_ARESETN] \
  [get_bd_pins ps7_0_axi_periph/M06_ARESETN]
  connect_bd_net -net rst_ps7_0_100M_peripheral_reset  [get_bd_pins rst_ps7_0_100M/peripheral_reset] \
  [get_bd_pins clk_wiz_dphy/reset] \
  [get_bd_pins clk_wiz_video_150/reset]
  connect_bd_net -net rst_video_150M_peripheral_aresetn  [get_bd_pins rst_video_150M/peripheral_aresetn] \
  [get_bd_pins mipi_csi2_rx_subsystem_0/video_aresetn] \
  [get_bd_pins yuv422_axis_norm/aresetn] \
  [get_bd_pins axis_yuv422_16_to_24/aresetn] \
  [get_bd_pins video_axis_cdc_150_to_125/s_axis_aresetn] \
  [get_bd_pins aes_session_key_regs_0/s_axi_aresetn] \
  [get_bd_pins ps7_0_axi_periph/M07_ARESETN]
  connect_bd_net -net sw2_session_start_1  [get_bd_ports sw2_session_start] \
  [get_bd_pins aes_session_key_regs_0/session_start_switch]
  connect_bd_net -net sw3_encrypt_1  [get_bd_ports sw3_encrypt] \
  [get_bd_pins gcm_tx_slot/sw3_encrypt]
  connect_bd_net -net tx_health_status  [get_bd_pins tx_health/status] \
  [get_bd_pins meta_session_status_gpio/gpio_io_i]
  connect_bd_net -net v_frmbuf_wr_0_interrupt  [get_bd_pins v_frmbuf_wr_0/interrupt] \
  [get_bd_pins xlconcat_irq/In1]
  connect_bd_net -net video16_to_frame128_protocol_error  [get_bd_pins video16_to_frame128/protocol_error] \
  [get_bd_pins tx_health/pack_protocol_error]
  connect_bd_net -net xlconcat_irq_dout  [get_bd_pins xlconcat_irq/dout] \
  [get_bd_pins processing_system7_0/IRQ_F2P]

  # Create address segments
  assign_bd_address -offset 0x43D00000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs aes_session_key_regs_0/S_AXI/reg0] -force
  assign_bd_address -offset 0x41210000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs axi_gpio_frmbuf_reset/S_AXI/Reg] -force
  assign_bd_address -offset 0x41200000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs axi_gpio_pcam/S_AXI/Reg] -force
  assign_bd_address -offset 0x41600000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs axi_iic_pcam/S_AXI/Reg] -force
  assign_bd_address -offset 0x41220000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs meta_session_status_gpio/S_AXI/Reg] -force
  assign_bd_address -offset 0x42000000 -range 0x00020000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs metadata_bram_ctrl/S_AXI/Mem0] -force
  assign_bd_address -offset 0x43C00000 -range 0x00002000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs mipi_csi2_rx_subsystem_0/csirxss_s_axi/Reg] -force
  assign_bd_address -offset 0x43000000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs v_frmbuf_wr_0/s_axi_CTRL/Reg] -force
  assign_bd_address -offset 0x00000000 -range 0x40000000 -target_address_space [get_bd_addr_spaces v_frmbuf_wr_0/Data_m_axi_mm_video] [get_bd_addr_segs processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM] -force


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


