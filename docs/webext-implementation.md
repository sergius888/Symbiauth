# Armadillo Browser Extension – Implementation Handoff

This document is the minimal context you must read before continuing work on the Armadillo Chrome extension + native messaging bridge. It explains what exists today, how the pieces talk to each other, where the code lives, and which sharp edges still remain. Treat it as the source of truth when picking up the project in a fresh session.

---

## High-Level Workflow

1. **User launches Armadillo TLS app** (macOS menu bar app in `apps/tls-terminator-macos`). On launch it:
   - Bundles the Rust native messaging (NM) host into the app bundle.
   - Installs/repairs the NM manifest under `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.armadillo.nmhost.json` using the dev extension ID.
   - Offers a “Remove Browser Bridge” action for cleanup.

2. **Chrome extension (MV3) starts** (`packages/webext/public`). The background service worker:
   - Connects to `com.armadillo.nmhost`.
   - Performs the `nm.hello` handshake (JSON + LE32 framing) and keeps the port alive with auto-reconnect.
   - Routes requests from content scripts (`ui.fill`) to the native host (`cred.list` / `cred.get`) and resolves promises using `corr_id`.

3. **Rust NM host (`apps/nmhost-macos`)**:
   - Reads/writes NM messages over stdio (4-byte LE length + JSON).
   - On `cred.*` messages it forwards the JSON to the Armadillo agent over the UDS socket (`~/.armadillo/a.sock`), preserving `corr_id`.
   - Returns agent responses, or surfaces structured errors (`AGENT_UNAVAILABLE`, `BAD_JSON`, etc.).

4. **Rust agent (`apps/agent-macos`)**:
   - Validates the origin (eTLD+1), session status, presence hint, and vault state before every `cred.list`/`cred.get`.
   - Pulls credentials from the local vault (`cred/<etld1>/<username>` entries) and returns either account metadata or the password (base64-encoded).
   - Emits NDJSON telemetry with reason codes for policy denials.

5. **Content script (`packages/webext/public/content.js`)**:
   - Watches the DOM (MutationObserver + SPA history hooks + shadow-root traversal + same-origin iframes) to find username/password fields.
   - Renders a single “Fill with Armadillo” overlay button anchored to whichever field is focused (uses requestAnimationFrame tracking to stay glued while scrolling).
   - On click/hotkey (`Cmd/Ctrl + .`) it:
     1. Calls `ui.fill` with `mode:"username"` ⇒ background ⇒ native host ⇒ agent ⇒ list of accounts.
     2. Prompts the user (simple `prompt` for now), fills the username, and remembers the selection per origin in `sessionStorage`.
     3. Calls `ui.fill` with `mode:"password"` using the remembered username ⇒ agent returns the password ⇒ script fills the password field.
   - Guards against duplicate injection via `data-armadillo-processed`.
   - Keeps lightweight toast/log messaging (`[arm.content] filled username …`) for debugging.

---

## Repository Layout (extension path only)

```
packages/webext/
├── package.json
│   └─ npm scripts (build is a no-op echo; plain JS assets)
├── dev/
│   └── dev_key.pem (DEV ONLY, .gitignored – stable extension ID seed)
├── public/
│   ├── manifest.json         # MV3 manifest (see below)
│   ├── background.js         # Service worker (handshake + cred RPCs + hotkey)
│   └── content.js            # Overlay injector & fill logic
└── src/ (legacy TS sources; not used in dev build)
```

### Key manifest fields

```json
{
  "manifest_version": 3,
  "name": "Armadillo (Dev)",
  "key": "<base64 dev public key>",
  "permissions": ["nativeMessaging", "scripting", "tabs"],
  "host_permissions": [
    "https://*/*",
    "http://*/*",
    "https://accounts.google.com/*",
    "https://auth0.openai.com/*",
    "https://accounts.youtube.com/*",
    "https://ssl.gstatic.com/*"
  ],
  "content_scripts": [{
    "matches": ["https://*/*", "http://*/*"],
    "js": ["content.js"],
    "run_at": "document_idle",
    "all_frames": true,
    "match_origin_as_fallback": true
  }],
  "background": { "service_worker": "background.js" },
  "commands": {
    "armadillo-fill": {
      "suggested_key": { "default": "Ctrl+Period", "mac": "Command+Period" }
    }
  }
}
```

