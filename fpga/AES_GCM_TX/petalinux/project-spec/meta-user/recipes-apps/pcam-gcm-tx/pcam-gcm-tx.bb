SUMMARY = "Pcam 720p30 PL-direct AES-GCM UDP transmitter"
LICENSE = "CLOSED"

SRC_URI = "file://pcam-gcm-udp-tx.c file://pcam-gcm-tx"
S = "${WORKDIR}"

inherit update-rc.d
INITSCRIPT_NAME = "pcam-gcm-tx"
INITSCRIPT_PARAMS = "start 99 2 3 4 5 . stop 20 0 1 6 ."
RDEPENDS:${PN} += "v4l-utils media-ctl"

do_compile() {
    ${CC} ${CFLAGS} -I${WORKDIR} ${LDFLAGS} ${WORKDIR}/pcam-gcm-udp-tx.c \
        -o pcam-gcm-udp-tx
}

do_install() {
    install -d ${D}${bindir} ${D}${sysconfdir}/init.d
    install -m 0755 pcam-gcm-udp-tx ${D}${bindir}/pcam-gcm-udp-tx
    install -m 0755 ${WORKDIR}/pcam-gcm-tx \
        ${D}${sysconfdir}/init.d/pcam-gcm-tx
}

FILES:${PN} += "${bindir}/pcam-gcm-udp-tx ${sysconfdir}/init.d/pcam-gcm-tx"
