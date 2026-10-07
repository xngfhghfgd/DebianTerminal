# DebianTerminal — POC Verification & Test Results

**Phase 1 (POC) outcome: PASS.** A genuine, official Debian GNU/Linux 12
(bookworm) **aarch64** system was booted and verified end-to-end on the Linux
dev host via the exact chain DebianTerminal drives from iOS:

```
QEMU (AArch64, TCG) ─▶ ARM64 Linux kernel (6.1.0-53-arm64)
   ─▶ Debian 12.15 arm64 rootfs ─▶ systemd (PID 1) ─▶ bash
   ─▶ serial console (ttyAMA0) ─▶ apt + network ─▶ persistent disk
```

This is **not** proot/Termux/BusyBox/Box64, no compat-layer, no faked
`/etc/os-release`. It is a real aarch64 kernel running a real arm64 Debian
userspace under QEMU's full-system emulation.

---

## 1. Host / build environment (honest scope)

- Host CPU: `x86_64` (Debian 12). 2 cores, ~2 GB RAM, ~18 GB free disk.
- `qemu-system-aarch64` v7.2.22 (from `qemu-system-arm`).
- `qemu-user-static` + registered **binfmt_misc `qemu-aarch64`** (static
  interpreter `/usr/bin/qemu-aarch64-static`) so arm64 binaries execute on the
  x86_64 host during the build.
- `debootstrap` used to produce the rootfs.
- **The iOS app cannot be compiled or run on this host** (no Xcode/macOS). The
  Swift sources and Xcode project are authored here and are validated only by
  inspection + `swiftc` syntax availability, not by a device build. The guest
  chain they drive is what was verified live below.

> Build gotcha worth recording: `debootstrap` **must run in a path with no
> spaces**. A path containing a space (`.../DebianTerminal`) breaks
> debootstrap's internal index `grep`, so `libc6`/the aarch64 loader never
> download and the second stage dies with
> `aarch64-binfmt-P: Could not open '/lib/ld-linux-aarch64.so.1'`.
> `Scripts/build-debian.sh` therefore stages in a space-free temp dir.

---

## 2. Boot command used (the verified invocation)

```sh
qemu-system-aarch64 \
  -machine virt -cpu max -smp 2 -m 2048 \
  -kernel /root/debbuild/Image \
  -initrd /root/debbuild/initrd.img \
  -drive file=/root/debbuild/debian12.img,if=none,id=disk0,format=raw \
  -device virtio-blk-pci,drive=disk0,romfile= \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0,romfile= \
  -append "root=/dev/vda rw console=ttyAMA0" \
  -nographic -no-reboot
```

`romfile=` (empty) on both `virtio*-pci` devices is required — the host does not
ship `efi-virtio.rom`, so QEMU fails with
`failed to find romfile "efi-virtio.rom"` unless it is cleared.

---

## 3. Verification results (live, from the guest serial console)

| Check | Command | Result | PASS |
|-------|---------|--------|------|
| Architecture | `uname -m` | `aarch64` | ✅ |
| Real kernel | `uname -a` | `Linux debian 6.1.0-53-arm64 #1 SMP Debian 6.1.187-1 (2026-09-07) aarch64 GNU/Linux` | ✅ |
| OS identity | `cat /etc/os-release` | `PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"`, `VERSION_ID="12"`, `VERSION_CODENAME=bookworm`, `ID=debian` | ✅ |
| Point release | `cat /etc/debian_version` | `12.15` | ✅ |
| systemd is PID 1 | `cat /proc/1/comm` | `systemd` | ✅ |
| systemd state | `systemctl is-system-running` | `running` | ✅ |
| Shell | `echo $0` | `-bash` (pid 303) | ✅ |
| Root user | `id` | `uid=0(root) gid=0(root) groups=0(root)` → `root@debian:~#` | ✅ |
| Serial console login | boot log | `Debian GNU/Linux 12 debian ttyAMA0` / `debian login:` / `Last login: ... on ttyAMA0` | ✅ |
| Network link | `ip -br addr` | `enp0s2 UP 10.0.2.15/24` (DHCP) | ✅ |
| Default route | `ip route` | `default via 10.0.2.2 dev enp0s2 proto dhcp src 10.0.2.15` | ✅ |
| DNS | `getent hosts debian.org` | `198.18.0.29 debian.org` | ✅ |
| apt works | `apt-get update` | `Hit:1 .../debian bookworm InRelease`, `Hit:3 .../debian-security bookworm-security InRelease`, `Fetched 55.4 kB in 1min 8s`, `Reading package lists...` | ✅ |
| Key packages | `dpkg -l` | `apt 2.6.1`, `bash 5.2.15-2+b13`, `systemd 252.39-1~deb12u2`, `systemd-sysv 252.39-1~deb12u2` | ✅ |
| Persistence | `cat /root/persist-marker.txt` after reboot | `PERSIST` (marker written before shutdown survived a full reboot) | ✅ |

Boot log highlights captured: `Linux version 6.1.0-53-arm64 (debian-kernel@lists.debian.org) ... #1 SMP Debian 6.1.187-1`, `SMP: Total of 2 processors activated`, `9000000.pl011: ttyAMA0 ... is a PL011 rev1`, `virtio_blk virtio0: [vda] 16777216 512-byte logical blocks (8.59 GB/8.00 GiB)`, `virtio_net virtio1 enp0s2: renamed from eth0`, `EXT4-fs (vda): mounted filesystem ... ordered data mode`, systemd `Detected virtualization qemu.`, `Detected architecture arm64.`, `Welcome to Debian GNU/Linux 12 (bookworm)!`.

---

## 4. What was verified vs. the user's POC acceptance list

The POC spec asked to reach `root@debian:~#` and confirm `cat /etc/os-release`
→ "Debian GNU/Linux 12 (bookworm)", `cat /etc/debian_version` → 12.x,
`uname -m` → aarch64, `uname -a` → real kernel, plus systemd / bash / serial
console / persistence. **All of these passed.**

Also confirmed beyond the minimum: `apt` (package management) and the network
(DHCP + DNS) both work, and the disk is **persistent** across a shutdown/reboot
cycle — matching the "persistent Debian 12 ARM64" objective.

---

## 5. Known limitations / notes (honest)

- `procps` (`ps`/`top`) is in the installer's package list
  (`Scripts/build-debian.sh`) but was not in the manually-built POC image; that
  image returned `-bash: ps: command not found`. PID 1 was instead confirmed via
  `/proc/1/comm` = `systemd`, which is authoritative.
- Guest speed under QEMU TCG on this 2-core x86_64 host is slow (boot ~1–2 min;
  apt index fetch ~1 min). On-device iOS will be slower still; tune with
  `-smp`/`-m` in `VMConfig`.
- The POC used QEMU **user-mode networking** (`-netdev user`), so guest DNS is
  the slirp forwarder `10.0.2.3`. This is exactly what the iOS app uses
  (`VMConfig`).
- The iOS app itself was not run (no macOS/Xcode on the host). See
  `README.md` and `Docs/JIT.md` for the on-device signing/JIT requirements.
