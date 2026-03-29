## Operating Rules (Acknowledged & Logged)
- Treat Armadillo/DreiGlaser as a commercial product with real users; design every change for scale and auditability.
- Never guess or assume; verify names, APIs, and behaviors directly in the repo or by asking you.
- Work cleanly with best practices, factoring code into well-scoped files and refactoring when necessary.
- Reject short-term compromises; prioritize correctness, security, and maintainability over speed.
- Collaborate closely: you run the systems/tests; I provide precise instructions and pause whenever uncertain.

---

## Clarifying Questions Before Next Implementation

1. **Current Priority & Milestone**
   - Which exact objective are we tackling next (e.g., vault migration polish, BLE presence hardening, recovery UX)?  
   - Is there a deadline or demo date driving this milestone that should influence sequencing?
   - Answer:
     - Objective: Ship a stable Phase 2 package with: (a) TOFU hardening (provisioning‑only) and “Kick on revoke” complete and verified, (b) Recovery skeleton usable end‑to‑end on device (generate → start countdown → commit/abort) with clear UX hooks, (c) Observability baselines in NDJSON (periodic vault.status; corr_id propagation across vault.* acks), (d) BLE Presence Phase 1 operating behind flags on both platforms with low‑noise logs.
     - Next two implementation items if any polish remains: 1) Ensure TLSServer emits periodic vault.status and includes corr_id for all vault.* acks; 2) Confirm iOS background‑publisher warnings are fully gone on all flows (connect/reconnect/rekey).
     - Deadline: Optimize for “can demo at any time.” Treat main as demo‑ready: each PR maintains a runnable state per the commands in Architecture‑and‑Progress.md.

2. **Testing & Verification Loop**
   - For macOS + iOS integration tests, do you prefer scripted checklists (e.g., unlock flow, revoke, recovery) per iteration, or ad-hoc guidance per feature?  
   - Are there any environments/devices beyond your primary Mac + iPhone we must keep compatible during development (e.g., Intel Macs, iOS beta versions)?
   - Answer:
     - Use scripted checklists per feature. For each change, include: prerequisites, exact commands/UI taps, expected NDJSON lines, and acceptance criteria. Keep these short and copy‑pastable.
     - Target baseline: Apple Silicon macOS (current stable) + iOS stable on one iPhone. Intel Macs and iOS betas are nice‑to‑have later; do not block current work.
     - Always attach: log snippet proving success (e.g., `pin.provisioning.disabled`) and a one‑line “rollback” note if a flag gates the feature.

3. **Security Review & Compliance**
   - Who will review cryptographic/architecture decisions (just us, or external auditor later), and should we start drafting ADRs per change now?  
   - Do we need to align with specific standards (e.g., SOC2, FIPS readiness) that affect how we log, store secrets, or structure recovery?
   - Answer:
     - Decisions are reviewed by us now; assume external audit later. Start ADRs immediately for crypto, key lifetimes, TOFU policy, and recovery semantics.
     - Place ADRs in `docs/adr/` with filename `ADR-XXXX-title.md` and include: Context, Decision, Alternatives, Consequences, References, and Test/Telemetry proof points.
     - Standards alignment: No formal SOC2/FIPS yet, but we already enforce least‑privilege filesystem perms (0700/0600), minimal PII in logs, and structured logs. Keep recovery phrases ephemeral; never persist mnemonics. These choices are audit‑friendly.

4. **Naming & Branding Constraints**
   - Until rebrand, should new bundles/modules continue using `Armadillo*`, or do you want neutral namespaces to ease renaming later?  
   - Are there user-facing strings we should already keep abstract (e.g., “Vault” vs brand) to simplify future localization/branding?
   - Answer:
     - Continue `Armadillo*` for app/bundle identifiers. Within code, keep product‑agnostic module/file names where practical (e.g., `TLSServer`, `Vault`).
     - Keep UI nouns brand‑neutral (“Vault”, “Server”, “Device”) and avoid company names in strings. This keeps localization and rebranding simpler.

5. **Operational Practices**
   - Do you have an existing incident log or runbook we should integrate with when capturing failures from the NDJSON logs?  
   - Should we start versioning the message schema (e.g., `vCurrent+1`) immediately to protect upcoming browser/extension clients?
   - Answer:
     - Start a light Runbook in `docs/runbook.md`: common failures (e.g., `TOFU_DISABLED`, missing `K_ble`), diagnosis steps, and known fixes. Reference exact NDJSON signatures and commands to tail logs.
     - Begin schema versioning now in `docs/message_schema.md`: add `schema_version: 1` note and a policy for additive changes and deprecations. Prefer additive fields; avoid breaking renames; gate behavior with flags.

6. **Recovery & Threat Modeling Follow-ups**
   - For the cancel-first recovery flow, do we already have Push infrastructure mocked or is it still conceptual?  
   - Are there open threat items (from the table) you want prioritized now—e.g., memory scrubbing enhancements, supply-chain hardening, or BLE anti-relay?
   - Answer:
     - Push is conceptual; not required for current skeleton. The agent implements countdown + token; iOS surfaces the UX. Future push can integrate at “rekey.started” to notify.
     - Prioritize: (1) Memory hygiene for sensitive keys in agent (zeroize buffers post‑use where feasible), (2) Supply chain hygiene (pin crate/swift package versions; keep SBOM), (3) BLE anti‑relay is Phase‑2+; for now, presence is a low‑assurance signal behind flags.