---

## File Roles (practical notes)

| File | Purpose | Important Details |
| --- | --- | --- |
| `packages/webext/public/manifest.json` | Declares permissions, hosts, hotkey. | Stable `key` ensures repeatable dev ID. `match_origin_as_fallback` helps with about:blank iframes, but sandboxed foreign frames still require explicit hosts + granted access. |
| `packages/webext/public/background.js` | MV3 service worker. | Handles NM handshake, tracks pending `corr_id` promises, routes `ui.fill` requests, logs host errors (`type:"error"`). |
| `packages/webext/public/content.js` | Overlay injector + fill logic. | MutationObserver + shadow DOM recursion, requestAnimationFrame overlay tracking, pointerdown suppression to keep focus, sessionStorage for selected username, `chrome.runtime.sendMessage` to background. |
| `apps/nmhost-macos/src/main.rs` | Native messaging host binary. | Implements LE32 framing, `nm.hello`, forwards `cred.*` to the agent, logs structured events, supports `--stdio-test` flag. |
| `apps/agent-macos/src/bridge.rs` | UDS server handling NM requests. | `cred.list`/`cred.get` handlers enforce proximity + vault + origin gates, reply with `cred.accounts`/`cred.secret` or structured errors. |
| `apps/agent-macos/src/vault.rs` | Vault extensions. | `list_credentials` and `get_credential` read entries keyed by `cred/<etld1>/<username>`. |
| `apps/tls-terminator-macos/ArmadilloTLS/AppDelegate.swift` | Installer hook. | Installs/removes NM manifest, ensures host binary permissions, reads extension ID from env or `~/.armadillo/dev_extension_id.txt`. |

---

## Current Behavior

1. **Extension loads** → background connects to native host → logs `[armadillo] native host ready`.
2. **User focuses a username/password field** → overlay button appears near the field (and stays glued while scrolling).
3. **Click button or use hotkey**:
   - Username step: background calls `cred.list`, shows prompt if multiple accounts, fills value, remembers selection in `sessionStorage["arm.selUser@<origin>"]`.
   - Password step: background calls `cred.get` with remembered username, decodes `password_b64`, fills the password field.
4. **Agent enforces** session/presence/vault/origin gates. If any gate fails, devtools shows `UNLOCK_REQUIRED`, `PRESENCE_REQUIRED`, etc., and no fill occurs.

---

## Known Gaps / TODOs

1. **Gmail iframe injection** – Despite host permissions + `all_frames`, some Gmail login frames still don’t load `content.js` (likely due to sandbox restrictions). Need to inspect their `sandbox` attributes and decide on a fallback (e.g., inject UI in parent frame + message the iframe).
2. **Overlay blur edge cases** – Most sites now keep the button visible during clicks, but verify exotic UIs (e.g., ones that forcibly blur on pointer events). If needed, expand the focus guard to wrapper elements or introduce an inline fallback icon.
3. **Agent policy hardening** – Ensure fills are denied on `http:` origins or mixed-context frames. Only allow curated cross-origin auth frames (e.g., Gmail/Auth0) once the frame origin is verified.
4. **Host-permission onboarding** – MV3 requires explicit user consent per host. For packaged builds we need a user-facing “Grant access for Gmail/Auth0” flow or docs.
5. **UI polish** – Current username chooser uses `prompt()`. Replace with a proper chooser (modal or mini-overlay) when reliability is confirmed.
6. **Error surfaced in background** – `[armadillo] native host error ...` now logs whenever the host returns `{ type:"error" }`. Investigate root causes (bad JSON, policy violations) before shipping.

---

## Testing Checklist

1. **Basic handshake** – Load extension, open service worker console, see `[armadillo] native host ready`.
2. **Reddit / Dropbox modal** – Overlay appears in modal, stays glued while scrolling, clicking fills username → password sequentially.
3. **ChatGPT Auth0 popup** – Overlay shows immediately on auto-focused fields, hotkey works.
4. **Gmail (accounts.google.com)** – After granting site access, overlay should appear in the login iframe (still pending fix).
5. **Error paths** – Lock vault / turn off phone → background logs `UNLOCK_REQUIRED` / `PRESENCE_REQUIRED` and no fill occurs.

---

## Final Notes for Future Work

