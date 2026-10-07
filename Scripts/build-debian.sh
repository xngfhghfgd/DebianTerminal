#!/usr/bin/env bash
#
# build-debian.sh — Build the persistent Debian 12 (Bookworm) ARM64 disk image
#                   that DebianTerminal boots in QEMU.
#
# It produces a single raw ext4 image (default `debian12.img`, 8 GiB) containing
# a genuine, official Debian GNU/Linux 12 (bookworm) aarch64 userspace inside a
# real aarch64 root, plus a kernel `Image` and `initrd.img`, that boots via:
#
#   qemu-system-aarch64 -machine virt -cpu max -smp 2 -m 2048 \
#       -kernel Image -initrd initrd.img \
#       -drive file=debian12.img,if=none,id=disk0,format=raw \
#       -device virtio-blk-pci,drive=disk0,romfile= \
#       -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile= \
#       -append "root=/dev/vda rw console=ttyAMA0" \
#       -nographic -no-reboot
#
# The image is fully persistent: packages, /home, /etc and apt caches survive
# app restarts (verified by a marker file across a reboot).
#
# HARD-WON LESSONS encoded here (do not "simplify" them away):
#   * debootstrap MUST run in a SPACE-FREE path. A path like
#     "../DebianTerminal" breaks debootstrap's internal `grep` on the Packages
#     index (it splits on the space) so libc6 never downloads and the second
#     stage dies with "Could not open '/lib/ld-linux-aarch64.so.1'". We stage in
#     a space-free temp dir, then move the finished disk into the project dir.
#   * When copying the rootfs into the disk, EXCLUDE proc/sys/dev/run/tmp.
#     A plain `cp -a rootfs/. /mnt/` copies the host's bind-mounted pseudo-FS
#     into the image (balloons it to several GiB and errors on live files).
#   * Network interface is `enp0s2` (predictable naming), NOT eth0.
#     Match `Name=enp* eth*` so networkd takes the interface.
#   * Initramfs: set MODULES=list and list the virtio/ext4 drivers in
#     /etc/initramfs-tools/modules. The default MODULES=most makes modprobe
#     crawl every .ko under qemu-user (tens of minutes) and MODULES=dep fails
#     with "mkinitramfs: failed to determine device for /".
#   * QEMU `-device virtio-net-pci` fails with "failed to find romfile
#     'efi-virtio.rom'" unless you append `romfile=` (empty) to both virtio
#     pci devices. efi-virtio.rom is not shipped on most hosts.
#
# Requirements (host): debootstrap, qemu-user-static, qemu-system-arm
# (for qemu-system-aarch64). On a non-aarch64 host, aarch64 binfmt_misc must be
# registered (qemu-aarch64-static) — the script registers it when possible.
#
# Usage:
#   ./build-debian.sh                       # 8 GiB disk, USTC mirror
#   DISK_SIZE=16 ./build-debian.sh          # custom size (GiB)
#   MIRROR=http://deb.debian.org/debian ./build-debian.sh
#
# Output (in the CURRENT directory): $DISK_FILE, $KERNEL_FILE, $INITRD_FILE.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SUITE="${SUITE:-bookworm}"
ARCH="arm64"
MIRROR="${MIRROR:-https://mirrors.ustc.edu.cn/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-https://mirrors.ustc.edu.cn/debian-security}"
DISK_SIZE_GIB="${DISK_SIZE:-8}"
DISK_FILE="${DISK_FILE:-debian12.img}"
KERNEL_FILE="${KERNEL_FILE:-Image}"
INITRD_FILE="${INITRD_FILE:-initrd.img}"
HOST_ARCH="$(uname -m)"
HOSTNAME="${GUEST_HOSTNAME:-debian}"
ROOT_PASSWORD="${ROOT_PASSWORD:-debian}"   # login: root / debian (change me!)
CORE="${CORE:-2}"

# Space-free staging dir. This is the ONLY place debootstrap runs.
STAGE_DIR="${STAGE_DIR:-/var/tmp/debianterminal-${SUITE}-${ARCH}}"
WORK="${STAGE_DIR}/work"          # rootfs lives here
OUT="${STAGE_DIR}/out"            # Image / initrd.img land here before move

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;32m[build-debian]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[build-debian ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    # Unmount any pseudo-FS / loop we still hold.
    umount -l "$WORK/proc" 2>/dev/null || true
    umount -l "$WORK/sys"  2>/dev/null || true
    umount -l "$WORK/dev/pts" 2>/dev/null || true
    umount -l "$WORK/dev"  2>/dev/null || true
    umount -l "$WORK/run"  2>/dev/null || true
    for l in /dev/loop*; do [ -e "$l" ] && losetup -d "$l" 2>/dev/null || true; done
}
trap cleanup EXIT

