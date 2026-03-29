# Phase 8b Slice 2 Decisions (Locked)

Date: 2026-03-12  
Owner: Codex + user

## Goal

Define exactly what is in-scope for cleanup now vs deferred, so cleanup stays safe and non-destructive.

## Decisions

1. `widget` (iOS widget extension)
- Status: `defer`
- Rationale: currently no strong, unique lock-screen value in the foreground-trust model.
- Action now: keep compiling, no removal, no major feature work.
- Revisit trigger: when we define a concrete widget value proposition that does not misrepresent trust state.

2. `vault` (legacy vault encryption path in Rust)
- Status: `defer`
- Rationale: keychain is current v1 secret system; vault may still be useful for future hardened modes.
- Action now: keep code, no deletion; do not expand feature surface in this phase.
- Revisit trigger: explicit product/security decision for post-v1 hardened secret mode.

3. `nmhost` + `webext` (browser bridge)
- Status: `defer`
- Rationale: still potentially relevant to browser-based workflows; not active focus for current launcher/secrets trust core.
- Action now: keep code + menu wiring as-is; no deep cleanup/removal in this slice.
- Revisit trigger: browser-bridge roadmap confirmation or explicit archival decision.

4. Active cleanup scope for this slice
- Status: `execute`
- Scope:
  - warning hygiene only in actively changing runtime surfaces
  - no broad module deletions
  - no transport/trust behavior changes

## Baseline Snapshot (2026-03-12)

- Rust (`cargo check --bin agent-macos`):
  - `generated 77 warnings (32 duplicates)` from mixed active/deferred modules.
- iOS/macOS app builds:
  - compile green in current state; remaining warnings are mostly framework/deferred-area noise.

## Non-goals

- deleting deferred modules
- mass refactors across bridge/proximity/vault/widget subsystems
- semantics changes to trust/launcher runtime

## Exit Criteria for Slice 2

1. Decisions above remain unchanged unless explicitly revised in docs.
2. Cleanup commits stay scoped and reversible.
3. Runtime behavior remains unchanged while noise is reduced in touched files.

