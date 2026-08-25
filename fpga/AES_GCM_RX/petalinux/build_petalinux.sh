#!/bin/bash
set -euo pipefail

if ! command -v petalinux-create >/dev/null 2>&1; then
    echo "PetaLinux 2025.2 environment is not active." >&2
    exit 1
fi
if ! command -v bootgen >/dev/null 2>&1; then
    echo "bootgen is unavailable in the active PetaLinux environment." >&2
    exit 1
fi
if ! command -v mkimage >/dev/null 2>&1; then
    echo "mkimage is unavailable in the active PetaLinux environment." >&2
    exit 1
fi
if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync is required to keep meta-user free of stale files." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${PETALINUX_BUILD_ROOT:-}" ]]; then
    PROJECT_DIR="${PETALINUX_BUILD_ROOT}/AES_GCM_RX_petalinux"
else
    case "${ROOT_DIR}" in
        /mnt/[a-zA-Z]/*|*' '*)
            PROJECT_DIR="$HOME/.cache/zybo-petalinux/AES_GCM_RX_petalinux"
            ;;
        *)
            PROJECT_DIR="${ROOT_DIR}/build/AES_GCM_RX_petalinux"
            ;;
    esac
fi
XSA="${ROOT_DIR}/../vivado/artifacts/AES_GCM_RX.xsa"
SESSION_SRC="${ROOT_DIR}/../../session_control"
SESSION_FILES="${ROOT_DIR}/project-spec/meta-user/recipes-apps/aes-session-agent/files"

if [[ ! -f "${XSA}" ]]; then
    echo "Missing ${XSA}; run Vivado implementation first." >&2
    exit 1
fi

# Recreate canonical recipe staging so a removed/renamed source cannot survive
# in a persistent generated PetaLinux project.
rm -rf -- "${SESSION_FILES}"
mkdir -p "${SESSION_FILES}"
install -m 0644 "${SESSION_SRC}"/{aes_session_agent.c,aes_session_regs.c,aes_session_regs.h,ecdh_session_crypto.c,ecdh_session_crypto.h} "${SESSION_FILES}/"
install -m 0755 "${SESSION_SRC}"/{aes-session-rx.init,aes-session-wifi,aes-session-check} "${SESSION_FILES}/"
install -m 0600 "${SESSION_SRC}/wpa.conf" "${SESSION_FILES}/"
install -m 0600 "${SESSION_SRC}/keys/rx-demo-private.pem" "${SESSION_FILES}/"
install -m 0644 "${SESSION_SRC}/keys/tx-demo-public.pem" "${SESSION_FILES}/"

if [[ ! -d "${PROJECT_DIR}" ]]; then
    mkdir -p "$(dirname "${PROJECT_DIR}")"
    (
        cd "$(dirname "${PROJECT_DIR}")"
        petalinux-create project --template zynq \
            --name "$(basename "${PROJECT_DIR}")"
    )
fi

cd "${PROJECT_DIR}"
petalinux-config --get-hw-description "${XSA}" --silentconfig
# Preserve the generated rootfs Kconfig/hash files under meta-user/conf while
# replacing all versioned recipes exactly.  Deleting conf here makes the next
# gen-machineconf pass fail before BitBake starts.
rsync -a --delete --exclude 'conf/' "${ROOT_DIR}/project-spec/meta-user/" \
    project-spec/meta-user/
petalinux-config -c rootfs --silentconfig
petalinux-build

# Make the deployed four-part Zynq layout explicit and reproducible: FSBL,
# bitstream, U-Boot, then the final DTB preloaded at U-Boot's configured
# 0x00100000 device-tree address.
install -m 0644 "${ROOT_DIR}/../vivado/artifacts/AES_GCM_RX.bit" \
    images/linux/system.bit
install -m 0644 "${ROOT_DIR}/boot.bif" images/linux/aes-gcm-boot.bif
(
    cd images/linux
    bootgen -arch zynq -image aes-gcm-boot.bif -o BOOT.BIN -w on
)
BOOT_INFO="$(mktemp)"
trap 'rm -f "${BOOT_INFO}"' EXIT
bootgen -arch zynq -read images/linux/BOOT.BIN >"${BOOT_INFO}"
grep -q 'total_images.*0x00000004' "${BOOT_INFO}"
grep -q 'IMAGE HEADER (system.dtb)' "${BOOT_INFO}"
grep -q 'load_addr (0x0c) : 0x00100000' "${BOOT_INFO}"
rm -f "${BOOT_INFO}"
trap - EXIT

# Confirm that the XSA and overlay produced exactly one DMA owner and that RX
# keeps explicit DMA-BUF cache maintenance (RX is not wired through ACP).
if command -v dtc >/dev/null 2>&1; then
    CHECK_DTS="$(mktemp)"
    trap 'rm -f "${CHECK_DTS}"' EXIT
    dtc -I dtb -O dts images/linux/system.dtb >"${CHECK_DTS}"
    test "$(grep -c 'dma@40400000 {' "${CHECK_DTS}")" -eq 1
    if grep -A20 'dma@40400000 {' "${CHECK_DTS}" | grep -q 'dma-coherent;'; then
        echo "RX AXI DMA must not be marked dma-coherent" >&2
        exit 1
    fi
    grep -A8 'aes-gcm-bridge {' "${CHECK_DTS}" | \
        grep -q 'kccistc,pcam-aes-gcm-bridge-1.0'
    rm -f "${CHECK_DTS}"
    trap - EXIT
fi

mkdir -p "${ROOT_DIR}/boot"
cp -f images/linux/{BOOT.BIN,image.ub,system.dtb,u-boot.elf,zynq_fsbl.elf} \
    "${ROOT_DIR}/boot/"
cp -f images/linux/{image.ub,system.dtb,u-boot.elf,zynq_fsbl.elf} \
    "${ROOT_DIR}/JTAG_RAM_BOOT/"
mkdir -p "${ROOT_DIR}/../sd_card"
cp -f images/linux/{BOOT.BIN,image.ub,system.dtb} "${ROOT_DIR}/../sd_card/"
cp -f "${ROOT_DIR}/../vivado/artifacts/AES_GCM_RX.bit" \
    "${ROOT_DIR}/../sd_card/system.bit"
mkimage -A arm -T script -C none -n AES_GCM_RX_SD_boot \
    -d "${ROOT_DIR}/../sd_card/boot.cmd" \
    "${ROOT_DIR}/../sd_card/boot.scr"
(
    cd "${ROOT_DIR}/../sd_card"
    sha256sum BOOT.BIN boot.cmd boot.scr image.ub system.bit system.dtb \
        README.md >SHA256SUMS
)
