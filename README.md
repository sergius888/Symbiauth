# SymbiAuth

SymbiAuth is an experimental iPhone + macOS trust system for short-lived sensitive work.

The current build has three real surfaces:
- `Secret Chamber` on macOS for secrets, notes, and documents
- `Trusted Shell` for trust-bound terminal work with on-demand secret injection
- `chamber` CLI commands for running a single command with injected env vars

This repo is public because the project is real and usable, not because it is finished.

## What It Is

- local-first
- paired iPhone + Mac
- trust session on the phone
- chamber on the Mac
- short trusted windows instead of a permanently unlocked vault

## What It Is Not

- not production security software
- not a polished password-manager replacement
- not a full terminal emulator
- not a promise that a compromised Mac cannot reach local state

If you want the blunt version: this is an experimental system with working pieces, not a finished security product.

## Current Shape

What works today:
- iPhone trust session flow
- macOS menu bar app
- Secret Chamber
- Trusted Shell
- chamber CLI
- tags, filters, favorites, notes, documents

What is still rough:
- naming still has old internal traces like `Armadillo` and `dreiglaser`
- some internal names and target names still need cleanup
- browser-extension work exists, but it is not the main public story right now

## Repo Layout

```text
apps/
  agent-macos/           Rust local agent and CLI
  app-ios/               iPhone app
  tls-terminator-macos/  macOS menu bar app and chamber UI
packages/
  protocol/              shared protocol definitions
  webext/                browser-extension work
docs/
  Progress/              work log and running notes
  Pivot_docs/            product and implementation notes
```

## Running It

You need:
- macOS
- Xcode
- Rust
- a physical iPhone for the trust flow

Start the Rust agent:

```bash
cargo run --manifest-path apps/agent-macos/Cargo.toml
```

Build and run the macOS app:

```bash
xcodebuild -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj \
  -scheme ArmadilloTLS \
  -configuration Debug \
  -derivedDataPath apps/tls-terminator-macos/build \
  build
open apps/tls-terminator-macos/build/Build/Products/Debug/ArmadilloTLS.app
```

Run the iPhone app from Xcode:

```text
apps/app-ios/ArmadilloMobile/ArmadilloMobile.xcodeproj
```

## CLI Example

With trust active on the phone:

```bash
cargo run --manifest-path apps/agent-macos/Cargo.toml --bin agent-cli -- chamber status
```

Run one command with an injected env var:

```bash
cargo run --manifest-path apps/agent-macos/Cargo.toml --bin agent-cli -- \
  chamber run --env GEMINI_API_KEY -- \
  bash -lc 'echo ${#GEMINI_API_KEY}'
```

## Security Notes

Read [Security.md](Security.md) before treating this like a real security tool.

Short version:
- trust gating is real
- local storage is real
- shell injection is real
- the threat model is still narrower than a finished commercial product

## Naming

Public name: `SymbiAuth`

Internal traces you will still see in the repo:
- `Armadilo`
- `Armadillo`
- `ArmadilloTLS`
- `ArmadilloMobile`
- `com.dreiglaser.*`

Those traces are not the public product name. They are migration debt.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
