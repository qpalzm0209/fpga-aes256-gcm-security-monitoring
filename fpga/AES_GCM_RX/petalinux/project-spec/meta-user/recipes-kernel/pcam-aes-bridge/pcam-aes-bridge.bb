SUMMARY = "PCAM AES-GCM RX DMA-BUF to AXI DMA bridge"
DESCRIPTION = "Imports RX CMA DMA-BUFs and submits paired MM2S/S2MM transfers without redundant full-frame cache synchronization."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://pcam_aes_bridge.c;beginline=1;endline=1;md5=50d2ba0afecd20f74c12a4bdbcfcfe61"

SRC_URI = "file://Makefile \
           file://pcam_aes_bridge.c \
           file://pcam_aes_bridge.h \
"

S = "${WORKDIR}"

inherit module

KERNEL_MODULE_AUTOLOAD += "pcam_aes_bridge"
