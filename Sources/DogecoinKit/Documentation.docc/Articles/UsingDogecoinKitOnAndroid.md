# Using DogecoinKit on Android

Build DogecoinKit with the Swift SDK for Android and run it in an Android app.

@Metadata {
    @PageKind(article)
}

## Overview

DogecoinKit runs the same wallet, transaction, SPV, and Electrum code on
Android as on Apple platforms. Where Android lacks an Apple framework,
DogecoinKit uses a portable replacement:

| On Apple platforms | On Android |
|--------------------|------------|
| Network.framework | SwiftNIO, with NIOSSL for TLS |
| CryptoKit | swift-crypto |
| `os.Logger` | logcat |
| The system's SQLite | SQLite you build and ship with the app |

One feature remains Apple-only: ``SecureKeyStorage``, which stores secrets in
the Keychain. On Android, protect the mnemonic with the Android Keystore
instead.

DogecoinKit doesn't include a Kotlin or Java interface. An Android app calls
it through a JNI bridge, such as one generated with swift-java.

### Build SQLite

GRDB, which stores the block headers, links the platform's SQLite, and the
Android NDK doesn't provide one. Build it once for each ABI you ship:

```sh
Scripts/build-android-sqlite.sh arm64-v8a x86_64
```

The script downloads SQLite, checks its pinned checksum, compiles it with the
newest installed NDK (or the one in `ANDROID_NDK_HOME`), and writes
`.build/android-sqlite/<ABI>/libsqlite3.so` along with the header.

### Build DogecoinKit

Use the Swift SDK for Android that matches your Swift toolchain, and point
the build at SQLite:

```sh
swift build \
    --swift-sdk swift-6.4.1-RELEASE_android \
    --triple aarch64-unknown-linux-android28 \
    -Xcc -I.build/android-sqlite/include \
    -Xlinker -L.build/android-sqlite/arm64-v8a
```

Package `libsqlite3.so` in the app's `jniLibs/<ABI>` folder, next to the
Swift runtime libraries and the NDK's `libc++_shared.so`.

### Choose Where Headers Go

An Android app process has no home directory, so the caches directory that
DogecoinKit stores headers in by default resolves to a location the app can't
write. Pass a directory inside the app's files or cache directory as
`storageDirectory` when you create ``SPVSyncManager`` or ``HeaderChain``:

```swift
// `filesDirectory` is the path of the app's Context.getFilesDir().
let sync = SPVSyncManager(
    network: .mainnet,
    storageDirectory: URL(filePath: filesDirectory).appending(path: "headers")
)
```

To start from a bundled header cache, copy `headers.sqlite` and
`metadata.json` out of the app's assets into a directory first, since assets
aren't files on disk, and pass that directory as `bundledCacheDirectory`.

Peers that ``PeerManager`` bans for misbehaving stay banned only until the
process exits, because `UserDefaults` doesn't persist on Android.

### Read the Logs

DogecoinKit logs to logcat with the tag `DogecoinKit.<category>`, such as
`DogecoinKit.Peer` or `DogecoinKit.electrum`:

```sh
adb logcat 'DogecoinKit.Peer:I' '*:S'
```

As with `os.Logger` on Apple platforms, release builds leave out debug
messages and show interpolated values as `<private>` unless they're numbers,
Booleans, or marked `privacy: .public`. Debug builds log everything.

### Run the Tests on a Device

`Scripts/test-android.sh` builds the test suite for Android, copies it to the
connected device or emulator with every library it needs, and runs it:

```sh
SWIFT=/path/to/swift-6.4.1-RELEASE/usr/bin/swift Scripts/test-android.sh arm64-v8a
```

Set `DOGECOINKIT_LIVE_P2P=1` and `DOGECOINKIT_LIVE_ELECTRUM=1` to include the
tests that sync headers from live peers and query live Electrum servers.