7. **Documentation & Knowledge Transfer**
   - Would you like me to maintain an always-up-to-date “handoff brief” (1–2 pages) that consolidates Architecture-and-Progress + STATE_AND_NEXT_STEPS for quick sharing in new chats?  
   - Should we adopt an ADR template for every major decision starting now, and if so, where should those live (`docs/adr/`?)?
   - Answer:
     - Yes. Maintain `docs/Handoff-Brief.md` as a compact 1–2 page executive overview with links to the detailed docs. Update when major flows change.
     - Yes to ADRs; location `docs/adr/`. Seed with ADRs for: TOFU hardening, Kick‑on‑revoke, Vault v2→v3 migration strategy, BLE presence trust level, and NDJSON telemetry policy.

8. **Tooling & Automation**
   - Are we cleared to introduce lightweight automation (e.g., Makefile targets, scripts) to reduce manual setup, or do you prefer keeping the current manual flow until after the next milestone?  
   - Any constraints on third-party crates/packages (licensing, audit requirements) before we add dependencies to Rust/Swift projects?
   - Answer:
     - Approved: add a minimal `Makefile` with phony targets: `make agent`, `make tls`, `make run-tls`, `make logs`, `make clean-artifacts`. No temporary files outside `build`/`target`. All commands must be idempotent.
     - Dependencies: prefer permissive licenses (MIT/Apache2/BSD). Avoid copyleft for embedded/SDK code. Before adding crypto libs, justify necessity and confirm active maintenance.

9. **Future Platform Targets**
   - When planning current abstractions, should we bake in Linux/Windows agent considerations now, or is macOS-only acceptable until v2?  
   - Likewise for browser extension: do we assume Chromium-first, or must we keep Safari/Firefox parity in mind immediately?
   - Answer:
     - macOS‑only is acceptable through v2. Keep portability in mind: isolate macOS‑specific bits (sleep notifications, Keychain) behind traits/protocols so Linux/Windows ports can swap implementations later.
     - Extension path: Chromium‑first (Manifest v3) with a Native Messaging host that talks to the local TLS/agent over UDS/TCP loopback. Keep APIs generic so Firefox can be added with minimal shims.

10. **Metrics & Observability**
    - Do you want additional telemetry (beyond NDJSON + tracing) centralized somewhere soon, or keep everything local until we define a privacy stance?  
    - Any specific metrics/dashboards you want me to design (unlock latency, BLE presence stability, recovery attempts) before we proceed?
   - Answer:
     - Keep telemetry local until privacy policy is formalized. NDJSON is our ground truth; avoid network export.
     - Add a local “operational health” view (simple script or small UI) reading NDJSON to show: unlock latency distribution, presence ratio per hour, rekey outcomes, and error tallies by code. This serves as an operator dashboard without exfiltration.

Please review or annotate these questions; once aligned, I can dive into the next implementation with full context and zero assumptions.

## Current Understanding Snapshot

- Objective: Deliver a commercial‑grade proximity vault where the iPhone’s Secure Enclave is the root of trust; macOS runs a TLS terminator and Rust agent; transport stays local (BLE presence → Bonjour → mutual TLS → UDS IPC → vault).
- Status: Implemented and behind flags where appropriate: vault hardening (0700/0600), v2→v3 migration to K_wrap, recovery skeleton (BIP‑39 + rekey start/commit/abort + countdown), TOFU hardening (provisioning‑only), per‑device revoke and server reset with live menu updates, optional “Kick on revoke,” BLE presence Phase 1 (rotating UUID) gated, iOS Settings with dev toggles, background thread publishing warnings resolved, and NDJSON observability with periodic vault.status (to be kept on).
- Security posture: BLE is presence‑only (low assurance) and gated; mTLS + ECDH derive per‑session keys; vault AES‑GCM sealed under K_wrap; TOFU is limited to provisioning window only; revoke actively terminates connections when enabled; recovery minimizes mnemonic exposure (no persistence, clipboard expiry).
- Component boundaries: iOS owns user auth + key derivation + BLE advertising; macOS TLS app owns identity, enrollment, pin lifecycle, BLE scanning, NDJSON, and UDS bridge; Rust agent owns vault keys, pairing artifacts, derivations, and recovery flows.
- Roadmap: Phase 1 (pairing/mTLS) → Phase 2 (disk vault, recovery UX, TOFU hardening, revoke‑kick) → Phase 3 (multi‑device, cache/enclave hardening, Linux/Windows prep) → Phase 4 (browser extension + transparency logging). Current focus: polish Phase 2 and prepare ADRs.
- Practices: Structured NDJSON with corr_id; principle of least privilege on filesystem; feature flags for risky/optional features; documented message contracts; ADRs for major decisions; copy‑pastable checklists per feature; “no guessing” rule is enforced via clarifications and tests.