# laconicman/swift-libxray — GitHub

# swift-libxray

[![CI](https://github.com/laconicman/swift-libxray/actions/workflows/ci.yml/badge.svg)](https://github.com/laconicman/swift-libxray/actions/workflows/ci.yml) [![License: Apache 2.0](https://camo.githubusercontent.com/f60cb0de87bbb87501d20c4fb0c9730ffee1dc4499e9ce303d477ffe8925f98b/68747470733a2f2f696d672e736869656c64732e696f2f62616467652f6c6963656e73652d4170616368655f322e302d626c75652e737667)](https://github.com/laconicman/swift-libxray/blob/main/LICENSE.txt)

Xray-core for Swift: the **official** [XTLS/libXray](https://github.com/XTLS/libXray) Apple cgo build (`LibXray.xcframework`, static, unpatched) as a SwiftPM binary target, plus `XrayCore`, a typed actor façade over its `CGoInvoke` JSON API.

- **Official, unpatched, static.** The artifact is exactly what `XTLS/libXray` releases for Apple platforms — `go build -buildmode=c-archive`, lipo'd per SDK — re-zipped only so the xcframework sits at the archive root (the layout SwiftPM's `binaryTarget` wants). One Go runtime per process, one exported symbol pair: `CGoInvoke` / `CGoFree`.
- **Why not dima-u's wrappers.** `dima-u/SwiftyXrayCore` 1.1.0 (2025-12-26) bundles Xray 25.10.15 with Outline's tun2socks in one gomobile framework; `dima-u/SwiftyXrayKit` 2.0.0 (2026-05-13) depends on `dima-u/libXray-apple` at `v26.3.27-ios`, a fork built on a patched Xray-core (`dima-u/Xray-core-apple`) so the TUN inbound works over a `SOCK_STREAM` socketpair inside the iOS Network Extension sandbox. Both exist to solve the packet-tunnel problem; this package has none and tracks the unmodified upstream — what Xray upstream ships is what runs.

## Install

```
dependencies: [
    .package(url: "https://github.com/laconicman/swift-libxray", from: "0.1.0"),
],
```

and depend on the `XrayCore` product. Platforms: macOS 13, iOS 15 — the artifact's own floors, read off its `LC_BUILD_VERSION`s (the xcframework also ships tvOS slices; they are simply undeclared here).

Toolchain: Swift 6.4 (Xcode 27). The manifest's `swift-tools-version` is 6.4; Xcode 26.6's SwiftPM (Swift 6.3.3) cannot parse it, so the package does not resolve there.

## Usage

All calls go through one actor — the Go runtime is process-global, so `XrayCore.shared` is its only door:

```
import XrayCore

let core = XrayCore.shared

try await core.version()                          // "26.10.21" — what the artifact really is
let ports = try await core.freePorts(3, excluding: [10808])

let outbounds = try await core.convertShareLinks(links)  // {"outbounds":[…]} as Data
let config = """
    {"log":{"access":"none","loglevel":"warning"},
     "inbounds":[{"tag":"in","listen":"127.0.0.1","port":\(ports[0]),
                  "protocol":"mixed","settings":{"udp":false}}],
     "outbounds":[…spliced from `outbounds`…]}
    """
try await core.test(configJSON: config)           // build-check only; no network
try await core.run(configJSON: config)            // returns before the inbounds accept!
await core.isRunning                              // getXrayState → data.running
try await core.stop()                             // restart in the same process works
```

Two behaviors to plan around (measured on macOS 26, Xray 26.10.21):

- **`run` returns before the inbounds accept** — the call itself is ~1 ms while the core finishes starting ~350 ms later. `isRunning` flips true at once; probe the inbound socket before sending traffic.
- **Xray logs to stderr**, not to the API: a start banner, then one `accepted` line per connection at the default `access` level. Set `"access":"none"` (and `"loglevel"`) in the config's `log` block if stderr is yours.
- `convertShareLinks` returns the engine's **flat** outbound shape — `settings:{address,port,id,encryption}` (no `vnext`/`users`), `pbk` → `realitySettings.password`, `#fragment` → `tag`. It is the format this core accepts.

Errors are typed: `XrayError` carries `method`, `stage` (`encode` / `invoke` / `decode`) and the engine's message verbatim.

## Provenance

Recorded in [`Upstream/v26.10.21.json`](https://github.com/laconicman/swift-libxray/blob/main/Upstream/v26.10.21.json) by `libxray-asset-tool`; upstream publishes no checksums, so this record is the provenance.

|  |  |
|---|---|
| Upstream | `https://github.com/XTLS/libXray/releases/download/v26.10.21/libxray-apple-cgo.zip` |
| Upstream SHA-256 | `f318d216bb3b16b18d7b04c54789d1feaa6b7571433ed5582c1fe776e3776ef1` |
| Upstream bytes | 101,519,579 |
| Asset | `LibXray-v26.10.21.xcframework.zip` on the `libxray-v26.10.21` release |
| Asset SHA-256 (SwiftPM checksum) | `c8827e11c5debb005e07510e7450bed399fab93b4dba5c24747b2f1864dfedc0` |
| Asset bytes | 101,517,039 |
| Slices | macos-arm64_x86_64 · ios-arm64 · ios-arm64_x86_64-simulator · tvos-arm64 · tvos-arm64_x86_64-simulator |
| Floors (LC_BUILD_VERSION) | macOS 13.0 · iOS 15.0 (tvOS slices exist, undeclared) |

To verify by hand: download the upstream zip and `shasum -a 256` it against the row above; then download the asset from the release and `swift package compute-checksum` it against the checksum row. Do not expect a local re-zip to reproduce that checksum: `zip` stamps local time and traverses in filesystem order, so the bytes differ across machines while the extracted trees are identical (`diff -r` them if in doubt) — TD-3.

## Versioning

Two tag schemes share this repo:

- **`libxray-vX.Y.Z`** — engine *artifacts* (Releases holding the xcframework zip). They are not SwiftPM versions and are ignored by it.
- **`0.x.y` (no `v`)** — the package's own semver tags, per milestone.

## For maintainers

`libxray-asset-tool` re-vendors the artifact:

```
swift run libxray-asset-tool v26.10.21
```

It downloads the upstream zip, hashes it, re-packs the xcframework into `Artifacts/` (git-ignored), records provenance into `Upstream/<tag>.json`, and prints the `.binaryTarget` snippet and the `gh release create` command. `url` and `checksum` in `Package.swift` always change together, and `Upstream/*.json` is never hand-edited.

The decisions and what each rejected are in the **Design** article of the DocC catalog (`Sources/XrayCore/XrayCore.docc/`), which is authoritative; the milestones are in `Roadmap.md` and the known compromises in `TechDebt.md` beside it.

## License

Apache 2.0 — see [LICENSE.txt](https://github.com/laconicman/swift-libxray/blob/main/LICENSE.txt). The `LibXray` artifact is XTLS/libXray's own build, redistributed unmodified: libXray under MIT, the Xray-core it embeds under MPL-2.0 — sources at the recorded upstream tag (`Upstream/v26.10.21.json`).

Source: https://github.com/laconicman/swift-libxray
