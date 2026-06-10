#!/bin/bash
set -euo pipefail

# Cross-compile a static Tor binary for Raspberry Pi 3B/3B+ (armv7l)
# Builds zlib, OpenSSL, libevent, and Tor as static libraries using musl-cross.
#
# Prerequisites (macOS):
#   brew install filosottile/musl-cross/musl-cross --with-arm-hf
#
# Usage:
#   ./scripts/build-tor-arm.sh
#
# Output:
#   rootfs_overlay/usr/bin/tor  (static armv7l binary, ~5-8 MB)
#
# The resulting binary is baked into Nerves firmware via rootfs_overlay.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_ROOT}/_build_tor_arm"
INSTALL_DIR="${BUILD_DIR}/install"
OUTPUT_DIR="${PROJECT_ROOT}/rootfs_overlay/usr/bin"

# Versions
ZLIB_VERSION="1.3.1"
OPENSSL_VERSION="1.1.1w"
LIBEVENT_VERSION="2.1.12-stable"
TOR_VERSION="0.4.8.20"

# Cross-compiler
CROSS="arm-linux-musleabihf"
export CC="${CROSS}-gcc"
export AR="${CROSS}-ar"
export RANLIB="${CROSS}-ranlib"
export STRIP="${CROSS}-strip"

# Verify cross-compiler is available
if ! command -v "${CC}" &>/dev/null; then
    echo "ERROR: ${CC} not found."
    echo ""
    echo "Install the musl cross-compiler:"
    echo "  brew install filosottile/musl-cross/musl-cross --with-arm-hf"
    echo ""
    echo "If it installed without --with-arm-hf, try:"
    echo "  brew reinstall filosottile/musl-cross/musl-cross --with-arm-hf"
    echo ""
    echo "Alternative: use arm-linux-musleabi (soft-float):"
    echo "  export CROSS=arm-linux-musleabi"
    echo "  Then re-run this script."
    exit 1
fi

NPROC=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

echo "=== Cross-compiling static Tor for armv7l ==="
echo "Cross-compiler: ${CC}"
echo "Build dir: ${BUILD_DIR}"
echo "Output: ${OUTPUT_DIR}/tor"
echo "Parallel jobs: ${NPROC}"
echo ""

mkdir -p "${BUILD_DIR}" "${INSTALL_DIR}" "${OUTPUT_DIR}"
cd "${BUILD_DIR}"

# --- Step 1: zlib (static) ---
echo "--- Building zlib ${ZLIB_VERSION} ---"
if [ ! -f "${INSTALL_DIR}/lib/libz.a" ]; then
    curl -fsSL "https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz" | tar xzf -
    cd "zlib-${ZLIB_VERSION}"
    CC="${CC}" ./configure --prefix="${INSTALL_DIR}" --static
    make -j"${NPROC}"
    make install
    cd "${BUILD_DIR}"
    echo "zlib: OK"
else
    echo "zlib: already built (skipping)"
fi

# --- Step 2: OpenSSL (static) ---
echo "--- Building OpenSSL ${OPENSSL_VERSION} ---"
if [ ! -f "${INSTALL_DIR}/lib/libssl.a" ]; then
    curl -fsSL "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" | tar xzf -
    cd "openssl-${OPENSSL_VERSION}"
    ./Configure linux-armv4 \
        --cross-compile-prefix="${CROSS}-" \
        --prefix="${INSTALL_DIR}" \
        threads no-shared no-dso no-comp
    make -j"${NPROC}"
    make install_sw
    cd "${BUILD_DIR}"
    echo "OpenSSL: OK"
else
    echo "OpenSSL: already built (skipping)"
fi

# --- Step 3: libevent (static) ---
echo "--- Building libevent ${LIBEVENT_VERSION} ---"
if [ ! -f "${INSTALL_DIR}/lib/libevent.a" ]; then
    curl -fsSL "https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}/libevent-${LIBEVENT_VERSION}.tar.gz" | tar xzf -
    cd "libevent-${LIBEVENT_VERSION}"
    ./configure \
        --host="${CROSS}" \
        --prefix="${INSTALL_DIR}" \
        --disable-shared \
        --enable-static \
        --with-pic \
        CC="${CC}"
    make -j"${NPROC}"
    make install
    cd "${BUILD_DIR}"
    echo "libevent: OK"
else
    echo "libevent: already built (skipping)"
fi

# --- Step 4: Tor (static) ---
echo "--- Building Tor ${TOR_VERSION} ---"
if [ ! -f "${BUILD_DIR}/tor-${TOR_VERSION}/src/app/tor" ]; then
    curl -fsSL "https://dist.torproject.org/tor-${TOR_VERSION}.tar.gz" | tar xzf -
    cd "tor-${TOR_VERSION}"

    export CPPFLAGS="-I${INSTALL_DIR}/include"
    export LDFLAGS="-L${INSTALL_DIR}/lib -static"

    ./configure \
        --host="${CROSS}" \
        --prefix="${BUILD_DIR}/tor-install" \
        --enable-static-tor \
        --disable-asciidoc \
        --disable-manpage \
        --disable-html-manual \
        --disable-seccomp \
        --disable-systemd \
        --disable-lzma \
        --disable-zstd \
        --disable-tool-name-check \
        --with-libevent-dir="${INSTALL_DIR}" \
        --with-openssl-dir="${INSTALL_DIR}" \
        --with-zlib-dir="${INSTALL_DIR}" \
        CC="${CC}"

    # Remove -pie flag that conflicts with -static
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's/-pie//g' Makefile src/app/Makefile src/tools/Makefile 2>/dev/null || true
    else
        sed -i 's/-pie//g' Makefile src/app/Makefile src/tools/Makefile 2>/dev/null || true
    fi

    make -j"${NPROC}"
    cd "${BUILD_DIR}"
    echo "Tor: OK"
else
    echo "Tor: already built (skipping)"
fi

# --- Step 5: Install and strip ---
TOR_BINARY="${BUILD_DIR}/tor-${TOR_VERSION}/src/app/tor"

if [ ! -f "${TOR_BINARY}" ]; then
    echo "ERROR: Tor binary not found at ${TOR_BINARY}"
    exit 1
fi

cp "${TOR_BINARY}" "${OUTPUT_DIR}/tor"
"${STRIP}" "${OUTPUT_DIR}/tor"

# Verify
echo ""
echo "=== Build complete ==="
file "${OUTPUT_DIR}/tor"
ls -lh "${OUTPUT_DIR}/tor"
echo ""
echo "Static Tor binary: ${OUTPUT_DIR}/tor"
echo ""
echo "Next steps:"
echo "  1. Rebuild firmware: MIX_TARGET=rpi3 mix firmware"
echo "  2. Deploy to Pi:     mix burn  (first time)"
echo "                       mix upload nerves.local  (OTA update)"
