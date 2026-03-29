### THE AUTH FLOW NARRATIVE


Perfect — here are the **plain-English narratives** for each scenario, step by step, with exactly what the user sees and what the system does behind the scenes.

---

# 1) Walk up to your Mac — **Auto-Unlock**

**Setup:** That Mac is set to *Auto-Unlock*.

**Flow**

* You step into range with your phone.
* Your phone quietly signals “I’m near.”
* **Mac:** vault unlocks on its own. Browser autofill works immediately.
* No Face ID prompt at all.

**If you walk away**

* Phone loses proximity and pops: **“Still around?”**

  * Tap **Yes** → keeps the vault open for X minutes.
  * Tap **No** or ignore → vault locks.

**Under the hood**

* Presence flips to *near*. Vault state flips to *unlocked*.
* If presence goes *far*, we start a short grace timer and then lock unless you confirm.

---

# 2) Walk up — **Proximity + First Use Face ID**

**Setup:** That Mac uses *Proximity + Face ID on first use*.

**Flow**

* You step into range; vault stays **locked** until you actually try something.
* First time you request a sensitive operation (e.g., autofill password, decrypt secret):

  * **Phone:** Face ID pops once.
  * After success → vault unlocks and you keep working with **no more prompts**.
* Next actions on that session are frictionless.

**Leaving**

* Same **“Still around?”** prompt as above.

**Under the hood**

* We issue a “session” token on first Face ID, then reuse it until you leave or the session expires.

---

# 3) Walk up — **Proximity + Intent**

**Setup:** That Mac uses *Proximity + Explicit Intent*.

**Flow**

* You step into range; vault remains **locked**.
* **Phone:** shows that Mac with a button **“Unlock”**.

  * Tap → Face ID → vault unlocks.
* Nothing happens until you explicitly choose to unlock.

**Why use this**

* For environments where you pass by your Mac often but don’t always intend to use it.

---

# 4) You’re near but want it locked (home privacy)

**Setup:** Any proximity mode.

**Flow**

* You’re in range but don’t want it open (e.g., someone else could touch your keyboard).
* **Phone:** toggle **“Keep locked”** (or “Pause proximity” for 30m).
* Vault stays **locked**, even though you’re near.

**Under the hood**

* We ignore proximity signals until you unpause or explicitly unlock.

---

# 5) You leave your desk

**Flow**

* Phone detects you’re no longer near.
* **Phone:** “Still around?”

  * **Yes** → keeps open for X minutes (useful if you just walked to the whiteboard).
  * **No** or no response in 60s → vault locks.

**Edge case**

* If your phone dies or loses network → vault locks automatically after the grace window.

---

# 6) Remote, **scoped** approval for a colleague

**Goal:** You’re at home. Your colleague needs *only* your VPN and GitHub push on the office Mac — nothing else.

**Flow**

* Colleague pings you out-of-band (chat/phone).
* **Phone:** open app → **Office Mac** → **Remote Approvals**

  * Choose allowed actions: **vpn.connect** and **github.com/push**
  * Set duration: e.g., **5 minutes** → **Approve**
* **Mac:** those actions work immediately **without Face ID**.
* Any other action (e.g., Facebook, bank) is **blocked** or asks for a separate Face ID if you’ve configured step-up.
* You can **revoke** early from the phone.

**Under the hood**

* Planned: we will mint short-lived, **scoped capability tokens** for only those actions. Everything else stays locked or requires step-up.

---

# 7) Sensitive site requires Face ID (“step-up”)

**Setup:** You toggled **Require Face ID** for, say, *bank.com/transfer*.

**Flow**

* Vault is already unlocked (via proximity or prior Face ID).
* You go to *bank.com* and click **Transfer**.
* **Phone:** Face ID prompt explains why (“Approve bank transfer on Office Mac?”).

  * Success → transfer proceeds.
  * Fail/Cancel → blocked.

**Under the hood**

* We issue a **short-lived token** scoped to *bank.com/transfer* to avoid spammy repeat prompts.

---

# 8) Two Macs with different modes

**Setup:**

