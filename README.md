# PaseoMac

Native SwiftUI client for the Paseo daemon. Connects to a remote daemon (e.g. on a VPS) over WebSocket, lets you view and drive coding agents from a lightweight Mac window with first-class paste and drag-drop for images and files.

Not affiliated with or endorsed by the Paseo project. Talks to the open-source `@getpaseo/server` daemon.

## Status

Pre-alpha. Phase 0 scaffold only — see `PLAN.md` for the roadmap.

## Requirements

- macOS 14.0 or later
- Xcode 16+ command line tools (`xcodebuild -version`)
- A reachable Paseo daemon (local or remote) — install via `npm i -g @getpaseo/cli` and run `paseo onboard`

## Build (SPM, SSH-friendly)

```bash
swift build -c release
./scripts/bundle.sh            # wraps .build/release/PaseoMac into build/PaseoMac.app
open build/PaseoMac.app
```

## Dev loop

```bash
swift build
./scripts/bundle.sh
open build/PaseoMac.app
```

## Configuration

On first launch PaseoMac prompts for a daemon endpoint (host:port) and pairing token. Both are stored in Keychain under service `sh.paseo.mac.client`.

## License

Source under AGPLv3, matching upstream Paseo. See `LICENSE`.
