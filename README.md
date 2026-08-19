# Weaver

A native HTTPS debugging proxy for macOS and iOS.

Weaver captures HTTP(S) traffic, decrypts it with a locally generated root
certificate, and lets you inspect requests and responses — headers, bodies,
timing — in a native interface.

## Features

- HTTP/1.1, HTTP/2, and WebSocket capture
- HTTPS decryption via a per-install root CA generated on your machine
- Traffic grouped by client app and by domain, with live filtering and search
- Request/response inspector with syntax-highlighted, collapsible bodies
- HAR export
- Standalone on-device capture on iOS — no desktop, no jailbreak

## Requirements

- macOS 14 or later
- Xcode 16 / Swift 6
- iOS 26 or later for the iOS app

## Build

```sh
cd apple
swift build
swift run Weaver
```

The iOS app is an Xcode project under `apple/apps/ios`. Set your Apple
developer team before generating it:

```sh
export DEVELOPMENT_TEAM=YOURTEAMID
```

## How it works

Weaver runs a local proxy and generates a root certificate the first time it
starts. Once that certificate is trusted, TLS connections routed through the
proxy can be decrypted and displayed. The certificate is created on your device
and never leaves it.

Traffic from apps using certificate pinning cannot be decrypted. This is by
design on their part, and Weaver does not attempt to defeat it.

## License

Apache License 2.0 — see [LICENSE](./LICENSE).
