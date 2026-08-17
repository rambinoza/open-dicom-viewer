#!/bin/bash
# setup_native_deps_ios.sh — OpenDicomViewer
#
# Cross-compiles DCMTK 3.6.8 + OpenJPEG 2.5.0 as static libraries for iOS
# device (arm64) and iOS Simulator (arm64 + x86_64), then packages each
# library as an XCFramework under libs/xcframeworks/.
#
# STATUS: this is a best-effort starting point, written without access to a
# Mac/Xcode/iOS SDK to actually run or verify it (see docs/iOS-Build.md for
# why). scripts/setup_native_deps.sh (the existing macOS-only script this is
# based on) is known-good and has presumably been run successfully before;
# this iOS variant applies the same CMake recipe across three additional
# platform slices and has NOT been build-tested. Treat failures here as
# expected first-attempt friction, not a sign the whole approach is wrong --
# see the "Known risk areas" section below before debugging blind.
#
# Usage:
#   ./scripts/setup_native_deps_ios.sh
#
# Output:
#   libs/xcframeworks/<library>.xcframework   (one per DCMTK/OpenJPEG library)
#   Each XCFramework has two slices: ios-arm64 (device) and
#   ios-arm64_x86_64-simulator (simulator, lipo'd universal).
#
# Licensed under the MIT License. See LICENSE for details.
set -e

PROJECT_ROOT="$(pwd)"
LIBS_DIR="$PROJECT_ROOT/libs"
XCFRAMEWORKS_DIR="$LIBS_DIR/xcframeworks"
TEMP_DIR="$PROJECT_ROOT/temp_build_ios"
CMAKE_DIR="$PROJECT_ROOT/temp_build/cmake"   # reuse the mac script's local CMake if present
IOS_DEPLOYMENT_TARGET="17.0"

mkdir -p "$LIBS_DIR" "$XCFRAMEWORKS_DIR" "$TEMP_DIR"

# ---------------------------------------------------------------------------
# 0. CMake + the ios-cmake toolchain file
# ---------------------------------------------------------------------------
# Cross-compiling for iOS from a CMake project is notoriously easy to get
# subtly wrong: CMake's try_run() (used by DCMTK's and OpenJPEG's configure
# checks for endianness, type sizes, etc.) can't execute an iOS binary on the
# macOS build host, so a naive `-DCMAKE_SYSTEM_NAME=iOS` setup will hang or
# fail at configure time. Rather than hand-roll that logic (which I can't
# verify without a real toolchain), this script uses the community-maintained
# ios-cmake toolchain file (https://github.com/leetal/ios-cmake, MIT
# licensed), which specifically solves this. It's downloaded once and cached.
if [ ! -f "$CMAKE_DIR/CMake.app/Contents/bin/cmake" ]; then
    echo "Local CMake not found -- run scripts/setup_native_deps.sh first (it downloads" \
         "a local CMake this script reuses), or install CMake and adjust CMAKE_BIN below."
    mkdir -p "$CMAKE_DIR"
    cd "$TEMP_DIR"
    curl -L -O https://github.com/Kitware/CMake/releases/download/v3.29.0/cmake-3.29.0-macos-universal.tar.gz
    tar xzf cmake-3.29.0-macos-universal.tar.gz
    mv cmake-3.29.0-macos-universal "$CMAKE_DIR"
    rm cmake-3.29.0-macos-universal.tar.gz
fi
CMAKE_BIN="$CMAKE_DIR/CMake.app/Contents/bin/cmake"
echo "Using CMake at: $CMAKE_BIN"

IOS_TOOLCHAIN="$TEMP_DIR/ios.toolchain.cmake"
if [ ! -f "$IOS_TOOLCHAIN" ]; then
    echo "Downloading ios-cmake toolchain file (pinned to 4.5.0)..."
    curl -L -o "$IOS_TOOLCHAIN" \
        https://raw.githubusercontent.com/leetal/ios-cmake/4.5.0/ios.toolchain.cmake
fi

# ---------------------------------------------------------------------------
# 1. Fetch sources (shared across all platform slices)
# ---------------------------------------------------------------------------
if [ ! -d "$TEMP_DIR/openjpeg-2.5.0" ]; then
    echo "Downloading OpenJPEG 2.5.0..."
    cd "$TEMP_DIR"
    curl -L -o openjpeg-2.5.0.tar.gz https://github.com/uclouvain/openjpeg/archive/v2.5.0.tar.gz
    tar xzf openjpeg-2.5.0.tar.gz
fi

