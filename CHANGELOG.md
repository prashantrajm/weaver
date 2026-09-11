# Changelog

All notable changes to Weaver. `apple/scripts/publish-release.sh` uses the
section matching `CFBundleShortVersionString` as the GitHub release notes, so
keep the top section for the version currently in `Info.plist`.

## 0.2.0

### Added

- **Captures this Mac automatically.** Starting the proxy sets the Mac's own
  HTTP/HTTPS system proxy to Weaver (one admin prompt per launch, no helper
  tool) and installs the root CA first if it isn't trusted yet. Settings are
  snapshotted and restored on Stop, Quit, and Ctrl-C; a crash is recovered on
  the next launch. A "This Mac" toolbar toggle turns it off for device-only
  capture.
- **Traffic attributed to the real process.** Connections from this Mac are
  resolved to the app that opened them by PID, not guessed from the
  User-Agent. Safari's and Chrome's networking helpers roll up to their app,
  CLI tools keep their own name, and the sidebar shows the real app icon.

## 0.1.0

First public release of the macOS app: HTTP/1.1, HTTP/2 and WebSocket
capture, HTTPS decryption via a per-install root CA, traffic grouped by app
and domain, request/response inspector, HAR export.