* **Home Mac** → *Proximity + First Use*
* **Office Mac** → *Auto-Unlock*

**Flow**

* At office: you sit down → Office vault opens instantly.
* At home: you sit down → first sensitive action triggers **one** Face ID, then you’re smooth for that session.

**On the phone**

* **Devices** lists both Macs, shows status, and lets you change each Mac’s mode independently.

---

# 9) Pause proximity

**Flow**

* You’re in a meeting room next to your Mac but don’t plan to use it.
* **Phone:** tap **Pause proximity (30m)**.
* Vault won’t auto-unlock even if your phone stays near.

**Under the hood**

* We suppress presence→unlock transitions until the pause timer ends or you cancel it.

---

# 10) When networks or BLE get flaky

**What you might see**

* Brief disconnects/reconnects (Mac or phone moves, signal bounces).
* **Phone:** may re-ask “Still around?” if we lose presence for long enough.

**Guarantees**

* If proximity can’t be confirmed and you don’t respond → we **lock**.
* If proximity returns quickly → we restore your previous unlocked state (depending on mode) without nagging you.

---

# 11) Re-pairing / resetting identity

**Flow**

* You reset the server identity (new TLS cert), or you re-install the app.
* **Phone:** scan QR → new pairing.
* Old pair entries are clearly labeled; you can remove them.
* Proximity modes/rules are per Mac; after re-pair they’re re-initialized (or restored if we migrate).

**Result**

* Clean, predictable pairing. No ghost connections.

---

# 12) Logs you can trust

**On the phone**

* **Activity** tab shows:

  * Time, which Mac, site/action, **allowed/denied**, “Face ID used?”
  * Whether it was **proximity**, **remote approval**, or **step-up**.

**Exports**

* You can export recent activity for review.

**Under the hood**

* Today the agent writes NDJSON logs. Next: hash-chained NDJSON for tamper-evidence and a summarized Activity feed on the phone.

---

## TL;DR (how it feels)

* **Everyday use:** Walk up → it works. Walk away → it locks (or asks if you’re still there).
* **Extra safety when you choose:** Flip a toggle for Face ID on the specific sites/actions you care about.
* **Remote control:** From your phone, grant **only** what’s needed, for **only** as long as needed.
* **Transparency:** Your phone shows exactly what happened while you were away.

If any of these should behave differently by default (e.g., always Face ID on approach, or longer/shorter keep-open timers), say the word and I’ll tune the defaults to your taste.



### Explained


Got it. Here’s the **updated, precise plan** that folds in your new requirements: proximity + optional initial Face ID, **scoped** remote approvals (not blanket access), and **auditable logs** visible on the phone. I’ll spell out the flows, the state machine, the message shapes, and how we implement this cleanly on top of the now-stable router.

# What I’m building (clear behaviors)

## A) Proximity modes (per-Mac, user-selectable)

You pick **one** per Mac:

1. **Auto-Unlock**

* Walk near → vault **unlocks immediately** (no Face ID).
* Leave → phone asks “Still around?”; Yes = keep open X min; No/timeout = lock.

2. **Proximity + Face ID on first use**

* Walk near → **don’t unlock yet**.
* First sensitive use on that Mac triggers **a single Face ID**; after that, vault stays open until you leave (same “Still around?” flow applies).
* This reduces false unlocks when you’re just passing by.

3. **Proximity + Explicit Intent**

* Walk near → **stay locked**.
* Phone shows “Tap to unlock” for that Mac; tap → Face ID → unlock.
* This is the most deliberate/quiet mode.

> You can also **Pause Proximity** (15/30/60 min). While paused, being near never unlocks.

## B) Step-up Face ID (per site / per action)

* You’ll see a list of **sites/actions** on the phone with a **“Require Face ID”** toggle.
* If toggled, even when the vault is open, **that specific action requires Face ID right then**.
* Each step-up approval yields a **short-lived, scoped token** (e.g., only “bank.com/transfer” for 5 minutes).

## C) Remote unlock (scoped, not full trust)