if [ ! -d "$TEMP_DIR/dcmtk-3.6.8" ]; then
    echo "Downloading DCMTK 3.6.8..."
    cd "$TEMP_DIR"
    curl -L -O https://dicom.offis.de/download/dcmtk/dcmtk368/dcmtk-3.6.8.tar.gz
    tar xzf dcmtk-3.6.8.tar.gz
    rm dcmtk-3.6.8.tar.gz
fi

# ---------------------------------------------------------------------------
# 1b. Patch DCMTK's own Darwin/iOS feature-test-macro flags
# ---------------------------------------------------------------------------
# Root-caused by diffing DCMTK's CMake/dcmtkPrepare.cmake against the actual
# failing clang invocation from a real build attempt: DCMTK 3.6.8 hand-builds
# CMAKE_CXX_FLAGS/CMAKE_C_FLAGS itself, per-Darwin-variant, in several
# separate branches of dcmtkPrepare.cmake. Its "plain macOS" branch (~line
# 498) adds -D_DARWIN_C_SOURCE, which is what makes fseeko/ftello visible to
# libc++'s <fstream> (used transitively by config/tests/arith.cc via
# ofstd/include/dcmtk/ofstd/ofstream.h). The branch(es) that fire for this
# iOS cross-compile (~lines 502 and 513, identified by matching the exact
# flag list -D_XOPEN_SOURCE_EXTENDED -D_XOPEN_SOURCE=500 ... -D_POSIX_C_SOURCE
# =199506L against a real failing build's clang command line) omit it -- an
# inconsistency in DCMTK's own platform detection, not something fixable by
# passing -DCMAKE_CXX_FLAGS=... on the `cmake` command line (tried first;
# confirmed by build output that DCMTK's own hand-built string always wins
# and any externally-supplied value never reaches the actual compile).
# Patching the source directly, once, right after download, is the reliable
# fix -- idempotent (checked via grep) so re-running this script is safe.
DCMTK_PREPARE_CMAKE="$TEMP_DIR/dcmtk-3.6.8/CMake/dcmtkPrepare.cmake"
if [ -f "$DCMTK_PREPARE_CMAKE" ] && ! grep -q '_POSIX_C_SOURCE=199506L -D_DARWIN_C_SOURCE' "$DCMTK_PREPARE_CMAKE"; then
    echo "Patching DCMTK's dcmtkPrepare.cmake to add -D_DARWIN_C_SOURCE to its iOS/Darwin flag branches..."
    sed -i '' \
        -e 's/-D_BSD_COMPAT -D_OSF_SOURCE -D_POSIX_C_SOURCE=199506L")/-D_BSD_COMPAT -D_OSF_SOURCE -D_POSIX_C_SOURCE=199506L -D_DARWIN_C_SOURCE")/' \
        "$DCMTK_PREPARE_CMAKE"
    if grep -q '_POSIX_C_SOURCE=199506L -D_DARWIN_C_SOURCE' "$DCMTK_PREPARE_CMAKE"; then
        echo "  Patch applied successfully."
    else
        echo "  WARNING: patch did not apply as expected -- inspect $DCMTK_PREPARE_CMAKE" \
             "manually around lines 495-515 (search for _POSIX_C_SOURCE=199506L) and compare" \
             "against the macOS branch a few lines above it, which already includes" \
             "-D_DARWIN_C_SOURCE and can be used as a template."
    fi
else
    echo "DCMTK dcmtkPrepare.cmake already patched (or not found yet) -- skipping."
fi

