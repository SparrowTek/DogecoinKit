#!/usr/bin/env bash
#
# Builds DogecoinKit's tests for Android and runs them on the connected
# device or emulator.
#
# Usage: Scripts/test-android.sh [ABI]
#   ABI: arm64-v8a (the default) or x86_64, matching the device.
#
# Environment:
#   SWIFT           The `swift` to build with. Default: swift on PATH. A Swift
#                   SDK for Android of the same version must be installed.
#   ANDROID_SERIAL  The device adb talks to, when more than one is connected.
#   DOGECOINKIT_LIVE_P2P=1, ELECTRUM_INTEGRATION_TESTS=1
#                   Also run the live-network tests, from the device.

set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
swift="${SWIFT:-swift}"
abi="${1:-arm64-v8a}"
case "$abi" in
    arm64-v8a) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *)
        echo "error: unsupported ABI $abi (expected arm64-v8a or x86_64)" >&2
        exit 1
        ;;
esac
triple="$arch-unknown-linux-android28"

# A Swift SDK only works with the toolchain release it was built for.
release=$("$swift" --version 2>&1 | sed -nE 's/.*\((swift-[0-9.]+-RELEASE)\).*/\1/p' | head -n 1)
sdk="${release}_android"
if ! "$swift" sdk list | grep -qx "$sdk"; then
    echo "error: no Swift SDK for Android matches ${release:-this toolchain}; install $sdk or set SWIFT to a matching toolchain" >&2
    exit 1
fi

"$package_root/Scripts/build-android-sqlite.sh" "$abi" >/dev/null
sqlite="$package_root/.build/android-sqlite"

build_options=(--package-path "$package_root" --swift-sdk "$sdk" --triple "$triple" --scratch-path "$package_root/.build/android-$abi")
"$swift" build --build-tests "${build_options[@]}" -Xcc "-I$sqlite/include" -Xlinker "-L$sqlite/$abi"
products=$("$swift" build --show-bin-path "${build_options[@]}")
configuration=$("$swift" sdk configure --show-configuration "$sdk" "$triple")
swift_resources=$(sed -n 's/^swiftResourcesPath: //p' <<<"$configuration")
sysroot=$(sed -n 's/^sdkRootPath: //p' <<<"$configuration")

# The runner loads the Swift runtime, the NDK's C++ runtime, and SQLite from
# its own directory.
staging="$package_root/.build/android-$abi/device"
rm -rf "$staging"
mkdir -p "$staging"
cp "$products/DogecoinKitTests-test-runner" "$products/DogecoinKitTests.so" "$staging/"
cp "$swift_resources"/android/*.so "$staging/"
cp "$sysroot/usr/lib/$arch-linux-android/libc++_shared.so" "$staging/"
cp "$sqlite/$abi/libsqlite3.so" "$staging/"

device_dir=/data/local/tmp/DogecoinKitTests
adb shell "rm -rf $device_dir && mkdir -p $device_dir/tmp"
adb push "$staging/." "$device_dir" >/dev/null

environment="LD_LIBRARY_PATH=. HOME=$device_dir/tmp TMPDIR=$device_dir/tmp"
for name in DOGECOINKIT_LIVE_P2P ELECTRUM_INTEGRATION_TESTS; do
    if [[ -n "${!name:-}" ]]; then
        environment+=" $name=${!name}"
    fi
done
adb shell "cd $device_dir && $environment ./DogecoinKitTests-test-runner --testing-library swift-testing"
