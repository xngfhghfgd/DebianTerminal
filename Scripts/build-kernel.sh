#!/usr/bin/env bash
#
# build-kernel.sh — Acquire or build an ARM64 Linux kernel "Image".
#
# Produces a single `Image` (raw, uncompressed-image) that QEMU AArch64 can
# boot directly on the `virt` machine:
#
#   qemu-system-aarch64 -machine virt -cpu max -kernel Image ...
#
# Two modes:
#
#   1. Default (download):  fetch the official Debian 12 arm64 kernel package
#      and extract /boot/vmlinuz as `Image`. Official, reliable, bootable. This
#      is what DebianTerminal ships. It resolves the actual
#      linux-image-<ver>-arm64 .deb from the mirror's arm64 Packages index and
#      wget's it (this surface-path method is more reliable on a host whose apt
#      sources are set to a mirror that 403s certain packages, and avoids the
#      "Unable to locate package" gotcha of a fake-dpkg `apt-get download`).
#      NOTE: `build-debian.sh` already produces Image + initrd.img as part of
#      the guest build, so this script is the standalone/alternate kernel path.
#
#   2. --source:            cross-compile a Linus tree from source. Use this when
#      you need to customize the kernel or build a minimal one. Requires an
#      aarch64 cross toolchain (gcc-aarch64-linux-gnu).
#
# Usage:
#   ./build-kernel.sh                 # download/extract Debian arm64 kernel
#   ./build-kernel.sh --source 6.7    # cross-compile v6.7 from source
#
set -euo pipefail

KERNEL_FILE="${KERNEL_FILE:-Image}"
ARCH="arm64"
SUITE="${SUITE:-bookworm}"
QEMU_ARCH="aarch64"
MIRROR="${MIRROR:-https://mirrors.ustc.edu.cn/debian}"

log() { printf '\n\033[1;32m[build-kernel]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[build-kernel ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

need() {
    for b in "$@"; do
        if ! command -v "$b" >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y "$b" >/dev/null 2>&1 || die "Cannot install $b"
        fi
    done
}

# ===========================================================================
# MODE 1 — download the official Debian arm64 kernel
# ===========================================================================
download_mode() {
    log "Downloading official Debian arm64 kernel ($SUITE) from $MIRROR..."
    need wget dpkg-deb
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' RETURN

    # Resolve the exact linux-image-<ver>-arm64 .deb filename from the mirror's
    # arm64 Packages index, then wget it. This surface-path method is reliable on
    # hosts whose apt sources are pinned to a mirror that 403s certain packages
    # (it also sidesteps the "Unable to locate package" gotcha of a fake-dpkg
    # `apt-get download`, which we hit and abandoned).
    IDX="$TMP/Packages.gz"
    wget -q -O "$IDX" "${MIRROR}/dists/${SUITE}/main/binary-arm64/Packages.gz"

    # $1 = first line of each stanza = "Package:". Keep the genuine, bootable
    # linux-image-<ver>-arm64 (NOT the -cloud / -rt / -dbg / -unsigned variants)
    # and print its Filename: value.
    DEB_FILES="$(zcat "$IDX" \
        | awk 'BEGIN{RS=""; FS="\n"} \
            $1 ~ /^Package: linux-image-[0-9].*-arm64$/ { \
                for (i=1;i<=NF;i++) if ($i ~ /^Filename: /) { print substr($i,11); break } }' \
        | grep -vE '-(cloud|rt|dbg|unsigned)-' \
        | grep -E 'linux-image-[0-9].*-arm64_.*\.deb$' \
        | tail -5)"
    [ -n "$DEB_FILES" ] || die "No linux-image arm64 stanza with a Filename found in $MIRROR."

    DEB=""
    for REL in $DEB_FILES; do
        URL="${MIRROR}/${REL}"
        log "Fetching $URL"
        if wget -q -O "$TMP/$(basename "$REL")" "$URL"; then
            DEB="$TMP/$(basename "$REL")"
            break
        fi
    done
    [ -n "$DEB" ] || die "Failed to wget any linux-image arm64 deb."
    log "Got package: $(basename "$DEB")"

    dpkg-deb -x "$DEB" "$TMP/extract"
    VMLINUZ="$(ls "$TMP/extract/boot/vmlinuz-"* 2>/dev/null | head -1)"
    [ -n "$VMLINUZ" ] || die "No vmlinuz found in package."

    log "Extracting kernel: $VMLINUZ"
    # Debian ships a gzip-compressed vmlinuz; QEMU accepts it as-is for
    # -kernel on aarch64.
    cp "$VMLINUZ" "$KERNEL_FILE"
    rm -rf "$TMP"
    log "Kernel written to: $KERNEL_FILE"
    ls -lh "$KERNEL_FILE"
}

# ===========================================================================
# MODE 2 — cross-compile from source
# ===========================================================================
source_mode() {
    VER="${1:-6.7}"
    need git gcc-aarch64-linux-gnu make bc flex bison libssl-dev libelf-dev
    SRC="linux-${VER}"
    log "Cloning kernel v$VER (shallow)..."
    if [ ! -d "$SRC" ]; then
        git clone --depth 1 -b "v$VER" https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$SRC"
    fi

    CROSS="aarch64-linux-gnu-"
    log "Configuring for QEMU virt (arm64)..."
    make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" defconfig
    # A safe, compact config for the `virt` machine with virtio.
    make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig
    # Enable virtio storage/network and the serial console, plus ext4.
    for cfg in \
        CONFIG_VIRTIO=y CONFIG_VIRTIO_PCI=y CONFIG_VIRTIO_BLK=y \
        CONFIG_VIRTIO_NET=y CONFIG_VIRTIO_CONSOLE=y \
        CONFIG_SERIAL_8250=y CONFIG_SERIAL_8250_CONSOLE=y \
        CONFIG_SERIAL_AMBA_PL011=y CONFIG_SERIAL_AMBA_PL011_CONSOLE=y \
        CONFIG_EXT4_FS=y CONFIG_BLK_DEV_INITRD=y CONFIG_DEVTMPFS=y \
        CONFIG_DEVTMPFS_MOUNT=y CONFIG_CMDLINE_BOOL=n; do
        make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" "$cfg" >/dev/null 2>&1 || true
    done
    log "Building Image (this takes a while)..."
    make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" Image -j"$(nproc)"
    cp "$SRC/arch/arm64/boot/Image" "$KERNEL_FILE"
    log "Kernel written to: $KERNEL_FILE"
    ls -lh "$KERNEL_FILE"
}

# ===========================================================================
case "${1:-}" in
    --source) source_mode "${2:-6.7}" ;;
    --help|-h) sed -n '1,30p' "$0" ;;
    *) download_mode ;;
esac