# ---------------------------------------------------------------------------
# 2. Build one platform slice (OpenJPEG, then DCMTK against it)
#    $1 = slice name (e.g. "ios-arm64"), $2 = ios-cmake PLATFORM value
# ---------------------------------------------------------------------------
build_slice() {
    local SLICE_NAME="$1"
    local IOS_CMAKE_PLATFORM="$2"
    local SLICE_DIR="$TEMP_DIR/slices/$SLICE_NAME"
    local OPENJPEG_INSTALL="$SLICE_DIR/openjpeg"
    local DCMTK_INSTALL="$SLICE_DIR/dcmtk"

    echo ""
    echo "=== Building slice: $SLICE_NAME (PLATFORM=$IOS_CMAKE_PLATFORM) ==="
    mkdir -p "$SLICE_DIR"

    echo "--- OpenJPEG ($SLICE_NAME) ---"
    rm -rf "$TEMP_DIR/openjpeg-2.5.0/build-$SLICE_NAME"
    mkdir -p "$TEMP_DIR/openjpeg-2.5.0/build-$SLICE_NAME"
    cd "$TEMP_DIR/openjpeg-2.5.0/build-$SLICE_NAME"
    "$CMAKE_BIN" .. \
        -DCMAKE_TOOLCHAIN_FILE="$IOS_TOOLCHAIN" \
        -DPLATFORM="$IOS_CMAKE_PLATFORM" \
        -DDEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$OPENJPEG_INSTALL" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_CODEC=OFF \
        -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_LCMS2=ON
    "$CMAKE_BIN" --build . --target install --parallel 4

    echo "--- DCMTK ($SLICE_NAME) ---"
    rm -rf "$TEMP_DIR/dcmtk-3.6.8/build-$SLICE_NAME"
    mkdir -p "$TEMP_DIR/dcmtk-3.6.8/build-$SLICE_NAME"
    cd "$TEMP_DIR/dcmtk-3.6.8/build-$SLICE_NAME"
    # NOTE (iOS port): DCMTK's CMake configure step originally failed at
    # INSPECT_FUNDAMENTAL_ARITHMETIC_TYPES (CMakeLists.txt:52), which
    # try-compiles config/tests/arith.cc -> ofstd/include/dcmtk/ofstd/ofstream.h
    # -> libc++'s <fstream>, which calls ::fseeko/::ftello unconditionally --
    # not visible under the feature-test macros DCMTK's iOS/Darwin branch of
    # CMake/dcmtkPrepare.cmake constructs for this platform. Passing
    # -DCMAKE_CXX_FLAGS/-DCMAKE_C_FLAGS here on the `cmake` command line was
    # tried first and confirmed NOT to work: dcmtkPrepare.cmake hand-builds
    # its own CMAKE_CXX_FLAGS/CMAKE_C_FLAGS string per Darwin variant and that
    # always wins by the time any actual compile happens. The real fix is the
    # source patch applied above (step 1b), which adds -D_DARWIN_C_SOURCE
    # directly to DCMTK's own flag-construction lines in dcmtkPrepare.cmake --
    # mirroring what DCMTK's own "plain macOS" branch already does. No flags
    # need to be (or should be) passed in from here anymore.
    "$CMAKE_BIN" .. \
        -DCMAKE_TOOLCHAIN_FILE="$IOS_TOOLCHAIN" \
        -DPLATFORM="$IOS_CMAKE_PLATFORM" \
        -DDEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$DCMTK_INSTALL" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DDCMTK_WITH_TIFF=OFF \
        -DDCMTK_WITH_PNG=OFF \
        -DDCMTK_WITH_XML=OFF \
        -DDCMTK_WITH_OPENSSL=OFF \
        -DDCMTK_WITH_ICONV=OFF \
        -DDCMTK_ENABLE_CXX11=ON \
        -DDCMTK_WITH_OPENJPEG=ON \
        -DCMAKE_PREFIX_PATH="$OPENJPEG_INSTALL"
    "$CMAKE_BIN" --build . --target install --parallel 4

    echo "Slice $SLICE_NAME done -> $DCMTK_INSTALL, $OPENJPEG_INSTALL"
}

# Device: arm64 only (no iOS device ships any other architecture in the
# iOS 17+ deployment target range this project uses).
build_slice "ios-arm64" "OS64"

# Simulator: build both arm64 (Apple Silicon Macs) and x86_64 (Intel Macs),
# lipo them together below into one universal simulator slice, matching how
# Apple's own XCFrameworks ship a single "simulator" variant covering both.
build_slice "ios-arm64-simulator" "SIMULATORARM64"
build_slice "ios-x86_64-simulator" "SIMULATOR64"

# ---------------------------------------------------------------------------
# 3. Lipo the two simulator slices together per-library
# ---------------------------------------------------------------------------
echo ""
echo "=== Creating universal simulator libraries (lipo) ==="
SIM_UNIVERSAL_DIR="$TEMP_DIR/slices/ios-simulator-universal"
mkdir -p "$SIM_UNIVERSAL_DIR/lib"

ARM64_SIM_LIBDIR="$TEMP_DIR/slices/ios-arm64-simulator/dcmtk/lib"
X86_64_SIM_LIBDIR="$TEMP_DIR/slices/ios-x86_64-simulator/dcmtk/lib"
ARM64_SIM_OPENJPEG_LIBDIR="$TEMP_DIR/slices/ios-arm64-simulator/openjpeg/lib"
X86_64_SIM_OPENJPEG_LIBDIR="$TEMP_DIR/slices/ios-x86_64-simulator/openjpeg/lib"

