# Phase 8b Cleanup Classification (Safety-First)

Date: 2026-03-12
Owner: engineering

## Scope rule

Only remove code when both are true:
1. no runtime/compile references
2. no roadmap intent (active or deferred)

If either is unclear, classify as `needs-decision` and do not delete in this pass.

---

## Classification

### keep-active (do not delete)

- `apps/agent-macos/src/bridge.rs`, `trust.rs`, `launcher.rs`, `secrets.rs`, `main.rs`
  - Core trust/launcher/secrets runtime for v1.
- `apps/tls-terminator-macos/ArmadilloTLS/*` trust + UDS + menubar + Preferences paths
  - Core mac runtime.
- `apps/app-ios/ArmadilloMobile/ArmadilloMobile/Features/{Hub,Session,Pairing,Settings}`
  - Core iOS runtime.
- `docs/Pivot_docs/*` current pivot/phase specs.

### keep-deferred (intentional, not dead)

- Vault flows (`vault.*`) and related Rust/iOS call paths
  - Still part of product direction decisions; not safe to purge in 8b slice-1.
- iOS widget extension (`apps/app-ios/ArmadilloMobile/Symbiauthwidget/*`)
  - Explicitly referenced in docs and prior architecture; defer deletion pending product call.
  - Current product constraint: trust is foreground-only, so lock-screen widget should NOT present live trust state (`trusted/ttl/locked`) to avoid misleading UX.
  - Allowed near-term widget role: quick-entry/deep-link utility (`Open App` / `Start Session` path), not trust-status authority.
- `apps/nmhost-macos` + `apps/webext`
  - Legacy/deferred integration paths. Not active in trust-v1 runtime, but intentional backlog exists.

### delete-safe (this pass)

- None beyond already removed startup helper script.
- Rationale: current tree has many historical/deferred modules; bulk deletes without product decision are high-risk.

### needs-decision (product/roadmap call required)

- Keep vs sunset for:
  - `apps/nmhost-macos`
  - `apps/webext`
  - iOS widget extension (status surface explicitly deferred; quick-entry utility remains viable)
  - Vault feature depth for v1.x

## Locked decisions from 2026-03-12

1. Vault code remains deferred (not deleted in 8b now).
2. `nmhost` + `webext` remain deferred (not deleted in 8b now).
3. Widget remains deferred; if revived short-term, it is quick-entry only, not live trust-status display.

---

## Warning reduction plan (non-behavioral)

### Rust (~90 warnings baseline)

Pass order:
1. touched runtime files first (`trust`, `bridge`, `launcher`, `secrets`, `main`)
2. remove dead imports/vars, unreachable branches, duplicate helpers
3. defer broad legacy modules unless explicitly in scope

Guardrail:
- No protocol/behavior changes in warning-only commits.

### iOS (~23 warnings baseline)

Pass order:
1. active runtime views/models (`PairingViewModel`, `SessionView`, `HubView`, `Settings*`)
2. remove dead state, duplicate observers, stale dev-only UI artifacts
3. avoid large architectural rewrites inside warning pass

Guardrail:
- Keep UI behavior stable; warning cleanup only.

---

## First 8b implementation slice

1. Build warning inventory per target (Rust + iOS).
2. Fix warnings in active runtime files only.
3. Produce before/after warning counts.
4. Commit as `8b-slice1 warnings-only`.
