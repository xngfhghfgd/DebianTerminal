#!/usr/bin/env bash
#
# build-qemu.sh — Cross-compile QEMU (qemu-system-aarch64) for iOS (arm64).
#
# Produces a self-contained arm64 Mach-O `qemu-system-aarch64` that runs on
# iOS 26.x with JIT (AArch64 host TCG). The binary is embedded in the iOS app
# and spawned via posix_spawn; its stdio is wired to a PTY for the terminal.
#
# IMPORTANT — iOS constraints this build must satisfy:
#   * QEMU is compiled as a *host* aarch64 (arm64) target so its TCG JIT emits
#     ARM64 code. On iOS the JIT needs the app to hold the
#     `com.apple.security.cs.allow-unsigned-executable-memory` entitlement
#     (Developer Mode) and, at runtime, QEMU must allocate JIT buffers with
#     `MAP_JIT` + `pthread_jit_write_protect_np` (see jit-patch note below).
#   * No fork()/exec() of external shell helpers; we link QEMU as a static
#     binary and drive it purely through its serial console device.
#   * QEMU both needs glib (and pixman). We cross-build glib/pixman for iOS
#     from source because there is no packaged iOS glib.
#
# REQUIREMENTS (macOS host):
#   * Xcode command-line tools (clang, xcrun) with the iOS SDK.
#   * meson, ninja, python3            ->  brew install meson ninja
#   * The toolchain uses xcrun --sdk iphoneos --show-sdk-path.
#
# Usage:
#   ./build-qemu.sh                 # build embedded iOS binary
#   QEMU_VER=9.0.0 ./build-qemu.sh  # pin a QEMU release
#
set -euo pipefail

QEMU_VER="${QEMU_VER:-9.0.0}"
QEMU_TARBALL="qemu-${QEMU_VER}.tar.xz"
QEMU_SRC="qemu-${QEMU_VER}"
SDK="iphoneos"
MIN_IOS="15.0"
HOST_ARCH="aarch64"               # host = iOS device (arm64)
OUT_DIR="$(pwd)/out"
PREFIX="$(pwd)/ios-prefix"

log() { printf '\n\033[1;32m[build-qemu]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[build-qemu ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

need() {
    for b in "$@"; do
        command -v "$b" >/dev/null 2>&1 || die "Missing tool: $b"
    done
}

# --- Host toolchain ---------------------------------------------------------
SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path 2>/dev/null || die "iOS SDK not found. Is Xcode installed?")"
TOOLCHAIN_PREFIX="$(xcrun -sdk "$SDK" -f clang)"
log "iOS SDK: $SDK_PATH"
log "clang : $TOOLCHAIN_PREFIX"

need meson ninja python3 make gcc

# --- iOS cross-file for Meson ------------------------------------------------
write_cross_file() {
    mkdir -p "$OUT_DIR"
    cat > "$OUT_DIR/cross-ios.txt" <<EOF
[binaries]
c       = '$TOOLCHAIN_PREFIX'
cpp     = '$TOOLCHAIN_PREFIX'
ar      = 'llvm-ar'
strip   = 'llvm-strip'
pkgconfig = 'pkg-config'

[built-in options]
c_args   = ['-target', 'arm64-apple-ios$MIN_IOS', '-isysroot', '$SDK_PATH', '-miphoneos-version-min=$MIN_IOS', '-fobjc-arc']
c_link_args = ['-target', 'arm64-apple-ios$MIN_IOS', '-isysroot', '$SDK_PATH', '-miphoneos-version-min=$MIN_IOS']
cpp_args = ['-target', 'arm64-apple-ios$MIN_IOS', '-isysroot', '$SDK_PATH', '-miphoneos-version-min=$MIN_IOS']
cpp_link_args = ['-target', 'arm64-apple-ios$MIN_IOS', '-isysroot', '$SDK_PATH', '-miphoneos-version-min=$MIN_IOS']

[host_machine]
system = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
}