lipo_all() {
    local DIR_A="$1" DIR_B="$2"
    for lib_a in "$DIR_A"/*.a; do
        [ -e "$lib_a" ] || continue
        local name="$(basename "$lib_a")"
        local lib_b="$DIR_B/$name"
        if [ -f "$lib_b" ]; then
            lipo -create "$lib_a" "$lib_b" -output "$SIM_UNIVERSAL_DIR/lib/$name"
            echo "  lipo'd $name"
        else
            echo "  WARNING: $name missing from $DIR_B -- skipping (arch mismatch between slices?)"
        fi
    done
}
lipo_all "$ARM64_SIM_LIBDIR" "$X86_64_SIM_LIBDIR"
lipo_all "$ARM64_SIM_OPENJPEG_LIBDIR" "$X86_64_SIM_OPENJPEG_LIBDIR"

# Headers are architecture-independent -- just reuse the arm64 simulator ones.
cp -R "$TEMP_DIR/slices/ios-arm64-simulator/dcmtk/include" "$SIM_UNIVERSAL_DIR/include-dcmtk"
cp -R "$TEMP_DIR/slices/ios-arm64-simulator/openjpeg/include" "$SIM_UNIVERSAL_DIR/include-openjpeg"

# ---------------------------------------------------------------------------
# 4. Package each library as an XCFramework (device + universal simulator)
# ---------------------------------------------------------------------------
echo ""
echo "=== Creating XCFrameworks ==="
DEVICE_DCMTK_LIBDIR="$TEMP_DIR/slices/ios-arm64/dcmtk/lib"
DEVICE_DCMTK_INCLUDE="$TEMP_DIR/slices/ios-arm64/dcmtk/include"
DEVICE_OPENJPEG_LIBDIR="$TEMP_DIR/slices/ios-arm64/openjpeg/lib"
DEVICE_OPENJPEG_INCLUDE="$TEMP_DIR/slices/ios-arm64/openjpeg/include"

make_xcframework() {
    local LIB_NAME="$1"          # e.g. "dcmdata" (file will be libdcmdata.a)
    local DEVICE_LIBDIR="$2"
    local DEVICE_INCLUDE="$3"
    local SIM_LIBDIR="$4"
    local SIM_INCLUDE="$5"

    local FILE_NAME="lib${LIB_NAME}.a"
    local DEVICE_LIB="$DEVICE_LIBDIR/$FILE_NAME"
    local SIM_LIB="$SIM_LIBDIR/$FILE_NAME"
    local OUT="$XCFRAMEWORKS_DIR/${LIB_NAME}.xcframework"

    if [ ! -f "$DEVICE_LIB" ] || [ ! -f "$SIM_LIB" ]; then
        echo "  SKIP $LIB_NAME (missing device or simulator .a -- check build logs above)"
        return
    fi

    rm -rf "$OUT"
    xcodebuild -create-xcframework \
        -library "$DEVICE_LIB" -headers "$DEVICE_INCLUDE" \
        -library "$SIM_LIB" -headers "$SIM_INCLUDE" \
        -output "$OUT"
    echo "  created $OUT"
}

# DCMTK libraries actually linked by Package.swift's DCMTKWrapper target today.
DCMTK_LIBS="dcmimage dcmimgle dcmdata oflog ofstd dcmjpeg dcmjpls dcmtkcharls ijg8 ijg12 ijg16 oficonv"
for lib in $DCMTK_LIBS; do
    make_xcframework "$lib" "$DEVICE_DCMTK_LIBDIR" "$DEVICE_DCMTK_INCLUDE" \
        "$SIM_UNIVERSAL_DIR/lib" "$SIM_UNIVERSAL_DIR/include-dcmtk"
done
# dcmnet/dcmqrdb/dcmtls (currently built but unused -- see PACS networking task)
for lib in dcmnet dcmqrdb dcmtls; do
    make_xcframework "$lib" "$DEVICE_DCMTK_LIBDIR" "$DEVICE_DCMTK_INCLUDE" \
        "$SIM_UNIVERSAL_DIR/lib" "$SIM_UNIVERSAL_DIR/include-dcmtk"
done

make_xcframework "openjp2" "$DEVICE_OPENJPEG_LIBDIR" "$DEVICE_OPENJPEG_INCLUDE" \
    "$SIM_UNIVERSAL_DIR/lib" "$SIM_UNIVERSAL_DIR/include-openjpeg"

echo ""
echo "Done. XCFrameworks are in: $XCFRAMEWORKS_DIR"
echo "Package.swift's DCMTKWrapper target still needs to be switched from its"
echo "current unsafeFlags-based -L linking to .binaryTarget entries pointing"
echo "at these XCFrameworks for the iOS platform slice -- see docs/iOS-Build.md."