need() {
    local b
    for b in "$@"; do
        if ! command -v "$b" >/dev/null 2>&1; then
            log "Installing missing tool: $b"
            export DEBIAN_FRONTEND=noninteractive
            case "$b" in
                qemu-aarch64-static) apt-get install -y qemu-user-static ;;
                debootstrap)          apt-get install -y debootstrap ;;
                qemu-system-aarch64)  apt-get install -y qemu-system-arm ;;
                mkfs.ext4)            apt-get install -y e2fsprogs ;;
                *)                    ;;
            esac
        fi
    done
}

# ---------------------------------------------------------------------------
# binfmt registration for cross-arch execution
# ---------------------------------------------------------------------------
binfmt_registered() {
    [ -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ] 2>/dev/null || return 1
    local flags
    flags="$(grep -m1 '^flags' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null || true)"
    # "F" is the fix-binary flag; a static interpreter is essential so the
    # interpreter does not itself need an interpreter at Chroot exec time.
    case "$flags" in *F*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
log "Host: $HOST_ARCH | Suite: $SUITE | Arch: $ARCH | Disk: ${DISK_SIZE_GIB}GiB"
need debootstrap qemu-aarch64-static qemu-system-aarch64 mkfs.ext4

if [ "$HOST_ARCH" != "aarch64" ]; then
    if ! binfmt_registered; then
        log "Registering aarch64 binfmt_misc (static interpreter)..."
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
        if [ -w /proc/sys/fs/binfmt_misc/register ]; then
            echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F' \
                > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
        fi
    fi
    if binfmt_registered; then
        log "aarch64 binfmt active — running native (single-stage) debootstrap."
        DEBOOT_MODE="native"
    else
        log "binfmt not available — falling back to --foreign + qemu second stage."
        DEBOOT_MODE="foreign"
    fi
else
    DEBOOT_MODE="native"
fi

# ---------------------------------------------------------------------------
# 1. debootstrap
# ---------------------------------------------------------------------------
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"

log "debootstrap $SUITE $ARCH into space-free dir $WORK ..."
if [ "$DEBOOT_MODE" = "foreign" ]; then
    debootstrap --arch="$ARCH" "$SUITE" "$WORK" "$MIRROR"
    cp "$(command -v qemu-aarch64-static)" "$WORK/usr/bin/"
    chroot "$WORK" /debootstrap/debootstrap --second-stage
else
    # binfmt_misc makes aarch64 binaries run natively, so a single-stage
    # debootstrap produces a fully usable rootfs.
    debootstrap --arch="$ARCH" "$SUITE" "$WORK" "$MIRROR"
fi

log "Base system installed at $WORK."

# ---------------------------------------------------------------------------
# 2. Configure the guest (inside the chroot, path has NO spaces)
# ---------------------------------------------------------------------------
log "Mounting pseudo-filesystems..."
mount --bind /dev     "$WORK/dev"   2>/dev/null || true
mount --bind /dev/pts "$WORK/dev/pts" 2>/dev/null || true
mount -t proc proc    "$WORK/proc"  2>/dev/null || true
mount -t sysfs sysfs  "$WORK/sys"   2>/dev/null || true

chroot "$WORK" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive

cat > /etc/fstab <<EOF
# /etc/fstab — the disk is a single raw ext4 device; root is /dev/vda
/dev/vda        /          ext4    defaults,noatime    0 1
EOF

cat > /etc/apt/sources.list <<EOF
deb '"$MIRROR"' bookworm main contrib non-free non-free-firmware
deb '"$MIRROR"' bookworm-updates main contrib non-free non-free-firmware
deb '"$SECURITY_MIRROR"' bookworm-security main contrib non-free non-free-firmware
EOF

echo "'"$HOSTNAME"'" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   '"$HOSTNAME"'.localdomain  '"$HOSTNAME"'
EOF

apt-get update

# Locales / timezone
export LANG=C.UTF-8
cat > /etc/default/locale <<EOF
LANG=C.UTF-8
EOF
echo "Etc/UTC" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

# Kernel, systemd and the mandatory userland.  --no-install-recommends keeps
# the image small (no X11 / printing dependencies).
apt-get install -y --no-install-recommends \
    linux-image-arm64 \
    initramfs-tools \
    systemd systemd-sysv init systemd-timesyncd \
    bash coreutils apt dpkg procps util-linux mount udev \
    iproute2 iputils-ping isc-dhcp-client \
    ca-certificates locales tzdata \
    openssh-client curl wget git python3 \
    kmod e2fsprogs netbase net-tools

# Root password: root / $ROOT_PASSWORD
echo "root:$ROOT_PASSWORD" | chpasswd

# Serial console getty on ttyAMA0 (PL011 UART)
systemctl enable serial-getty@ttyAMA0.service >/dev/null 2>&1 || true

# Get networking up.  The virtio NIC is named enp0s2 (predictable naming),
# so match enp* / eth*.
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/20-wired.network <<EOF
[Match]
Name=enp* eth*

[Network]
DHCP=yes
EOF
systemctl enable systemd-networkd.service >/dev/null 2>&1 || true

# DNS: QEMU user-mode (slirp) advertises 10.0.2.3 as the forwarder.
# systemd-resolved is a separate package we do not install, so a plain
# resolv.conf pointing at slirp is used.  (If you install systemd-resolved,
# symlink /etc/resolv.conf to its stub and drop these nameservers.)
cat > /etc/resolv.conf <<EOF
nameserver 10.0.2.3
EOF

# --- Initramfs -----------------------------------------------------------
# Critical: MODULES=list + explicit virtio/ext4 drivers.  MODULES=most is
# unworkably slow under qemu-user; MODULES=dep fails (no device to probe).
sed -i "s/^MODULES=.*/MODULES=list/" /etc/initramfs-tools/initramfs.conf
cat > /etc/initramfs-tools/modules <<EOF
virtio
virtio_blk
virtio_net
virtio_pci
virtio_ring
ext4
EOF

# Install the initramfs for the kernel package that was just installed.
# Prefer the already-generated /boot/initrd.img-*; fall back to mkinitramfs.
if ls /boot/initrd.img-* >/dev/null 2>&1; then
    : # kernel postinst already ran mkinitramfs
fi
# Regenerate using our MODULES=list config to guarantee virtio drivers land.
KVER="$(ls /usr/lib/modules/ | grep -E "^[0-9]" | sort -V | tail -1)"
if [ -n "$KVER" ]; then
    mkinitramfs -o /boot/initrd.img-${KVER} ${KVER} 2>&1 || true
fi

echo "initramfs dir:"; ls -la /boot/ 2>/dev/null || true
echo "KVER=$KVER"
echo "Guest configuration complete."
'

# ---------------------------------------------------------------------------
# 3. Extract kernel + initramfs
# ---------------------------------------------------------------------------
log "Extracting kernel and initramfs..."
cp "$WORK"/boot/vmlinuz-* "$OUT/Image"
cp "$WORK"/boot/initrd.img-* "$OUT/initrd.img"
ls -lh "$OUT"/Image "$OUT"/initrd.img

# ---------------------------------------------------------------------------
# 4. Build the persistent raw ext4 disk
# ---------------------------------------------------------------------------
log "Creating ${DISK_SIZE_GIB}GiB raw disk image (sparse)..."
truncate -s "${DISK_SIZE_GIB}G" "$DISK_FILE"

LOOP="$(losetup --find --show "$DISK_FILE" 2>/dev/null || true)"
[ -n "$LOOP" ] || die "Could not attach a loop device to $DISK_FILE."
log "Using loop device $LOOP"

mkfs.ext4 -L debian-root -O ^metadata_csum,^64bit "$LOOP" >/dev/null
mkdir -p /mnt/debian-root
mount "$LOOP" /mnt/debian-root

log "Copying rootfs into image (excluding pseudo-filesystems)..."
( cd "$WORK" && tar --exclude=proc --exclude=sys --exclude=dev --exclude=run \
      --exclude=tmp --exclude=lost+found -cf - . ) | \
  ( cd /mnt/debian-root && tar -xf - )
mkdir -p /mnt/debian-root/{proc,sys,dev,run,tmp}
chmod 1777 /mnt/debian-root/tmp

log "Fixing /etc/resolv.conf inside the image..."
cat > /mnt/debian-root/etc/resolv.conf <<EOF
nameserver 10.0.2.3
EOF

sync
umount /mnt/debian-root
losetup -d "$LOOP"

log "Formatting check..."
e2fsck -f -p "$DISK_FILE" 2>&1 | tail -2 || true

# ---------------------------------------------------------------------------
# 5. Move the kernel/initrd into the project dir next to the disk
# ---------------------------------------------------------------------------
mv "$OUT/Image" "$KERNEL_FILE"
mv "$OUT/initrd.img" "$INITRD_FILE"
rm -rf "$WORK" "$OUT"

log "----------------------------------------------------------------------"
log "Done. Artifacts:"
log "  $DISK_FILE  ($DISK_SIZE_GIB GiB raw ext4, persistent)"
log "  $KERNEL_FILE"
log "  $INITRD_FILE"
log "Boot command:"
log "  qemu-system-aarch64 -machine virt -cpu max -smp $CORE -m 2048 \\"
log "      -kernel $KERNEL_FILE -initrd $INITRD_FILE \\"
log "      -drive file=$DISK_FILE,if=none,id=disk0,format=raw \\"
log "      -device virtio-blk-pci,drive=disk0,romfile= \\"
log "      -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile= \\"
log "      -append \"root=/dev/vda rw console=ttyAMA0\" \\"
log "      -nographic -no-reboot"
log "----------------------------------------------------------------------"
