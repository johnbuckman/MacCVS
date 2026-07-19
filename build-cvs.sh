#!/bin/bash
# Reproducibly build the universal, self-contained `cvs` that MacCVS bundles.
#
# Produces bin/cvs — a universal (arm64 + x86_64) CVS 1.11.23 client that links
# ONLY /usr/lib/libSystem.B.dylib (no OpenSSL/Kerberos/external zlib), so it runs
# on any macOS with nothing to install.
#
# It is built from unmodified GNU CVS 1.11.23 source with two small,
# modern-toolchain fixes:
#   1. Drop cvs's private getline() (conflicts with the one now in <stdio.h>);
#      all callers use the system getline, which is behaviourally identical.
#   2. Make the bundled zlib's `Byte` typedef unconditional (old zlib skipped it
#      on Mac assuming Carbon's MacTypes.h, which we never include).
# Configured with --without-gssapi --disable-encryption (the :pserver: protocol
# needs no crypto), which is what removes the OpenSSL/Kerberos dependencies.
set -e
cd "$(dirname "$0")"

URL="https://ftp.gnu.org/non-gnu/cvs/source/stable/1.11.23/cvs-1.11.23.tar.bz2"
WARN="-Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion -D_DARWIN_C_SOURCE -Wno-deprecated-non-prototype"
WORK="$(mktemp -d)"

build_arch() {
    local arch="$1" dst="$2"
    rm -rf "$WORK/cvs-$arch"
    cp -R "$WORK/cvs-1.11.23" "$WORK/cvs-$arch"
    cd "$WORK/cvs-$arch"
    # Fix 1: cvs's private getline vs the system one.
    sed -i '' 's/^getline (lineptr, n, stream)/unused_cvs_getline (lineptr, n, stream)/' lib/getline.c
    perl -0777 -pi -e 's/int\n  getline __PROTO \(\(char \*\*_lineptr, size_t \*_n, FILE \*_stream\)\);\n//' lib/getline.h
    # Fix 2: unconditional Byte typedef in bundled zlib.
    perl -0777 -pi -e 's/#if !defined\(MACOS\) && !defined\(TARGET_OS_MAC\)\ntypedef unsigned char  Byte;  \/\* 8 bits \*\/\n#endif/typedef unsigned char  Byte;  \/* 8 bits *\/\n/' zlib/zconf.h
    CFLAGS="-arch $arch $WARN" ./configure --without-gssapi --disable-encryption --disable-dependency-tracking >/dev/null
    make -j4 >/dev/null
    cp src/cvs "$dst"
    cd - >/dev/null
}

echo "==> Downloading CVS 1.11.23 source"
curl -sL -o "$WORK/cvs.tar.bz2" "$URL"
tar xjf "$WORK/cvs.tar.bz2" -C "$WORK"

echo "==> Building arm64"; build_arch arm64 "$WORK/cvs-arm64.bin"
echo "==> Building x86_64"; build_arch x86_64 "$WORK/cvs-x86_64.bin"

mkdir -p bin
lipo -create "$WORK/cvs-arm64.bin" "$WORK/cvs-x86_64.bin" -output bin/cvs
chmod +x bin/cvs
rm -rf "$WORK"

echo "==> Done: bin/cvs"
lipo -info bin/cvs
otool -L bin/cvs | tail -1
