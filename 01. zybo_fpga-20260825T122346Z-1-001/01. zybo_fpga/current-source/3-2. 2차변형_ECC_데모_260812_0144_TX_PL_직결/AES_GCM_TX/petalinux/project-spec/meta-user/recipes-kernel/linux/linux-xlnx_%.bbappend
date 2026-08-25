FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://pcam.cfg \
            file://wireless.cfg \
            file://0001-media-xilinx-csi2rxss-set-entity-function.patch \
            file://0003-media-ov5640-fix-720p30-csi2-frame-period.patch \
            file://0006-media-ov5640-pcam-direct-yuv-720p-digilent-timing.patch \
            file://0007-media-ov5640-use-digilent-advanced-awb-for-pcam.patch \
"
