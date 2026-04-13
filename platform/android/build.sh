#!/usr/bin/env bash
# Build script for hangewubi Android IME
# Prerequisites:
#   - Android NDK (set ANDROID_NDK_HOME or NDK installed via Android Studio)
#   - Rust with Android targets: rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#   - cargo-ndk: cargo install cargo-ndk
#
# Usage:
#   ./build.sh              # Build Rust .so for all ABIs
#   ./build.sh --release    # Release build
#   ./build.sh --abi arm64  # Build for a single ABI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANDROID_DIR="$SCRIPT_DIR"
JNI_LIBS_DIR="$ANDROID_DIR/app/src/main/jniLibs"
ASSETS_DATA_DIR="$ANDROID_DIR/app/src/main/assets/data"

BUILD_TYPE="debug"
SINGLE_ABI=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            BUILD_TYPE="release"
            shift
            ;;
        --abi)
            SINGLE_ABI="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

CARGO_FLAGS=""
if [ "$BUILD_TYPE" = "release" ]; then
    CARGO_FLAGS="--release"
fi

# Map of ABI -> Rust target
declare -A ABI_MAP=(
    ["arm64-v8a"]="aarch64-linux-android"
    ["armeabi-v7a"]="armv7-linux-androideabi"
    ["x86_64"]="x86_64-linux-android"
)

# Determine which ABIs to build
if [ -n "$SINGLE_ABI" ]; then
    case "$SINGLE_ABI" in
        arm64) ABIS=("arm64-v8a") ;;
        arm32|armv7) ABIS=("armeabi-v7a") ;;
        x86_64|x64) ABIS=("x86_64") ;;
        *) ABIS=("$SINGLE_ABI") ;;
    esac
else
    ABIS=("arm64-v8a" "armeabi-v7a" "x86_64")
fi

echo "=== Building hangewubi for Android ==="
echo "Build type: $BUILD_TYPE"
echo "ABIs: ${ABIS[*]}"

# Step 1: Copy data files to assets
echo ""
echo "--- Copying data files to assets ---"
mkdir -p "$ASSETS_DATA_DIR"
cp "$PROJECT_ROOT/data/wubi86.txt" "$ASSETS_DATA_DIR/"
echo "Copied wubi86.txt"
if [ -f "$PROJECT_ROOT/data/pinyin.txt" ]; then
    cp "$PROJECT_ROOT/data/pinyin.txt" "$ASSETS_DATA_DIR/"
    echo "Copied pinyin.txt"
fi

# Step 2: Build Rust shared library for each ABI using cargo-ndk
echo ""
echo "--- Building Rust library ---"
cd "$PROJECT_ROOT"

# Set minimum API level
export ANDROID_NDK_MIN_API=24

for abi in "${ABIS[@]}"; do
    target="${ABI_MAP[$abi]}"
    echo ""
    echo "Building for $abi ($target)..."

    cargo ndk --target "$target" --platform 24 build $CARGO_FLAGS

    # Copy the .so to jniLibs
    mkdir -p "$JNI_LIBS_DIR/$abi"

    if [ "$BUILD_TYPE" = "release" ]; then
        SO_PATH="$PROJECT_ROOT/target/$target/release/libhangewubi.so"
    else
        SO_PATH="$PROJECT_ROOT/target/$target/debug/libhangewubi.so"
    fi

    if [ -f "$SO_PATH" ]; then
        cp "$SO_PATH" "$JNI_LIBS_DIR/$abi/libhangewubi.so"
        echo "Copied libhangewubi.so -> jniLibs/$abi/"
    else
        echo "ERROR: $SO_PATH not found!"
        exit 1
    fi
done

echo ""
echo "=== Rust build complete ==="
echo ""
echo "Next steps:"
echo "  1. Open platform/android/ in Android Studio"
echo "  2. Or run: cd platform/android && ./gradlew assembleDebug"
echo "  3. Install APK: adb install app/build/outputs/apk/debug/app-debug.apk"
echo "  4. Enable the IME in Settings -> System -> Languages & Input -> On-screen keyboard"
