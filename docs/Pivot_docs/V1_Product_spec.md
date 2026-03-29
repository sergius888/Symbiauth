> ⚠️ **PARTIALLY SUPERSEDED** — The trust rules (§3), iPhone UX TTL picker (§1.1), and Mac UX
> state descriptions (§1.2) are outdated. For the canonical trust spec, see
> [`v1_product_spec_states.md`](docs/Pivot_docs/v1_product_spec_states.md).
>
> **Still valid here:** Feature descriptions (launchers, secret injection, secrets volume,
> auto-cleanup), feasibility check, crypto-native use cases, and the "out of scope" list.

---

# SymbiAuth v1 Product Spec (March 2026)

## 0) The promise (v1)

SymbiAuth v1 gives the user a **short “trusted window”** on a Mac, authorized by **Face ID on iPhone**, during which the Mac can safely do sensitive things (use secrets). When the window ends, SymbiAuth **cleans up automatically** so no secrets are left behind.

**Design philosophy:** *short sessions, explicit start, predictable end, fail closed.*

---

## 1) What the user experiences (end-to-end)

### 1.1 iPhone UX (v1)

**Home screen:**

* Button: **Start Session**
* TTL picker: **2 min / 5 min / 10 min**
* Shows the currently paired Mac name (one active Mac for v1)
* Status: `Idle` or `Session Active (foreground-only)`

**Session start:**

1. User taps **Start Session**
2. Face ID prompt appears
3. If success:

   * iPhone begins BLE participation (foreground only)
   * iPhone shows a big visible “Session Active” state + countdown

**During session:**

* App must remain **foreground** to maintain session capability.
* If user backgrounds/locks → session capability stops immediately.
* (Mac will expire trust based on TTL; no background magic expected.)

**End session:**

* Button: **End Session**
* Immediately stops BLE participation.

> v1 deliberately avoids lock-screen widgets / background flow. Foreground-only is the product safety boundary.

---

### 1.2 Mac UX (v1)

Mac has a **menubar app** with a simple state machine:

**Locked (default)**

* “Locked — no active trust”
* Shows paired phone name (optional)
* Button: “Start Trust Session” (or “Waiting for iPhone session” depending on design)

**Trusted**

* Shows countdown: “Trusted: 04:32”
* Buttons:

  * **Run Launcher…**
  * **End Session Now**
* Shows “Resources active” summary:

  * “Mounted: Secrets Volume ✓/✗”
  * “Running processes: N”

**When trust ends (expiry or manual end):**

* Menubar returns to Locked
* Cleanup runs automatically (details below)

---

## 2) What “Trusted” allows the Mac to do (features)

### Feature A: Preconfigured Launchers (v1)

A “Launcher” is a stored action:

* name (e.g., “Run Freqtrade”)
* command + args (path, args)
* secret bindings (which secrets to inject)
* working directory (optional)

**User flow:**

* In menubar, click Launcher → Run
* If currently Trusted: it executes immediately
* If Locked: it refuses and prompts user to start a session on phone

**Important constraint (security):**

* Secrets are injected **only at process spawn** (env vars or temp file), never globally.

---

### Feature B: Inject secrets into launched processes (v1)

Two supported injection modes:

**Mode B1: Env vars (default, simplest)**

* When starting a process, SymbiAuth sets env vars like:

  * `KORE_API_KEY=...`
  * `DB_PASS=...`
* Only the child process gets them.

Pros: simple, fast.
Cons: env vars can be visible to same-user processes depending on OS/tools (risk level varies).

**Mode B2: Ephemeral files (optional v1.1 if needed)**

* Write secrets to a temp file with tight perms (0600)
* Pass file path as argument
* Delete file on revoke/expiry

Pros: less env leakage.
Cons: more implementation complexity.

**v1 recommendation:** start with **B1** and add B2 later if required.

---

### Feature C: Mount / unmount a secrets volume (v1)

This is for “configs/dotfiles/ssh keys” style bundles.

**v1 feasible approach:**

* SymbiAuth mounts an encrypted disk image when trust starts (or when first needed).
* On revoke/expiry it unmounts.

**User controls:**

* Toggle: “Mount secrets volume during session” (on Mac)
* Or “Mount on demand” (when a launcher needs it)

**Important clarity:**

* Mounting is Mac-local. iPhone does not stream secrets.
* The secrets live encrypted on Mac storage (or removable drive) and are released only during Trust.

---

### Feature D: Auto-cleanup (v1)

Cleanup happens on:

* TTL expiry
* Manual “End Session”
* Mac sleep/lid close (optional but recommended)

Cleanup actions:

1. **Kill tracked processes** that were launched during session
2. **Unmount secrets volume** (if mounted)
3. Clear SymbiAuth temporary artifacts (temp files if used)
4. Clear “trusted” state in UI + agent

**We do NOT promise** to clean up arbitrary apps the user opened manually (e.g., Safari tabs). Only what SymbiAuth started / mounted.

---

## 3) Trust rules (the logical core)

### 3.1 How trust is established (v1)

* iPhone must be **foreground** and user must pass **Face ID**
* Mac connects over BLE GATT and performs **challenge–response** proof
* Mac sets `trust_until = now + TTL`

### 3.2 What ends trust (v1)