* From the phone, pick a **specific Mac** and **exactly which sites/actions** to allow.
* Example: “Unlock Office Mac for 5 min, but only **github.com/push** and **vpn.connect**. No Facebook.”
* Planned: agent will issue **capability tokens per allowed scope** with TTL; everything else stays blocked or needs step-up.
* You can **revoke early** from the phone.

## D) Logs visible on the phone

* Phone (planned) shows an **audit feed**: when/what Mac/which site/action, decision (allowed/denied), whether Face ID was required, and by whom/when.
* Stored locally on phone (rotating), with **export** option. Today the agent keeps NDJSON logs; we will switch to hash-chained NDJSON for tamper-evidence and surface the feed in the app.

## E) Multiple Macs, clean control

* Phone has a **Devices** list (Home Mac, Office Mac, …), each with:

  * Current status: online/near/locked/unlocked
  * Proximity mode selector (Auto-Unlock / Prox+FirstUse / Prox+Intent)
  * Per-Mac “Proximity auto-open” toggle (master switch)
* Rules (step-up) can be **global** or **per-Mac**. Default global; you can override per-Mac if needed.

---

# How the flows actually run (state machine & messages)

## Core agent states

* `presence`: `far | near`
* `vault`: `locked | unlocked`
* `proximity_mode`: enum per Mac (above)
* `auth_cache`: scoped tokens (origin/action/sid, exp)
* `remote_session`: optional (allowed scopes, exp)

### Presence transitions

* **enter** (BLE + link verified): set `near`.
* **leave** (RSSI timeout or link lost): trigger **“Still around?”** on phone.

  * **Yes** → keep open for X min (timer).
  * **No** or **no answer in 60s** → `lock`.

### Unlock decisions

* If `proximity_mode = Auto-Unlock` and `near` and vault locked → **unlock**.
* If `Prox+FirstUse` and `near`:

  * First sensitive operation → send `auth.request(scope=session_unlock)` → Face ID → `auth.ok` → **unlock**.
* If `Prox+Intent` and `near`: require phone tap + Face ID to unlock.

### Step-up decisions

* On each request (credential fill, command), evaluate:

  1. Is there a **remote_session token** covering this scope? → allow.
  2. Is there a **valid scoped token** in `auth_cache` (from recent Face ID)? → allow.
  3. Does a **step-up rule** require Face ID now?

     * `ttl_s=0` → **always** Face ID.
     * `ttl_s>0` → Face ID if no fresh token.
* If Face ID required: send `auth.request{scope, reason, sid, nonce}`; on `auth.proof` → mint token → allow.

### Remote unlock (scoped)

* Phone sends `remote.grant{agent_fp, allowed:[scopes], session_ttl_s}`.
* Agent stores `remote_session` and shows a menu badge “Remote session active”.
* All matching scopes allow without prompts; everything else follows normal step-up rules.
* `remote.revoke` or TTL expiry → session ends.

---

# Message shapes (concise)

* **presence.enter / presence.leave**

  ```json
  { "type": "presence.enter", "sid": "...", "agent_fp": "..." }
  { "type": "presence.leave", "sid": "...", "agent_fp": "..." }
  ```

* **auth.request** (step-up)

  ```json
  {
    "type": "auth.request",
    "sid": "...", "nonce": "...",
    "reason": "Step-up required",
    "scope": { "origin": "bank.com", "action": "transfer" }
  }
  ```

* **auth.proof** → **auth.ok**

  ```json
  { "type": "auth.proof", "sid": "...", "nonce": "...", "proof": "<faceid-attestation>" }
  { "type": "auth.ok", "sid": "...", "scope": {...}, "exp": 173... /* optional/internal: "token": "<scoped-capability>" */ }
  ```

* **remote.grant / remote.revoke**

  ```json
  {
    "type": "remote.grant",
    "agent_fp": "...",
    "sid": "...",
    "allowed": [ { "origin": "github.com", "action": "push", "ttl_s": 300 },
                 { "origin": "vpn", "action": "connect", "ttl_s": 300 } ],
    "session_ttl_s": 300
  }
  { "type": "remote.revoke", "agent_fp": "...", "sid": "..." }
  ```