# --- Build glib + pixman for iOS ----------------------------------------------
# QEMU hard-depends on glib-2.0 and pixman. glib ships a Meson-based build.
build_deps() {
    SRCDIR="$(pwd)/deps-src"
    mkdir -p "$SRCDIR" "$PREFIX"
    cd "$SRCDIR"

    # pixman
    if [ ! -d pixman ]; then
        log "Fetching pixman..."
        curl -L -o pixman.tar.gz https://www.cairographics.org/releases/pixman-0.42.2.tar.gz
        tar xf pixman.tar.gz && mv pixman-0.42.2 pixman
    fi
    log "Building pixman for iOS..."
    (
        cd pixman
        ./configure \
            --prefix="$PREFIX" --host=aarch64-apple-ios$MIN_IOS \
            --disable-shared --enable-static --disable-dependency-tracking \
            CFLAGS="-target arm64-apple-ios$MIN_IOS -isysroot $SDK_PATH -miphoneos-version-min=$MIN_IOS" \
            CC="$TOOLCHAIN_PREFIX" || die "pixman configure failed"
        make -j"$(nproc)" && make install
    )

    # glib (depends on pcre2/ffi — build minimal). Use the meson build.
    if [ ! -d glib ]; then
        log "Fetching glib..."
        curl -L -o glib.tar.xz https://download.gnome.org/sources/glib/2.80/glib-2.80.0.tar.xz
        tar xf glib.tar.xz && mv glib-2.80.0 glib
    fi
    log "Building glib for iOS..."
    (
        cd glib
        PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
        meson setup build \
            --cross-file "$OUT_DIR/cross-ios.txt" \
            --prefix="$PREFIX" \
            -Ddefault_library=static \
            -Dtests=false -Dglib_debug=false -Dlibmount=disabled \
            -Dselinux=disabled -Dxattr=disabled -Dsystemtap=false \
            -Dnls=disabled -Ddocs=false -Dman=false \
            -Doss-fuzz=disabled -Dintrospection=disabled \
            || die "glib meson setup failed"
        ninja -C build -j"$(nproc)" && ninja -C build install
    )
    cd "$OLDPWD"
}

# --- Fetch QEMU ---------------------------------------------------------------
fetch_qemu() {
    if [ ! -f "$QEMU_TARBALL" ] && [ ! -d "$QEMU_SRC" ]; then
        log "Downloading QEMU $QEMU_VER..."
        curl -L -o "$QEMU_TARBALL" "https://download.qemu.org/$QEMU_TARBALL"
    fi
    if [ ! -d "$QEMU_SRC" ]; then
        tar xf "$QEMU_TARBALL"
    fi
}

# --- Configure & build qemu-system-aarch64 -------------------------------------
build_qemu() {
    cd "$QEMU_SRC"
    log "Configuring QEMU for iOS arm64 (aarch64-softmmu, TCG)..."
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
    meson setup build-ios \
        --cross-file "$OUT_DIR/cross-ios.txt" \
        --prefix="$PREFIX" \
        --target-list=aarch64-softmmu \
        --enable-tcg --disable-system --disable-tools --disable-docs \
        --disable-guest-agent --disable-tests \
        --enable-curses=disabled --enable-ncurses=disabled \
        --enable-slirp=disabled --enable-vde=disabled --enable-netmap=disabled \
        --enable-vnc=disabled --enable-rdma=disabled \
        --default-features=disabled \
        --enable-virtfs=disabled \
        -Dexec_round_to_page=false || die "QEMU meson setup failed (check deps)."

    log "Building qemu-system-aarch64 (this takes several minutes)..."
    ninja -C build-ios qemu-system-aarch64

    mkdir -p "$OUT_DIR"
    cp build-ios/qemu-system-aarch64 "$OUT_DIR/qemu-system-aarch64"
    log "Built: $OUT_DIR/qemu-system-aarch64"
    file "$OUT_DIR/qemu-system-aarch64" || true
}

# --- JIT patch note -------------------------------------------------------------
jit_note() {
    cat <<'EOF'

==============================================================================
 JIT on iOS — REQUIRED runtime configuration (see JIT.md)
==============================================================================
QEMU's TCG allocates executable buffers for translated code. On iOS you MUST:
  1. Add the entitlement to the app:
        <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
        <true/>
     (and for Developer Mode on device, the JIT entitlement:
        com.apple.security.get-task-allow / Developer mode toggle).
  2. QEMU must mmap its code buffers with MAP_JIT (and, on arm64e cpus,
     toggle write-protection via pthread_jit_write_protect_np()). Newer QEMU
     has an exec_path/mmap helper that honors MAP_JIT when the OS exposes it.
     If a given QEMU build does not, patch:
        accel/tcg/tcg-all.c  and  util/oslib-posix.c
        to use mmap(..., MAP_JIT | MAP_PRIVATE | MAP_ANON, fd, 0) and wrap
        writes in pthread_jit_write_protect_np(0)/(1).
  3. Verify JIT at runtime in the Swift layer before booting (see
     JITDetector.swift).
EOF
    log "$(cat <<EOF
Next steps:
  * Copy out/qemu-system-aarch64 into DebianTerminal/Resources/
  * Add the JIT entitlement to the Xcode project
  * See Scripts/install-jit.sh and JIT.md
EOF
)"
}

# ===========================================================================
main() {
    need xcrun
    write_cross_file
    build_deps
    fetch_qemu
    build_qemu
    jit_note
}
main "$@"