* When `now > trust_until` → revoke + cleanup
* Manual “End Session” → revoke + cleanup
* Mac sleep/lid close → revoke + cleanup (recommended)

### 3.3 Foreground-only safety guarantee

* When the iPhone app backgrounds/locks:

  * iPhone stops participating immediately
  * Mac will not get further proofs
  * trust ends by TTL (predictable, safe)

We do not claim “instant revoke when phone leaves room.” TTL is the contract.

---

## 4) Where secrets live (and what we promise)

**v1 rule:** secrets do not transit the network during use.

* Secrets are stored on the Mac in a secure form (Keychain / encrypted volume).
* Trust session authorizes their release **locally** for a limited time.

This fits the hotdesk/shared-Mac use case while avoiding cloud.

---

## 5) What is explicitly out of scope (v1)

* Background/pocket proximity unlock
* Always-on presence detection
* Automatic “leave room → lock instantly”
* Remote approvals over cloud
* Full password-manager replacement UX

---

## 6) Feasibility check (so we don’t promise lies)

### We can reliably do in v1

✅ Foreground Face ID gating on iPhone
✅ BLE GATT challenge–response while foreground
✅ TTL trust on Mac + cleanup
✅ Launchers + env var injection
✅ Mount/unmount encrypted volume on Mac

### We do NOT base v1 on

❌ iPhone advertising in background/lock
❌ CoreLocation wakeups as reliability mechanism
❌ iOS background BLE guarantees

---

## 7) The MVP deliverable

A demo that works every time:

1. User starts session on iPhone (Face ID)
2. Mac becomes Trusted within ~10 seconds
3. User runs a launcher that needs secrets
4. After TTL, SymbiAuth kills the launcher + unmounts secrets + returns to Locked

If this is achieved, the pivot succeeded.

---

BONUS Use case:
Here are a few **realistic crypto-native use cases** that fit v1 perfectly (foreground trust sessions + TTL + auto-cleanup) and solve problems people actually have.

## 1) Safe “signing session” for hot wallets (the one people will instantly get)

**Problem:** Traders/devs sometimes keep a hot wallet key loaded in env vars / config, or leave browser wallets unlocked. That’s a disaster on shared machines or when screen-sharing.

**SymbiAuth v1 solution:**

* Launcher: “Enable Signing (5 min)”
* During Trusted window:

  * mount an encrypted “SigningVolume” containing a hot-wallet key / config OR decrypt from Keychain into env var
  * start the signing process (e.g., a bot, script, or local signer)
* On expiry:

  * kill signer process
  * unmount volume
  * wipe temp files

**Why they want it:** it turns “I need to sign 10 txs fast” into a **controlled, timed signing session** that disappears automatically.

**Examples:**

* running a market maker / rebalance script that needs a private key
* short burst of onchain admin actions (pause contract, set params, migrate)
* one-off “rescue funds / rotate key” operations

## 2) “RPC + API keys burst” for infra / MEV / data tools

**Problem:** Many crypto workflows rely on sensitive keys:

* Alchemy/Infura/QuickNode RPC keys
* private endpoints, archive node creds
* CEX API keys (Binance/Bybit/OKX), sometimes with withdrawal rights (shouldn’t!)

These keys often get stuffed into `.env` files and accidentally leaked to GitHub, shell history, logs, or left on disk.

**SymbiAuth v1 solution:**

* Launchers that start:

  * local indexer
  * MEV searcher
  * liquidation bot
  * onchain analytics script
* Secrets injected **only at spawn** (env vars), for TTL.
* Auto-cleanup kills processes + clears session state.

**Why they want it:** prevents `.env` sprawl and accidental commits while staying fast.

## 3) “Temporary SSH agent + key” for production boxes (very real)

**Problem:** Crypto teams live in terminals:

* SSH into validators, sequencers, nodes, relayers
* keys get left in `~/.ssh`, ssh-agent stays loaded forever

**SymbiAuth v1 solution:**

* Launcher: “SSH to Validator (10 min)”
* On trust start:

  * mount volume containing SSH key OR load key into ssh-agent from encrypted storage
* Run ssh command
* On expiry:

  * remove key from agent (`ssh-add -D` or targeted)
  * kill related sessions (optional)
  * unmount

**Why they want it:** massively reduces “I forgot my key loaded” risk.

## 4) “Screen-share safe mode” for founders/traders (simple but sticky)

**Problem:** Crypto people are constantly screen-sharing—calls, investors, OTC, strategy, audits. They accidentally show:

* API keys
* wallet addresses/seed fragments
* internal dashboards

**SymbiAuth v1 solution:**

* Launcher: “Demo/Screenshare Mode (10 min)”
* During trust:

  * apply a macOS profile: hide desktop icons, disable notifications, close certain apps, open clean browser profile
* On expiry:

  * revert everything automatically

**Why they want it:** it prevents embarrassing/severe leaks with zero discipline required.

---

## The cleanest “crypto pitch” line (v1)

**“SymbiAuth gives you a timed ‘signing session’ on your Mac — Face ID starts it, TTL ends it, and it cleans up automatically. No keys left behind, no .env leaks, no ssh-agent lingering.”**

If you want, I can add a short section to your `V1_PRODUCT_SPEC.md` titled **“Crypto-native use cases”** with 2–3 of the above and a concrete launcher example for each (command + secrets).