- **Never trust the extension** – All gating stays in the agent. The extension only presents UI.
- **Keep NM manifest user-scoped** – Chrome NM hosts should never be system-wide.
- **Code signing** – Native host + app must be signed/notarized before distribution.
- **Telemetry** – NDJSON logging exists; add rate-limited counters to debug fill failures without leaking secrets.
- **Documentation** – Update user-facing docs with “Grant site access” instructions, dev key generation steps, and acceptance test flow.

Read this doc before resuming work. If you pick up a fresh chat, paste this file so you (and the assistant) start with the correct context.

---

## Next Steps to Finish the MVP (Finalized Checklist)

1. **Gmail/Auth0 Coverage (must-have)**
   - Keep the existing `content_scripts` injection but add a background `chrome.webNavigation` listener that calls `chrome.scripting.executeScript` for target frames (e.g., `accounts.google.com/*`, `auth0.*/*`) once host access is granted.
   - Inspect Gmail/Auth0 iframe `sandbox` attributes; document any remaining blockers and required `site access` steps for MV3.
   - ✅ Done when overlay renders and fills inside Gmail + ChatGPT/Auth0 login flows without manual reloads after granting site access (note: Gmail’s account chooser step does not expose inputs, so seeing `[arm.bg] injected … frameId: 0` there is expected).

2. **Overlay Stability Polish**
   - Ensure pointer/touch handlers (`preventDefault` + `stopPropagation`) are applied on the overlay root and button so focus is never lost mid-click.
   - Keep rAF-based positioning and add a small blur-hide delay; optionally use IntersectionObserver to hide/show when the field leaves/enters the viewport.
   - ✅ Done when overlays stay glued during scroll/zoom across Reddit, Dropbox modals, and Gmail.

3. **Agent Fill Policy Hardening**
   - Enforce HTTPS-only fills; reject mixed-content frames.
   - Allow fills only for the top-frame origin or vetted cross-origin auth frames (`accounts.google.com`, `auth0.*`) when access is granted.
   - Introduce allow/deny knobs (env/config) for testing and add NDJSON reason codes such as `ORIGIN_DENIED`, `MIXED_CONTENT`.
   - ✅ Done when hostile pages produce explicit denials and logs show the reason codes.

4. **Face ID Gating**
   - iOS: prompt via LocalAuthentication, send `auth.proof` (nonce + signature), derive `k_session`.
   - Agent: verify proof, set `auth_ok_until = now + TTL`, gate `vault.open` / `cred.get` / rekey on freshness.
   - ✅ Done when first fill requires Face ID, subsequent fills within TTL succeed silently, and expired sessions return `FACEID_REQUIRED`.

5. **Onboarding & Host-Permission UX**
   - Add in-extension messaging to guide users through MV3 “Grant site access” for Gmail/Auth0 (deep link to `chrome://extensions`).
   - Update docs with a concise walkthrough and troubleshooting tips (e.g., verifying `[arm.content] injected …` logs).
   - ✅ Done when a new user can enable site access in <30 seconds with our UI/docs.

6. **UI Improvements**
   - Replace the `prompt()` chooser with an inline account selector (list overlay, default selection).
   - Add a small toast/indicator for denial reasons (vault locked, presence required).
   - ✅ Done when account selection uses our UI and users see readable denial feedback.

7. **Packaging & Signing**
   - Sign + notarize the macOS menu-bar app and `armadillo-nmhost`.
   - Make the installer repair script idempotent (verifies manifest path, fixes permissions/quarantine, logs success/failure).
   - ✅ Done when a fresh Mac install works without manual `xattr` or `chmod`.

8. **Telemetry & Error Surfacing**
   - Keep NDJSON logging; add rate-limited counters for `fill_denied_origin`, `unlock_required`, `presence_required`, `faceid_required`, `gmail_injected`, etc.
   - ✅ Done when a 15-minute run shows stable metrics without leaking PII.

9. **Open Security Checks**
   - Block fills on “change password” / “register” pages unless explicitly allowed (denylist or regex).
   - Maintain the extension as untrusted UI: no secrets unless all gates pass.
   - ✅ Done when `/reset-password` and similar paths consistently return denials with logged reason codes.

Follow items 1–4 first (coverage, stability, policy, Face ID) to reach a demo-ready MVP; the remaining steps round out onboarding, packaging, telemetry, and security polish.