* **audit log event** (agent → phone, and stored locally)

  ```json
  {
    "type": "audit.event",
    "ts": "...",
    "agent_fp": "...",
    "mac_name": "Office Mac",
    "scope": { "origin": "bank.com", "action": "transfer" },
    "decision": "allow|deny|require_step_up",
    "via": "proximity|remote|step_up_token",
    "face_id_used": true|false,
    "corr_id": "..."
  }
  ```

---

# UX on the phone (what the user sees)

* **Home**

  * “Home Mac — Unlocked (Proximity)” or “Office Mac — Locked”
  * Buttons: **Unlock 5m**, **Lock now**, **Pause proximity (30m)**

* **Devices**

  * List of Macs with status and **Proximity Mode** selector.
  * Master toggle: **Enable proximity unlock**.

* **Sites & Actions**

  * Searchable list, each with **Require Face ID** toggle (per site/action).
  * Optional per-Mac override.

* **Activity (Logs)**

  * Timeline of actions while you were away or anytime.
  * Filters, export.

* **Notifications**

  * “Still around?” → Yes/No
  * “Remote session active (04:59)” → Lock early

---

# Security & correctness (no compromises)

* **mTLS + cert pinning** (already done).
* **Scoped tokens** bound to (scope + sid + agent_fp + expiration). Non-transferable.
* Agent logs in NDJSON today; hash-chained audit log + phone feed are planned.
* **BLE privacy**: rotate ephemeral IDs; RSSI smoothing + hysteresis.
* **Continuation hygiene on iOS**: every await resumes (success/timeout/cancel) → no leaks.
* **Router hygiene** (already in): bind/unbind per NWConnection; GC idle routes; ignore internal no-corr messages.

---

# Implementation plan (short, actionable)

1. **Agent**

   * Add per-Mac **proximity_mode** + timers for “Still around?” and keep-open.
   * Implement **step-up rules** (YAML/JSON) + scoped tokens.
   * Add **remote.grant/revoke** with allowed scopes.
   * Emit **audit.event** on every decision.

2. **TLS**

   * Keep the **strict corr_id router**.
   * Ignore internal no-corr types in the route log.

3. **iOS**

   * UI: Devices (mode + toggles), Sites & Actions (step-up), Activity (logs), Home (controls).
   * Notifications: “Still around?”, Remote session controls.
   * Face ID only on `auth.request`.
   * Continuation safety; timeouts always resume.

4. **Tests (acceptance)**

   * Auto-Unlock / FirstUse / Intent modes.
   * Step-up always-prompt (ttl=0) and ttl-limited reuse.
   * Remote scoped unlock (github+vpn allowed; facebook denied).
   * Leave room: prompt flows; default lock on timeout.
   * Two Macs with different modes.
   * Identity reset: clean re-pair; routing remains solid.

---

# Defaults (you can change anytime)

* **Dev defaults**: Proximity mode = **Auto-Unlock**; auth reuse = **per_session**; step-up rules empty; remote allowed; logs on.
* **Prod defaults**: Proximity mode = **Prox + First Use**; auth reuse = **ttl=300s**; onboarding suggests enabling step-up for banking/sensitive.

---

## TL;DR

* You get exactly what you asked: **user choice everywhere**.
* Proximity removes friction; **Face ID is opt-in per site/action** or can be required once on approach.
* **Remote unlock is scoped** to named actions/sites (no blanket access).
* **Audit logs** make activity transparent when you’re away.
* All of this rides on the **stable corr_id router** we just fixed, so transport stays boring and reliable.

If this matches your intent, I’ll start by:

1. Adding `proximity_mode` logic and timers in the agent.
2. Wiring step-up rules + scoped tokens.
3. Implementing `remote.grant/revoke` and the audit event stream.

Then we’ll do the iOS screens + continuation hygiene and run the acceptance checklist.

---

# Quick project overview (for new teammates)

**What this is:** A local-only trust bridge between Mac and iPhone. Phone presence + Face ID approvals let the Mac perform trusted actions (autofill credentials, unlock vault, run scoped commands). When the phone leaves, trust is revoked. No cloud.

