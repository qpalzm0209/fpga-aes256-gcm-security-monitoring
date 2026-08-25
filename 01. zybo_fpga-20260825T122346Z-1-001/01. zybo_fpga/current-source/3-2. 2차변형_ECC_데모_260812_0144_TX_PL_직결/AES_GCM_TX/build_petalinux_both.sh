#!/usr/bin/env bash
# AMD's settings.sh contains optional command probes that can return non-zero.
# Source it before enabling errexit so a harmless probe does not abort this
# wrapper on a clean shell.
set -uo pipefail

# PetaLinux/Yocto must build on a native Linux filesystem, not a mounted
# Windows or shared FAT/NTFS volume.  This wrapper stages the portable source tree into
# WSL ext4, builds both boards, and copies only final boot artifacts back.
TOP="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$HOME/aes_gcm_session_build}"
PETALINUX_SETTINGS="${PETALINUX_SETTINGS:-$HOME/petalinux/2025.2/settings.sh}"
TARGET=${1:-both}
BUILD_ROOT="$(realpath -m "$BUILD_ROOT")"

case "$TARGET" in
    both|tx|rx) ;;
    *) echo "Usage: $0 [both|tx|rx]" >&2; exit 2 ;;
esac
# AMD settings.sh treats the caller's first positional argument as an SDK
# install path.  TARGET is already saved, so do not leak our board selector.
set --

case "$BUILD_ROOT" in
    /|"$HOME"|"$TOP")
        echo "Refusing unsafe BUILD_ROOT: $BUILD_ROOT" >&2
        exit 1
        ;;
esac
if [[ -d "$BUILD_ROOT" && ! -e "$BUILD_ROOT/.aes_gcm_build_root" ]] &&
   find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "BUILD_ROOT is not an empty/dedicated build directory: $BUILD_ROOT" >&2
    exit 1
fi

test -f "$PETALINUX_SETTINGS" || {
    echo "Missing PetaLinux settings: $PETALINUX_SETTINGS" >&2
    exit 1
}
source "$PETALINUX_SETTINGS"
set -e
command -v rsync >/dev/null || {
    echo "rsync is required" >&2
    exit 1
}

mkdir -p "$BUILD_ROOT"
touch "$BUILD_ROOT/.aes_gcm_build_root"
rsync -a --delete \
    --exclude '.aes_gcm_build_root' \
    --exclude 'vivado/project/' --exclude 'petalinux/build/' \
    --exclude 'xsim.dir/' --exclude 'xsim_work/' --exclude '*.log' \
    "$TOP/" "$BUILD_ROOT/"

if [[ "$TARGET" == both || "$TARGET" == tx ]]; then
    "$BUILD_ROOT/AES_GCM_TX/petalinux/build_petalinux.sh"
fi
if [[ "$TARGET" == both || "$TARGET" == rx ]]; then
    "$BUILD_ROOT/AES_GCM_RX/petalinux/build_petalinux.sh"
fi

mkdir -p "$TOP/AES_GCM_TX/petalinux/boot" "$TOP/AES_GCM_RX/petalinux/boot"
if [[ "$TARGET" == both || "$TARGET" == tx ]]; then
    rsync -a --delete "$BUILD_ROOT/AES_GCM_TX/petalinux/boot/" \
        "$TOP/AES_GCM_TX/petalinux/boot/"
    rsync -a --delete --exclude '*.log' --exclude 'jtag_boot_status.txt' \
        "$BUILD_ROOT/AES_GCM_TX/petalinux/JTAG_RAM_BOOT/" \
        "$TOP/AES_GCM_TX/petalinux/JTAG_RAM_BOOT/"
    rsync -a --delete "$BUILD_ROOT/AES_GCM_TX/sd_card/" \
        "$TOP/AES_GCM_TX/sd_card/"
fi
if [[ "$TARGET" == both || "$TARGET" == rx ]]; then
    rsync -a --delete "$BUILD_ROOT/AES_GCM_RX/petalinux/boot/" \
        "$TOP/AES_GCM_RX/petalinux/boot/"
    rsync -a --delete --exclude '*.log' --exclude 'jtag_boot_status.txt' \
        "$BUILD_ROOT/AES_GCM_RX/petalinux/JTAG_RAM_BOOT/" \
        "$TOP/AES_GCM_RX/petalinux/JTAG_RAM_BOOT/"
    rsync -a --delete "$BUILD_ROOT/AES_GCM_RX/sd_card/" \
        "$TOP/AES_GCM_RX/sd_card/"
fi
echo "$TARGET PetaLinux boot artifacts updated"
