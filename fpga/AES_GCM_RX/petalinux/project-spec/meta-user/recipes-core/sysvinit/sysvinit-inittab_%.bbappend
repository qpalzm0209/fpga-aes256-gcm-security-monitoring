# ttyPS0 is the RX-to-PC telemetry channel after U-Boot hands control to Linux.
# Remove any SysV getty generated for it so no login prompt can interleave with
# the CRC-framed telemetry stream. U-Boot itself remains available over UART.
do_install:append() {
    if [ -f ${D}${sysconfdir}/inittab ]; then
        sed -i -e '/ttyPS0/d' ${D}${sysconfdir}/inittab
    fi
}
