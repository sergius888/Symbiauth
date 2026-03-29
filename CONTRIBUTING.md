# Contributing

Keep changes small and testable.

## Before You Open A PR

- explain what changed
- explain how you tested it
- mention security-sensitive behavior if you touched trust, secrets, shell injection, pairing, or local storage

## Good First Rules

- do not do giant renames unless the PR is only a rename
- do not mix refactors, feature work, and visual churn in one PR
- do not commit private keys, certificates, or local build output
- do not widen security claims in docs without matching implementation

## Useful Checks

Rust:

```bash
cargo check --manifest-path apps/agent-macos/Cargo.toml
```

macOS app:

```bash
xcodebuild -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj \
  -scheme ArmadilloTLS \
  -configuration Debug \
  -derivedDataPath apps/tls-terminator-macos/build \
  build
```

iPhone app:

```bash
xcodebuild -project apps/app-ios/ArmadilloMobile/ArmadilloMobile.xcodeproj \
  -scheme ArmadilloMobile \
  -configuration Debug \
  -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Browser Extension Dev Key

Do not commit `packages/webext/dev/dev_key.pem`.

Generate it locally if you need a stable development extension ID:

```bash
mkdir -p packages/webext/dev
openssl genrsa -out packages/webext/dev/dev_key.pem 2048
openssl rsa -in packages/webext/dev/dev_key.pem -pubout -outform DER \
  | base64 > packages/webext/dev/public_key_base64.txt
```
