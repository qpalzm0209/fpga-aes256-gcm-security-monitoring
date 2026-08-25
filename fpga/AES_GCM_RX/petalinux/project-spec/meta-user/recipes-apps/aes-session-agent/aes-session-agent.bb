SUMMARY = "X25519 authenticated AES-GCM session key agent (RX)"
LICENSE = "CLOSED"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = "file://aes_session_agent.c file://aes_session_regs.c file://aes_session_regs.h \
           file://ecdh_session_crypto.c file://ecdh_session_crypto.h \
           file://aes-session-rx.init file://aes-session-wifi file://aes-session-check file://wpa.conf \
           file://rx-demo-private.pem file://tx-demo-public.pem"

DEPENDS = "openssl"
RDEPENDS:${PN} += "wpa-supplicant wpa-supplicant-cli iw iproute2-ip busybox-udhcpc openssl"
inherit update-rc.d
INITSCRIPT_PACKAGES = "${PN}"
INITSCRIPT_NAME:${PN} = "aes-session-agent"
INITSCRIPT_PARAMS:${PN} = "start 95 S . stop 20 0 1 6 ."

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} \
        ${WORKDIR}/aes_session_agent.c ${WORKDIR}/aes_session_regs.c \
        ${WORKDIR}/ecdh_session_crypto.c -o aes-session-agent -lcrypto
}

do_install() {
    install -d ${D}${bindir} ${D}${sysconfdir}/init.d ${D}${sysconfdir}/aes-session
    install -m 0755 aes-session-agent ${D}${bindir}/aes-session-agent
    install -m 0755 ${WORKDIR}/aes-session-rx.init ${D}${sysconfdir}/init.d/aes-session-agent
    install -m 0755 ${WORKDIR}/aes-session-wifi ${D}${sysconfdir}/init.d/aes-session-wifi
    install -m 0755 ${WORKDIR}/aes-session-check ${D}${bindir}/aes-session-check
    install -m 0600 ${WORKDIR}/wpa.conf ${D}${sysconfdir}/aes-session/wpa.conf
    install -m 0600 ${WORKDIR}/rx-demo-private.pem ${D}${sysconfdir}/aes-session/rx-private.pem
    install -m 0644 ${WORKDIR}/tx-demo-public.pem ${D}${sysconfdir}/aes-session/tx-public.pem
}

FILES:${PN} += "${sysconfdir}/aes-session ${sysconfdir}/init.d/aes-session-wifi"
