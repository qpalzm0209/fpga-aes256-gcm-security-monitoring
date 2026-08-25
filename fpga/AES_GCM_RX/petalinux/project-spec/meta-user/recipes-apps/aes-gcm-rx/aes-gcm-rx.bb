SUMMARY = "PCam AES-256-GCM receiver, DMA and HDMI controller"
LICENSE = "CLOSED"

SRC_URI = "file://aes-gcm-rx.c file://pcam_aes_bridge.h file://aes-gcm-rx.init"
S = "${WORKDIR}"

inherit update-rc.d
INITSCRIPT_NAME = "aes-gcm-rx"
INITSCRIPT_PARAMS = "start 99 2 3 4 5 . stop 20 0 1 6 ."
DEPENDS += "pcam-aes-bridge"
RDEPENDS:${PN} += "kernel-module-pcam-aes-bridge"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -pthread aes-gcm-rx.c -o aes-gcm-rx -lm
}

do_install() {
    install -d ${D}${bindir} ${D}${sysconfdir}/init.d
    install -m 0755 aes-gcm-rx ${D}${bindir}/aes-gcm-rx
    install -m 0755 ${WORKDIR}/aes-gcm-rx.init \
        ${D}${sysconfdir}/init.d/aes-gcm-rx
}

FILES:${PN} += "${bindir}/aes-gcm-rx ${sysconfdir}/init.d/aes-gcm-rx"
