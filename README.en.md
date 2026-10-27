# NetDock

[简体中文](README.md)

A free, open-source, native Apple network workbench built with Swift, SwiftUI, and Network.framework. No third-party runtime dependencies.

This increment adds **M2 UDP + M3 workbench features** and a macOS-only Connection Monitor to the existing native macOS and universal iPhone/iPad apps. See the testing record for actual verification and remaining physical-device checks.

## Build and run

Open `NetDock.xcodeproj`. Choose `NetDockMac` for macOS or `NetDockMobile` for an iPhone/iPad simulator or device. The macOS app supports Apple silicon (arm64) only; Intel Macs are not supported. Minimum deployment targets: macOS 14 and iOS/iPadOS 17. Swift 6 / Xcode 16+ are required; this delivery was tested using Xcode 27.1 / Swift 6.4. Device builds require your own development team, unique bundle identifier, and signing setup. No personal credentials are included.

The Xcode project is checked in. After adding files, regenerate it with `ruby Scripts/generate_project.rb` using only Ruby's standard library. There is no XcodeGen dependency. Run `./Scripts/verify.sh` for core tests and both application builds. Actual execution results and remaining checks are in [docs/testing.md](docs/testing.md).

## Features

- Locally persisted independent sessions: create, edit, duplicate, delete, start, and stop.
- TCP client with hostnames, IPv4/IPv6, ordered bounded sends, continuous receive, timeout, and categorized failures.
- TCP server with multiple real clients, targeted sends, broadcast to connected clients, individual disconnect, and listener cleanup.
- IPv4/IPv6 unicast UDP client/server with local binding, datagram boundaries, actual endpoints, per-source reply and explicit server destinations.
- Periodic sending (100ms minimum), finite or continuous runs, pause/resume/stop, and cancellation on stop/background/failure.
- Named quick commands, bounded in-memory send history, log search/direction filtering, TXT/JSON log export and versioned session JSON import/export.
- macOS Connection Monitor with a native Table, refresh/pause, filters/sorting, change highlights, details/copy, visible port queries and CSV/JSON export. Public API visibility restrictions are explained in [monitor notes](docs/connection-monitor.md).
- UTF-8 and HEX input; precise HEX validation; lossless in-memory data records with TX/RX/SYS, timestamps, endpoints, HEX offsets, copy, clear, and auto-scroll.
- Simplified Chinese by default; immediate English switching. System/light/dark appearance; persisted preferences.
- Native macOS split navigation, adaptive iPad columns, and a compact iPhone workspace.

Create a TCP server listening on port 9000, then a client connecting to `127.0.0.1:9000` or `[::1]:9000`. Open additional clients to test targeted replies and broadcasts. Switching sessions leaves their connections running.

Keyboard shortcuts: Command-N creates a session; Command-K starts/stops; Command-Return sends; Command-L clears the current log.

TCP is a byte stream: read chunks are not message boundaries. An individual chunk may split a UTF-8 code point; undecodable bytes are preserved and available in HEX. Send completion confirms processing by the local network API, not acknowledgment by the remote application.

## Privacy and limits

Session configuration, saved commands and interface preferences stay local. Configuration imports create new identities without starting or replacing active sessions. Send history remains in bounded memory. User-selected exports include raw data. Raw traffic is never automatically written to disk. Each session retains up to 5,000 records or 30 MiB of payload. UI updates are batched every 100 ms. Pending sends are capped at 16 MiB; each listener accepts at most 128 connections.

There are no accounts, cloud services, ads, telemetry, or remote backend. Network traffic goes to user-specified destinations. The sandboxed Mac app enables inbound and outbound networking. iOS includes localized Local Network usage descriptions. Mobile sessions stop on entering the background; no continuous background listener is promised.

TCP automatic reconnect is still deferred. M4 covers stability and release preparation. This is not the complete V1 release. Physical-device networking and permissions must be checked separately from simulator tests.

The installed `apple-design` skill was inspected and found to target Web/CSS. Native layouts therefore follow [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/layout), as required by the specification. See [design](docs/design.md), [architecture](docs/architecture.md), and [privacy](docs/privacy.md).

Licensed under MIT, following the specification's recommendation. See [LICENSE](LICENSE).
