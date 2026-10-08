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
AR_TOOL="$(xcrun -sdk "$SDK" -f ar 2>/dev/null || echo ar)"
STRIP_TOOL="$(xcrun -sdk "$SDK" -f strip 2>/dev/null || echo strip)"
log "iOS SDK: $SDK_PATH"
log "clang : $TOOLCHAIN_PREFIX"
log "ar    : $AR_TOOL"
log "strip : $STRIP_TOOL"

need meson ninja python3 make
# macOS ships clang (no gcc unless brew-installed); accept either.
if ! command -v gcc >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1; then
    die "Need a C compiler (gcc or clang)"
fi

# --- Parallelism (macOS has no nproc without coreutils) ----------------------
if command -v sysctl >/dev/null 2>&1; then
    JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
elif command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc 2>/dev/null || echo 4)"
else
    JOBS="4"
fi
JOBS="${JOBS:-4}"
log "Parallel jobs: $JOBS"

# --- iOS cross-file for Meson ------------------------------------------------
write_cross_file() {
    mkdir -p "$OUT_DIR"
    cat > "$OUT_DIR/cross-ios.txt" <<EOF
[binaries]
c       = '$TOOLCHAIN_PREFIX'
cpp     = '$TOOLCHAIN_PREFIX'
ar      = '$AR_TOOL'
strip   = '$STRIP_TOOL'
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
# QEMU hard-depends on glib-2.0 and pixman. glib ships a Meson-based build and
# in turn hard-depends on libffi (gobject closures) + pcre2 (regex), which we
# cross-build first. zlib comes from the iOS SDK but has no .pc, and QEMU's
# aarch64 target requires libfdt — we synthesize both .pc shims.
build_deps() {
    SRCDIR="$(pwd)/deps-src"
    mkdir -p "$SRCDIR" "$PREFIX/lib/pkgconfig"
    cd "$SRCDIR"

    # pcre2 (needed by glib)
    if [ ! -d pcre2 ]; then
        log "Fetching pcre2..."
        curl -L -o pcre2.tar.gz https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.43/pcre2-10.43.tar.gz
        tar xf pcre2.tar.gz && mv pcre2-10.43 pcre2
    fi
    log "Building pcre2 for iOS..."
    (
        cd pcre2
        ./configure \
            --prefix="$PREFIX" --host=aarch64-apple-darwin \
            --disable-shared --enable-static --disable-jit \
            --disable-pcre2grep-jit --enable-pcre2-8 \
            CFLAGS="-target arm64-apple-ios$MIN_IOS -isysroot $SDK_PATH -miphoneos-version-min=$MIN_IOS" \
            CC="$TOOLCHAIN_PREFIX" || die "pcre2 configure failed"
        make -j"$JOBS" && make install
    )

    # libffi (needed by glib for GObject closures)
    if [ ! -d libffi ]; then
        log "Fetching libffi..."
        curl -L -o libffi.tar.gz https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz
        tar xf libffi.tar.gz && mv libffi-3.4.6 libffi
    fi
    # Apple Clang 17+/LLVM rejects non-private labels between
    # .cfi_startproc/.cfi_endproc on Mach-O (D153167 / libffi issue #852).
    # Fix from upstream PR #857 (8308bed5b2): move cfi_startproc after the
    # CNAME(label) in the three ffi_*_SYSV entry points.
    if [ -d libffi ]; then
        log "Patching libffi sysv.S (cfi_startproc reorder for Apple Clang)..."
        perl -0pi -e 's/\tcfi_startproc\nCNAME\(ffi_call_SYSV\):/CNAME(ffi_call_SYSV):\n\tcfi_startproc/g; s/\tcfi_startproc\nCNAME\(ffi_closure_SYSV\):/CNAME(ffi_closure_SYSV):\n\tcfi_startproc/g; s/\tcfi_startproc\nCNAME\(ffi_go_closure_SYSV\):/CNAME(ffi_go_closure_SYSV):\n\tcfi_startproc/g' libffi/src/aarch64/sysv.S
    fi
    log "Building libffi for iOS..."
    (
        cd libffi
        ./configure \
            --prefix="$PREFIX" --host=aarch64-apple-darwin \
            --disable-shared --enable-static \
            --disable-docs --disable-multi-os-directory \
            CFLAGS="-target arm64-apple-ios$MIN_IOS -isysroot $SDK_PATH -miphoneos-version-min=$MIN_IOS -fno-common" \
            CC="$TOOLCHAIN_PREFIX" || die "libffi configure failed"
        make -j"$JOBS" && make install
    )

    # pixman
    if [ ! -d pixman ]; then
        log "Fetching pixman..."
        curl -L -o pixman.tar.gz https://www.cairographics.org/releases/pixman-0.42.2.tar.gz
        tar xf pixman.tar.gz && mv pixman-0.42.2 pixman
    fi
    log "Building pixman for iOS (library only — tests/demos link host libpng)..."
    (
        cd pixman
        ./configure \
            --prefix="$PREFIX" --host=aarch64-apple-ios$MIN_IOS \
            --disable-shared --enable-static --disable-dependency-tracking \
            --disable-arm-simd --disable-arm-neon --disable-arm-a64-neon \
            --disable-arm-iwmmxt --disable-arm-iwmmxt2 --disable-mips-dspr2 \
            --disable-mmx --disable-sse2 --disable-ssse3 --disable-vmx \
            CFLAGS="-target arm64-apple-ios$MIN_IOS -isysroot $SDK_PATH -miphoneos-version-min=$MIN_IOS" \
            CC="$TOOLCHAIN_PREFIX" || die "pixman configure failed"
        # Build only the pixman library. The top-level `make` also recurses into
        # demos/ + test/, whose programs link the host (Homebrew macOS) libpng —
        # which the iOS linker refuses (cross-link error). Install the .pc by hand.
        make -j"$JOBS" -C pixman || die "pixman make failed"
        make -C pixman install || die "pixman install failed"
        install -m 0644 pixman-1.pc "$PREFIX/lib/pkgconfig/"
    )

    # zlib: iOS SDK ships libz + zlib.h but no pkg-config file -> shim.
    cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
prefix=$SDK_PATH
Name: zlib
Description: zlib compression library (iOS SDK)
Version: 1.2.12
Libs: -lz
Cflags: -I\${prefix}/usr/include
EOF

    # libfdt: aarch64-softmmu hard-requires it. QEMU's release tarball does NOT
    # bundle dtc source, and meson looks for a pkg-config 'libfdt'. So we
    # actually build the library (from dtc) rather than fake a .pc shim.
    if [ ! -d dtc ]; then
        log "Fetching dtc (libfdt)..."
        curl -L -o dtc.tar.gz https://github.com/dgibson/dtc/archive/refs/tags/v1.7.0.tar.gz
        tar xf dtc.tar.gz && mv dtc-1.7.0 dtc
    fi
    log "Building libfdt (dtc) for iOS..."
    (
        cd dtc
        # dtc builds via its own Makefile rules (no autotools). We need the
        # static libfdt archive only: the `libfdt` target also builds a .dylib
        # (GNU-style -shared link flags, fails on Apple ld), so build the
        # archive target directly. AR=ar (Apple cctools) — llvm-ar is not on
        # the macos PATH; `ar` archives Mach-O objects regardless of target.
        make -j"$JOBS" CC="$TOOLCHAIN_PREFIX" AR='ar' \
            CFLAGS="-target arm64-apple-ios$MIN_IOS -isysroot $SDK_PATH -miphoneos-version-min=$MIN_IOS -O2" \
            libfdt/libfdt.a
        install -m 0755 libfdt/libfdt.a "$PREFIX/lib/"
        mkdir -p "$PREFIX/include/libfdt"
        for h in libfdt/fdt.h libfdt/libfdt.h libfdt/libfdt_env.h libfdt/fdt_address_cells.h \
                 libfdt/fdt_empty_tree.h libfdt/fdt_ro.h libfdt/fdt_rw.h libfdt/fdt_sw.h; do
            install -m 0644 "$h" "$PREFIX/include/libfdt/" 2>/dev/null || true
        done
        echo "libfdt built"
    )

    # libfdt.pc — QEMU's meson finds libfdt via pkg-config.
    cat > "$PREFIX/lib/pkgconfig/libfdt.pc" <<EOF
prefix=$PREFIX
Name: libfdt
Description: Flat Device Tree manipulation library
Version: 1.7.0
Libs: -L\${prefix}/lib -lfdt
Cflags: -I\${prefix}/include/libfdt
EOF

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
            -Dtests=false -Dglib_debug=disabled \
            -Dlibmount=disabled -Dselinux=disabled -Dxattr=false \
            -Dsystemtap=false -Dnls=disabled \
            -Doss_fuzz=disabled -Dintrospection=disabled \
            -Dlibelf=disabled \
            || die "glib meson setup failed"
        ninja -C build -j"$JOBS" && ninja -C build install
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
        --enable-tcg --disable-tools --disable-docs \
        --disable-guest-agent --disable-tests \
        --disable-curses --disable-ncurses \
        --disable-slirp --disable-vde --disable-netmap \
        --disable-vnc --disable-rdma \
        --default-features=disabled \
        --disable-virtfs \
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
