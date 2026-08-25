#!/usr/bin/env bash
set -euo pipefail

# Run after activating a supported PetaLinux 2025.2 environment.

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
XSA="$ROOT/vivado/artifacts/AES_GCM_TX.xsa"
# BitBake requires Unix-domain sockets.  WSL's mounted Windows filesystems
# (normally /mnt/<drive>) do not provide the required socket semantics, and
# paths containing spaces are also unsupported by PetaLinux.  Keep the
# disposable build cache on the native Linux filesystem in either case while
# copying every deployable result back into this release tree below.
if [ -n "${PETALINUX_BUILD_ROOT:-}" ]; then
    PROJECT="$PETALINUX_BUILD_ROOT/AES_GCM_TX_petalinux"
else
    case "$HERE" in
        /mnt/[a-zA-Z]/*|*' '*)
            PROJECT="$HOME/.cache/zybo-petalinux/AES_GCM_TX_petalinux"
            ;;
        *)
            PROJECT="$HERE/build/AES_GCM_TX_petalinux"
            ;;
    esac
fi
SESSION_SRC="${SESSION_CONTROL_ROOT:-$ROOT/../session_control}"
if [ ! -d "$SESSION_SRC" ] && [ -d "$ROOT/session_control" ]; then
    SESSION_SRC="$ROOT/session_control"
fi
SESSION_FILES="$HERE/project-spec/meta-user/recipes-apps/aes-session-agent/files"

command -v petalinux-create >/dev/null || {
    echo "PetaLinux tools are not active; source settings.sh first" >&2
    exit 1
}
command -v bootgen >/dev/null || {
    echo "bootgen is unavailable in the active PetaLinux environment" >&2
    exit 1
}
command -v mkimage >/dev/null || {
    echo "mkimage is unavailable in the active PetaLinux environment" >&2
    exit 1
}
command -v rsync >/dev/null || {
    echo "rsync is required to keep meta-user free of stale files" >&2
    exit 1
}
test -f "$XSA" || {
    echo "Missing implemented XSA: $XSA" >&2
    exit 1
}

# Keep one canonical implementation at the shared-folder top level.  Recreate
# the recipe staging directory so removed/renamed files cannot survive a build.
rm -rf -- "$SESSION_FILES"
mkdir -p "$SESSION_FILES"
install -m 0644 "$SESSION_SRC"/{aes_session_agent.c,aes_session_regs.c,aes_session_regs.h,ecdh_session_crypto.c,ecdh_session_crypto.h} "$SESSION_FILES/"
install -m 0755 "$SESSION_SRC"/{aes-session-tx.init,aes-session-wifi,aes-session-check} "$SESSION_FILES/"
install -m 0600 "$SESSION_SRC/wpa.conf" "$SESSION_FILES/"
install -m 0600 "$SESSION_SRC/keys/tx-demo-private.pem" "$SESSION_FILES/"
install -m 0644 "$SESSION_SRC/keys/rx-demo-public.pem" "$SESSION_FILES/"

if [ ! -d "$PROJECT" ]; then
    mkdir -p "$(dirname "$PROJECT")"
    (
        cd "$(dirname "$PROJECT")"
        petalinux-create project --template zynq --name AES_GCM_TX_petalinux
    )
fi

cd "$PROJECT"
petalinux-config --get-hw-description="$XSA" --silentconfig
# PetaLinux creates meta-user/conf/user-rootfsconfig during hardware import.
# It is generated project state, so keep it while replacing every versioned
# recipe with the canonical source tree below.
rsync -a --delete --exclude 'conf/' "$HERE/project-spec/meta-user/" \
    "$PROJECT/project-spec/meta-user/"
petalinux-build

# Make the deployed four-part Zynq layout explicit and reproducible: FSBL,
# bitstream, U-Boot, then the final DTB preloaded at U-Boot's configured
# 0x00100000 device-tree address.
install -m 0644 "$ROOT/vivado/artifacts/AES_GCM_TX.bit" images/linux/system.bit
install -m 0644 "$HERE/boot.bif" images/linux/aes-gcm-boot.bif
(
    cd images/linux
    bootgen -arch zynq -image aes-gcm-boot.bif -o BOOT.BIN -w on
)
BOOT_INFO="$(mktemp)"
trap 'rm -f "$BOOT_INFO"' EXIT
bootgen -arch zynq -read images/linux/BOOT.BIN >"$BOOT_INFO"
grep -q 'total_images.*0x00000004' "$BOOT_INFO"
grep -q 'IMAGE HEADER (system.dtb)' "$BOOT_INFO"
grep -q 'load_addr (0x0c) : 0x00100000' "$BOOT_INFO"
rm -f "$BOOT_INFO"
trap - EXIT

# Fail before deployment if the removed plaintext-DDR AXI DMA bridge leaked
# into the final tree, or if the live V4L2 frame writer/session bank is absent.
if command -v dtc >/dev/null 2>&1; then
    CHECK_DTS="$(mktemp)"
    trap 'rm -f "$CHECK_DTS"' EXIT
    dtc -I dtb -O dts images/linux/system.dtb >"$CHECK_DTS"
    test "$(grep -c 'dma@40400000 {' "$CHECK_DTS")" -eq 0
    ! grep -q 'aes-gcm-bridge {' "$CHECK_DTS"
    grep -q 'v_frmbuf_wr@43000000' "$CHECK_DTS"
    grep -q '43d00000' "$CHECK_DTS"
    rm -f "$CHECK_DTS"
    trap - EXIT
fi

mkdir -p "$HERE/boot"
cp -f images/linux/{BOOT.BIN,image.ub,system.dtb,u-boot.elf,zynq_fsbl.elf} "$HERE/boot/"
cp -f images/linux/{image.ub,system.dtb,u-boot.elf} "$HERE/JTAG_RAM_BOOT/"
cp -f images/linux/zynq_fsbl.elf "$HERE/JTAG_RAM_BOOT/fsbl.elf"
mkdir -p "$ROOT/sd_card"
cp -f images/linux/{BOOT.BIN,image.ub,system.dtb} "$ROOT/sd_card/"
cp -f "$ROOT/vivado/artifacts/AES_GCM_TX.bit" "$ROOT/sd_card/system.bit"
test -f "$ROOT/sd_card/boot.cmd" || {
    echo "Missing reproducible SD boot command: $ROOT/sd_card/boot.cmd" >&2
    exit 1
}
test -f "$ROOT/sd_card/README.md" || {
    echo "Missing SD release README: $ROOT/sd_card/README.md" >&2
    exit 1
}
mkimage -A arm -T script -C none -n AES_GCM_TX_SD_boot \
    -d "$ROOT/sd_card/boot.cmd" "$ROOT/sd_card/boot.scr"
(
    cd "$ROOT/sd_card"
    sha256sum BOOT.BIN boot.cmd boot.scr image.ub system.bit system.dtb \
        README.md >SHA256SUMS
)
echo "PetaLinux output copied to $HERE/boot"
