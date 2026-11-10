#!/usr/bin/env bash
#
# Builds SQLite for Android. GRDB links the platform's SQLite, but the NDK
# has none, so an Android build of DogecoinKit links this one instead and
# the app ships it.
#
# Usage: Scripts/build-android-sqlite.sh [ABI ...]
#   ABIs: arm64-v8a (the default), x86_64, armeabi-v7a
#
# Writes .build/android-sqlite/include/sqlite3.h and, for each ABI,
# .build/android-sqlite/<ABI>/libsqlite3.so, then prints the flags that
# point `swift build` at them.
#
# Environment:
#   ANDROID_NDK_HOME   The NDK to build with. Default: the newest NDK in the
#                      Android SDK.
#   ANDROID_API_LEVEL  The minimum API level. Default: 28, the Swift SDK's.

set -euo pipefail

sqlite_version=3540100 # 3.54.1
sqlite_year=2026
# sqlite.org publishes the SHA3-256 (92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30);
# this is the SHA-256 of the same file, which every host can check.
sqlite_sha256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9

api_level="${ANDROID_API_LEVEL:-28}"
output="$(cd "$(dirname "$0")/.." && pwd)/.build/android-sqlite"
abis=("$@")
if [[ ${#abis[@]} -eq 0 ]]; then
    abis=(arm64-v8a)
fi

case "$(uname -s)" in
    Darwin)
        host=darwin-x86_64
        android_sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
        ;;
    Linux)
        host=linux-x86_64
        android_sdk="${ANDROID_HOME:-$HOME/Android/Sdk}"
        ;;
    *)
        echo "error: unsupported host $(uname -s)" >&2
        exit 1
        ;;
esac

ndk="${ANDROID_NDK_HOME:-$(find "$android_sdk/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n 1)}"
toolchain="$ndk/toolchains/llvm/prebuilt/$host/bin"
if [[ ! -d "$toolchain" ]]; then
    echo "error: no NDK found; set ANDROID_NDK_HOME" >&2
    exit 1
fi

# Download and verify the amalgamation once.
source_dir="$output/sqlite-amalgamation-$sqlite_version"
if [[ ! -f "$source_dir/sqlite3.c" ]]; then
    mkdir -p "$output"
    archive="$output/sqlite-amalgamation-$sqlite_version.zip"
    curl --fail --silent --show-error --location \
        "https://sqlite.org/$sqlite_year/sqlite-amalgamation-$sqlite_version.zip" --output "$archive"
    if command -v shasum >/dev/null; then
        actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
    else
        actual=$(sha256sum "$archive" | cut -d ' ' -f 1)
    fi
    if [[ "$actual" != "$sqlite_sha256" ]]; then
        rm -f "$archive"
        echo "error: checksum mismatch for $archive" >&2
        exit 1
    fi
    unzip -q -o "$archive" -d "$output"
    rm "$archive"
fi

mkdir -p "$output/include"
cp "$source_dir/sqlite3.h" "$output/include/"

for abi in "${abis[@]}"; do
    case "$abi" in
        arm64-v8a)
            clang="aarch64-linux-android$api_level-clang"
            triple="aarch64-unknown-linux-android$api_level"
            ;;
        x86_64)
            clang="x86_64-linux-android$api_level-clang"
            triple="x86_64-unknown-linux-android$api_level"
            ;;
        armeabi-v7a)
            clang="armv7a-linux-androideabi$api_level-clang"
            triple="armv7-unknown-linux-android$api_level"
            ;;
        *)
            echo "error: unknown ABI $abi (expected arm64-v8a, x86_64, or armeabi-v7a)" >&2
            exit 1
            ;;
    esac

    mkdir -p "$output/$abi"
    # GRDB compiles its snapshot and FTS5 APIs in, so SQLite needs them too.
    # Temporary tables stay in memory, as in Android's own SQLite: apps have
    # no writable temporary directory by default. 16 KB page alignment keeps
    # the library loadable on every Android 15+ device.
    "$toolchain/$clang" -shared -fPIC -O2 \
        -DSQLITE_THREADSAFE=1 \
        -DSQLITE_ENABLE_FTS5 \
        -DSQLITE_ENABLE_SNAPSHOT \
        -DSQLITE_TEMP_STORE=3 \
        -Wl,-z,max-page-size=16384 \
        -Wl,-soname,libsqlite3.so \
        "$source_dir/sqlite3.c" -o "$output/$abi/libsqlite3.so" -lm

    echo "$abi: $output/$abi/libsqlite3.so"
    echo "  swift build --triple $triple -Xcc -I$output/include -Xlinker -L$output/$abi ..."
done
