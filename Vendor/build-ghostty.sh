#!/bin/bash
#
# Build libghostty from Ghostty source and update the vendored xcframework.
# Requires: zig, Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)
#
# Usage:
#   ./Vendor/build-ghostty.sh /path/to/ghostty          # default: ReleaseFast
#   ./Vendor/build-ghostty.sh /path/to/ghostty Debug     # debug build

set -euo pipefail

SOURCE_DIR="${1:-}"
OPTIMIZE="${2:-ReleaseFast}"

if [ -z "$SOURCE_DIR" ]; then
    echo "Usage: $0 <ghostty-source-dir> [optimize]"
    echo "  ghostty-source-dir: path to ghostty checkout (https://github.com/ghostty-org/ghostty)"
    echo "  optimize: ReleaseFast (default), Debug, ReleaseSafe, ReleaseSmall"
    exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

if [ ! -f "$SOURCE_DIR/include/ghostty.h" ]; then
    echo "[!] ghostty header not found at $SOURCE_DIR/include/ghostty.h"
    exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
    echo "[!] zig not found — install from https://ziglang.org/download/"
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCFRAMEWORK_DIR="$ROOT_DIR/Vendor/GhosttyKit.xcframework/macos-arm64_x86_64"
BUILD_DIR="$ROOT_DIR/Vendor/.build"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "[*] zig version: $(zig version)"
echo "[*] ghostty source: $SOURCE_DIR"
echo "[*] optimize: $OPTIMIZE"

# Fetch dependencies first (uses ghostty's own cache)
echo "[*] fetching dependencies..."
(cd "$SOURCE_DIR" && zig build --fetch)

# Patch build.zig to install libghostty.a on Darwin
# Upstream only installs the xcframework on macOS, not the raw .a file.
# We need the static archive for our vendored xcframework.
PATCH_MARKER="libghostty static install for Darwin"
BUILD_ZIG="$SOURCE_DIR/build.zig"
if ! grep -Fq "$PATCH_MARKER" "$BUILD_ZIG"; then
    echo "[*] patching build.zig for Darwin static lib install..."
    sed -i '' \
        '/We shouldn'\''t have this guard but we don'\''t currently/,/^        }$/c\
        // libghostty static install for Darwin:\
        // Upstream only wires .a install for non-Darwin. We patch it\
        // to also install the static archive on macOS.\
        lib_shared.installHeader();\
        if (!config.target.result.os.tag.isDarwin()) {\
            lib_shared.install("libghostty.so");\
        }\
        lib_static.install("libghostty.a");' \
        "$BUILD_ZIG"
fi

# Common build flags
BUILD_FLAGS=(
    -Doptimize="$OPTIMIZE"
    -Demit-exe=false
    -Demit-macos-app=false
    -Demit-docs=false
    -Dsentry=false
)

# Build for arm64
echo "[*] building arm64..."
(
    cd "$SOURCE_DIR"
    rm -rf zig-out
    zig build "${BUILD_FLAGS[@]}" -Dtarget=aarch64-macos
)

ARM64_LIB="$SOURCE_DIR/zig-out/lib/libghostty.a"
if [ ! -f "$ARM64_LIB" ]; then
    echo "[!] failed to find arm64 libghostty.a at $ARM64_LIB"
    echo "[*] zig-out/lib contents:"
    ls -la "$SOURCE_DIR/zig-out/lib/" 2>/dev/null || echo "    (directory not found)"
    exit 1
fi
echo "[+] arm64: $(du -h "$ARM64_LIB" | cut -f1)"
cp "$ARM64_LIB" "$BUILD_DIR/libghostty-arm64.a"

# Build for x86_64
echo "[*] building x86_64..."
(
    cd "$SOURCE_DIR"
    rm -rf zig-out
    zig build "${BUILD_FLAGS[@]}" -Dtarget=x86_64-macos
)

X86_LIB="$SOURCE_DIR/zig-out/lib/libghostty.a"
if [ ! -f "$X86_LIB" ]; then
    echo "[!] failed to find x86_64 libghostty.a at $X86_LIB"
    exit 1
fi
echo "[+] x86_64: $(du -h "$X86_LIB" | cut -f1)"
cp "$X86_LIB" "$BUILD_DIR/libghostty-x86_64.a"

# Create universal binary and strip debug symbols
echo "[*] creating universal binary..."
lipo -create "$BUILD_DIR/libghostty-arm64.a" "$BUILD_DIR/libghostty-x86_64.a" \
    -output "$BUILD_DIR/libghostty-fat.a"
echo "[*] stripping debug symbols..."
strip -S -x "$BUILD_DIR/libghostty-fat.a" -o "$BUILD_DIR/libghostty.a"

# Update vendored files
cp "$BUILD_DIR/libghostty.a" "$XCFRAMEWORK_DIR/libghostty.a"
cp "$SOURCE_DIR/include/ghostty.h" "$XCFRAMEWORK_DIR/Headers/ghostty.h"

# Revert patch so we don't leave modified files in the ghostty checkout
echo "[*] reverting build.zig patch..."
(cd "$SOURCE_DIR" && git checkout -- build.zig 2>/dev/null || true)

# Clean up
rm -rf "$BUILD_DIR"

echo "[+] updated Vendor/GhosttyKit.xcframework/macos-arm64_x86_64/"
echo "    libghostty.a: $(du -h "$XCFRAMEWORK_DIR/libghostty.a" | cut -f1)"
echo "    ghostty.h:    $(wc -l < "$XCFRAMEWORK_DIR/Headers/ghostty.h") lines"