**Components**
- Agent (Rust, macOS): core brain + encrypted vault; pairing, auth/policy, proximity, vault/cred APIs.
- TLS Terminator (Swift, macOS): TLS listener; routes by `corr_id` to exact socket; single transport path.
- iOS app (SwiftUI): pairs via QR, handles Face ID prompts; current MVP dev buttons (ping, vault read/write, cred seed/get, prox intent/pause/resume/status). UI refactor planned.
- Policy (YAML on agent): defaults reuse ttl=300s, proximity prox_first_use; rules per origin/app/action/cmd.
- Dev logs: route log `/tmp/armadillo-route.ndjson`; agent log `/tmp/agent.log` when run with tee.

**Current flows**
- Pairing: QR → pairing.complete → pairing.ack with cert pinning.
- Auth/step-up: first gated op prompts (per policy); scoped grants reuse within TTL; rules can force Face ID per site/action.
- Proximity: modes auto_unlock, prox_first_use, prox_intent; intent/pause/resume/status exposed; grace on disconnect.
- Vault: encrypted KV; dev buttons write/read `sample_test`; miss/locked returns status (not generic error).
- Credentials: cred.write/get/list; origins canonicalized (scheme/host lowercase, default https, strip default ports); dev seed/get works.
- Routing: single path iOS/TLS ↔ agent; corr_id→connection map; route log shows uds_in/route_out with same corr/conn.

**Install story**
- Mac agent + TLS helper (pkg/dmg).
- iOS app (App Store); pair via QR; Face ID for prompts.
- Browser extension for autofill → calls agent for cred.get/list.
- Other actions via shipped helpers (nmhost/CLI) that call agent APIs; no user coding.
- Users toggle step-up per site/action in iOS; agent enforces.

**Remaining work**
- iOS UI refactor (Devices/Approvals/Rules/Activity/Settings), hide dev controls for users.
- Proximity polish in UI (“Still around?” prompt), audit log feed on phone.
- Cleanup warnings/unused modules; tighten framing errors; finalize webext/nmhost flows.

---

# North Star — Symbiauth (phone is the key, Mac/browser is the door)

**Plain English:** Your phone controls trust. When it’s near, chosen things just work; when you leave, the Mac and browser lock. For sensitive sites/actions you decide, the phone asks for one extra Face ID. Everything is local.

**What it is**
- Proximity-aware, phone-controlled security layer for Mac + browser.
- Local vault on the Mac (passwords/tokens/commands); phone decides when it can be used.
- Browser extension can blur/lock selected pages while you’re away and (optionally) clear cookies per site.

**How it feels**
- Arrive: proximity detected. Modes:
  - *Auto-Unlock*: vault usable immediately.
  - *Prox + First Use* (default): first gated action asks Face ID once, reuse for a short TTL.
  - *Prox + Intent*: tap “Use this Mac” on phone; then it works.
- Sensitive sites/actions: per-site/action “Require Face ID” asks again (step-up) only where you want it.
- Leave: short grace → vault locks; marked pages blur instead of breaking the site; optional per-site cookie clear.
- Remote one-off: from phone, grant a specific action (e.g., fill GitHub, run a command) for a short window; logged.

**Components**
- iOS app: devices, proximity mode, per-site toggles (Face ID/blur/cookie clear), remote approvals, activity.
- macOS TLS helper: pinned mTLS ingress, corr_id router.
- Rust agent: vault + policy engine (proximity modes, step-up rules, scoped grants), audit log planned to be hash-chained.
- Chrome extension: autofill, status, blur overlay per site, optional cookie clear on leave.

**Safety model**
- Mutual TLS with certificate pinning; vault is local-only.
- Scoped, short-lived grants bound to site/action/session; least-privilege remote approvals.
- Audit log planned to be hash-chained on the Mac; summarized on phone.

**User control**
- Per-Mac proximity mode; quick actions (Unlock 5m, Pause proximity, Lock now).
- Per-site/action toggles: Require Face ID, Blur when away, Clear cookies on leave.
- Optional manual fallback if phone is unavailable (off by default).

**Name**
- Symbiauth (symbiote + auth): phone and Mac in symbiosis—speed for routine, certainty for sensitive.
