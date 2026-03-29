##### Brainstorming:



Good. Now you should stop thinking “what can the protocol do?” and start thinking:

**“What painful, high-frequency, high-anxiety action becomes one tap safer and faster because trust is granted?”**

That’s the product.

The Mac should not “perform trust.”
The Mac should perform **valuable actions gated by trust**.

## The core product thesis

SymbiAuth is not a generic proximity app.
It is a **trusted-action layer for sensitive work on a Mac**.

The best features are the ones that:

* happen often
* involve secrets or risky state
* are annoying to do safely today
* become dramatically easier with a short trusted window

---

# The killer features

## 1) Trusted Launchers

This is the strongest v1 feature.

### What happens when trust is granted

The Mac unlocks a list of preconfigured launchers like:

* “Run trading bot”
* “Open production SSH session”
* “Start deploy tool”
* “Mount research workspace”
* “Open signer session”

Each launcher can:

* inject specific secrets
* set env vars
* mount files/volumes
* run commands
* track spawned processes
* auto-clean up on revoke

### Why this matters

People do not buy “BLE trust.”
They buy:

> “I press one thing and my dangerous workflow starts safely, then disappears automatically.”

That is real value.

---

## 2) Secure Secret Injection

This is probably the most universally useful feature.

### What the Mac does on trust grant

* resolves secret references
* injects only the secrets needed for that action
* injects them only into the launched process
* kills/unsets/cleans on revoke

### Why it’s valuable

This kills several real pains:

* `.env` sprawl
* secrets in shell history
* secrets committed to git
* copied API keys living in clipboard
* long-lived SSH agent state
* shared-machine residue

### PMF angle

For devs, traders, crypto operators, infra people:
**“Use secrets without storing them in the project or leaving them behind.”**

That is extremely legible.

---

## 3) Session-Bound Secrets Volume

This is the second strongest feature after launchers.

### What the Mac does on trust grant

* mounts an encrypted volume or decrypted workspace
* exposes configs, certs, keys, notebooks, scripts
* unmounts it on revoke

### Best use cases

* dotfiles / private configs
* SSH material
* signing configs
* customer creds / support creds
* strategy configs
* “personal layer” on a shared/hotdesk Mac

### PMF angle

This is very attractive for:

* shared desks
* office Macs
* people who don’t want to fully log into their whole life

---

## 4) Session Cleanup / Auto-Revoke

This is not a side feature. It is part of the product promise.

### What the Mac does on revoke

* kills tracked processes
* unmounts secret volume
* deletes temp files
* clears in-memory session state
* optionally clears clipboard / removes ssh-agent identities / closes specific apps

### Why it matters

Without this, the app is just “temporary unlock.”
With this, it becomes:

> “I can do dangerous work fast, and I know the machine won’t stay contaminated.”

That is a strong emotional value prop.

---

# Best concrete user-facing actions

If I were shaping v1 for PMF, I would make the Mac support these **five action types**:

## A. Run a Trusted Command

Examples:

* run bot
* run deploy
* run migration
* run backup
* run db query tool

This is the default primitive.

---

## B. Open a Trusted Shell / Terminal Session

Examples:

* terminal opens with env vars / mounted secrets available
* ends cleanly on revoke

This is huge because many users live in terminal.

---

## C. Start a Trusted SSH Session

Examples:

* add SSH identity temporarily
* open the target connection
* remove identity and close session on revoke

This is very compelling.

---

## D. Mount Trusted Workspace

Examples:

* mount encrypted volume
* reveal files/configs only during trust

This is the “virtual flash drive” mental model.

---

## E. Open Trusted Browser / App Context

Examples:

* launch a browser profile or app with a session-bound config
* on revoke, close it / clean profile

This is probably not v1 core, but very promising later for:

* admin dashboards
* exchange accounts
* support portals

---

# The best initial verticals

You asked for PMF thinking. Here’s the truth:

## Vertical 1: Crypto / Trading / Infra operators

This is the most natural early wedge.

### Killer actions

* run a bot with exchange keys
* start a signer session
* open an SSH session to infra
* mount a secrets bundle for trading configs

### Why this works

These users:

* understand risk
* already suffer from ugly unsafe workflows
* tolerate some friction if safety is real
* appreciate “session-bound trust”

This is your strongest early audience.

---

## Vertical 2: Devs with shared or semi-shared Macs

### Killer actions

* run scripts with secrets
* start local tools without `.env`
* access private configs temporarily

This is broader but less emotionally urgent than crypto/trading.

---

## Vertical 3: Consultants / freelancers / hotdesk workers

### Killer actions

* mount personal workspace
* open client credentials safely
* leave no residue

Promising, but probably less sharp than crypto/trading.

---

# What not to build first

Do not make v1 a broad “password manager competitor.” That’s weak and crowded.

Avoid:

* generic autofill as the main story
* too much emphasis on proximity magic
* too many modes and settings
* too much UI polish before the actions are killer

---

# My recommendation for v1 product packaging

## Core product statement

**“SymbiAuth gives you a trusted window on your Mac to run sensitive actions, use secrets, and automatically clean everything up when the session ends.”**

## The 3 flagship features to ship first

1. **Trusted Launchers**
2. **Secret Injection**
3. **Auto-Cleanup**

## The best optional 4th feature

4. **Trusted Secrets Volume**

That is enough to be meaningful.

---

# The single best concrete v1 demo

If I had to demo this to someone in 30 seconds:

1. On iPhone: Face ID → Start Session
2. On Mac menubar: “Trusted 5:00”
3. Click launcher: **Run Freqtrade / SSH Prod / Start Signer**
4. Bot/session starts with secrets
5. Trust ends → process dies, volume unmounts, state clears

That demo sells the product.

---

# If I were ruthless about PMF

I would position it as:

## Option A — Crypto/trader angle

**“A timed signing and secrets session for your Mac.”**

## Option B — DevSecOps angle

**“Run sensitive developer workflows without leaving secrets behind.”**

Option A is sharper. Option B is broader.

---

# The concrete Mac actions I would implement first

In order:

1. **Run launcher with env-injected secrets**
2. **Add/remove SSH key for session**
3. **Mount/unmount encrypted secrets volume**
4. **Kill tracked session processes on revoke**
5. **Clipboard/temp cleanup**
6. Later: browser/app guarded contexts

---

The real value is not the trust itself.
The real value is:

> **session-bound access to dangerous capabilities, with automatic cleanup.**

If you want, next I can turn this into a **v1 feature priority list** with:

* Must have
* Nice to have
* Don’t build yet

so you can stop feature wandering.





### Potential Narrative:
Think of it like this:

SymbiAuth lets your Mac borrow trust from your iPhone for a short time.

You open the app on your phone, scan your face, and that tells your Mac:
**“It’s really me. For now, allow the sensitive stuff.”**

Then on the Mac you can press saved actions, like:

* start a trading bot
* open an SSH session
* mount a private folder
* run a script that needs API keys

The important part is that the app gives those tools access to secrets **only while trust is active**.

So instead of:

* copying API keys around
* leaving private files mounted
* forgetting an SSH key loaded
* leaving a dangerous process running on a shared Mac

you get this:

1. Start trust from your phone
2. Do the sensitive action on your Mac
3. When trust ends, the app cleans up automatically

That cleanup can mean:

* stopping the process
* removing temporary access
* unmounting the private folder
* deleting temporary secret files

So the value is not “Bluetooth” or “Face ID.”

The value is:

**You can do dangerous or sensitive work quickly, without leaving a mess behind.**

A very normal example:

You have a bot that needs exchange API keys.
Today, you might keep those keys in a file, or paste them into terminal, or leave them loaded too long.

With SymbiAuth:

* you unlock trust on your phone
* press “Run Bot” on the Mac
* the bot gets the keys just for that session
* when the session ends, access is removed

Another example:

You need to SSH into a production machine.
With SymbiAuth:

* trust starts
* the SSH key becomes available
* your session opens
* when trust ends, the key is no longer available

So for a non-technical user, the product promise is:

> **“Use your sensitive tools on your Mac only when you approve them from your phone, and let everything shut itself down cleanly afterwards.”**

The main thing a user needs to understand is:

* the phone is the approval device
* the Mac is where the work happens
* trust can be temporary
* the app helps prevent secrets from being left behind



### Launcher Schema (potential)

Here’s the **exact v1 launcher schema** and a **safe-enough injection model** that is realistic to build.

---

# 1) V1 launcher schema

Keep it brutally small.

```json
{
  "id": "uuid",
  "name": "Run Freqtrade",
  "kind": "command",
  "exec_path": "/bin/zsh",
  "args": ["-lc", "./run_freqtrade.sh"],
  "cwd": "/Users/sergiu/projects/freqtrade",
  "secret_refs": ["BINANCE_API_KEY", "BINANCE_API_SECRET"],
  "mount_volume": false,
  "kill_on_revoke": true,
  "enabled": true
}
```

## Field meanings

### `id`

Unique launcher ID.

### `name`

User-facing label in the menubar UI.

### `kind`

For v1, keep it always:

* `"command"`

Later you can add:

* `"ssh"`
* `"app"`

### `exec_path`

Executable to run.

Examples:

* `/bin/zsh`
* `/usr/bin/python3`
* `/usr/bin/open`

### `args`

Array of arguments.

Examples:

* `["-lc", "./run_freqtrade.sh"]`
* `["main.py", "--mode", "live"]`

### `cwd`

Working directory.

### `secret_refs`

Names of secrets the launcher is allowed to request.

Important:

* the launcher stores **references**, not secret values.

### `mount_volume`

Whether to mount the encrypted secrets volume before launch.

### `kill_on_revoke`

If true, SymbiAuth kills tracked process(es) on revoke.

### `enabled`

UI toggle.

---

# 2) Secret schema

Keep secrets separate from launchers.

```json
{
  "id": "uuid",
  "name": "BINANCE_API_KEY",
  "kind": "env",
  "value_ref": "stored-in-keychain-or-encrypted-store"
}
```

For v1, you can keep it even simpler internally:

* `name`
* encrypted value in local secret store

The launcher only needs `name`.

---

# 3) Runtime execution model

When user clicks a launcher during trust:

## Step 1: Validate trust

Rust checks:

* current trust mode/state allows action
* trust not revoked
* launcher exists and is enabled

## Step 2: Resolve secrets

For each `secret_ref`:

* fetch actual value from secure local store

## Step 3: Prepare session context

Optional:

* mount secrets volume if `mount_volume == true`

## Step 4: Launch process

Spawn process with:

* `exec_path`
* `args`
* `cwd`
* env vars from resolved secrets

## Step 5: Track for cleanup

Store:

* launcher ID
* PID / process group
* mounted volume flag
* temp files created

---

# 4) Safe v1 injection model

For v1, use **env var injection** first.

## Why

Because it is:

* easy
* useful
* enough for many workflows
* simple to clean up

## Rust spawn example

Conceptually:

```rust
Command::new(&launcher.exec_path)
    .args(&launcher.args)
    .current_dir(&launcher.cwd)
    .env("BINANCE_API_KEY", resolved_key)
    .env("BINANCE_API_SECRET", resolved_secret)
    .spawn()
```

---

# 5) Security reality of env vars

Be honest: env vars are not perfect.

Risks:

* child process can leak them in logs
* scripts may print them accidentally
* same-user inspection can expose them in some contexts

But for v1 they are still useful because:

* they are much better than hardcoding secrets in repos
* much better than leaving `.env` files everywhere
* easy to scope to one launched process
* easy to rotate later to temp-file mode

So env vars are a **good v1 starting point**, not the final security ceiling.

---

# 6) Better-than-env option for later

Later add:

## Temp file injection

For secrets like:

* SSH private keys
* JSON keyfiles
* wallets
* certs

Flow:

* create temp file with `0600`
* pass path in args or env
* track temp file
* delete on revoke

That should be v1.1, not v1.

---

# 7) Cleanup tracking schema

When a launcher runs, store a runtime record like:

```json
{
  "run_id": "uuid",
  "launcher_id": "uuid",
  "pid": 12345,
  "started_at": 1772227983000,
  "kill_on_revoke": true,
  "mounted_volume": false,
  "temp_paths": []
}
```

This is what revoke uses.

---

# 8) Revoke behavior

On trust revoke:

## If `kill_on_revoke == true`

* kill PID / process group

## If volume mounted

* unmount it

## If temp files created

* delete them

Then mark run as closed.

Important:

* Don’t try to “resume” killed processes later.
* New trust = user can launch again.

---

# 9) Launcher UI fields

For v1 Mac UI, ask only for:

* **Name**
* **Executable / script**
* **Arguments**
* **Working directory**
* **Secrets to inject**
* **Mount secrets volume?**
* **Kill on revoke?**

That’s enough.

---

# 10) Add a “Test Launcher” button

Very important.

Before user saves:

* check file exists
* check cwd exists
* check referenced secrets exist
* maybe dry-run command formatting

Show:

* ✅ Valid
* ❌ Missing secret `BINANCE_API_SECRET`
* ❌ Script path not found

This will save you a lot of pain.

---

# 11) Good v1 examples

## Example A — trading bot

* exec: `/bin/zsh`
* args: `["-lc", "./run_bot.sh"]`
* cwd: `/Users/sergiu/bot`
* secrets: `BINANCE_API_KEY`, `BINANCE_API_SECRET`
* mount volume: false
* kill on revoke: true

## Example B — SSH session

* exec: `/bin/zsh`
* args: `["-lc", "ssh trader@prod-box"]`
* cwd: `/Users/sergiu`
* secrets: `PROD_SSH_KEY_PATH` or later temp-file key
* mount volume: false
* kill on revoke: true

## Example C — signer

* exec: `/bin/zsh`
* args: `["-lc", "./start_signer.sh"]`
* cwd: `/Users/sergiu/signer`
* secrets: `RPC_URL`, `SIGNER_KEY`
* mount volume: true
* kill on revoke: true

---

# 12) My recommendation for implementation order

## First ship:

* launcher schema
* secret refs
* env var injection
* PID tracking
* kill on revoke

## Then add:

* mounted secrets volume
* temp file injection
* SSH template

---

# 13) Product truth

A Trusted Launcher is not magic. It is:

> “A saved command that can temporarily receive sensitive context during a trusted session, and gets cleaned up automatically when trust ends.”

That’s a real product.

If you want, next I’ll write the **exact Rust structs** for:

* `Launcher`
* `SecretRef`
* `ActiveRun`

and the basic file format to store them locally.



# Question: That cleanup can mean: stopping the process If user is running a trading bot or whatever, means that as soon as phone is locked, or app is no longer in foreground the trading bot stops?

## Answer: Not necessarily. That depends on the **trust mode** and the **launcher cleanup policy**.

### There are two separate things

1. **Trust state**
   Whether the Mac is currently allowed to access sensitive capabilities.

2. **What happens to already-started processes**
   Whether a bot/script/session keeps running after trust changes.

Those are related, but they do not have to be identical.

---

## In practice

### If the launcher is marked **“kill on revoke”**

Then yes:

* trust ends
* the bot gets stopped

That is the safest behavior.

### If the launcher is marked **“do not kill on revoke”**

Then:

* trust ends
* no new sensitive actions can start
* but the already-running process may continue

That is less safe, but sometimes much more practical.

---

## Example: trading bot

A trading bot is exactly the kind of thing where users may **not** want it killed the second the phone locks.

So a realistic behavior would be:

* User starts trust from phone
* Launches bot
* Bot starts with the needed API keys/config
* After that, bot can keep running even if trust later ends
* But:

  * user cannot launch **new** protected actions without re-trusting
  * secrets volume may unmount only if bot no longer needs it
  * if the bot depends on mounted files, killing/unmounting may break it

So for bots, you probably want a launcher option like:

* **Stop on revoke**
* **Allow to continue after revoke**

---

## The real product decision

SymbiAuth should not have one global rule like:

> “phone locked = kill everything”

That would be too dumb and too annoying.

It should let the user decide **per launcher**.

### Good default

For v1:

* default = **kill on revoke**
* but user can disable it for certain launchers

That gives safety by default, flexibility where needed.

---

## Better way to explain it

Trust means:

* **permission to start or unlock sensitive things**

It does **not always mean**:

* “everything dies instantly when trust ends”

Sometimes it should.
Sometimes it should not.

---

## Good examples

### SSH session

Probably:

* **kill on revoke = yes**

Because if trust is gone, the session should die.

### Trading bot

Maybe:

* **kill on revoke = optional**

Because once launched, it may be intended to run for hours.

### Mount private volume

Usually:

* **unmount on revoke = yes**

Because that is exactly the thing you want to disappear.

---

## The clean mental model

When trust ends, SymbiAuth should ask for each launcher/resource:

> “Does this thing need to die when trust ends, or was trust only needed to start it?”

That is the right product model.

So your answer is:

**No, locking the phone or leaving foreground does not have to stop a trading bot automatically.**
It only stops it if that launcher is configured to stop on revoke.

Here is a clean v1 policy table:

* bots
* SSH sessions
* mounted volumes
* temp files
* browser sessions
  so you know what the default behavior should be for each.

Here’s a clean v1 policy table you can actually build around.

# SymbiAuth v1 cleanup policy by action type

## 1) Trading bot / long-running process

### Default:

**Do not kill on revoke**

### Why:

Trust was needed to **start** it safely, not necessarily to keep it alive.
If you kill it every time the phone locks or the app backgrounds, users will hate it.

### What should happen on revoke:

* no new protected actions can start
* bot keeps running
* SymbiAuth marks it as **running outside trust**
* if it depends on a mounted secrets volume, warn the user before launch or require a different injection method

### Good user option:

* `Keep running after revoke`
* optional stricter toggle: `Kill on revoke`

---

## 2) SSH session

### Default:

**Kill on revoke**

### Why:

SSH is usually a live privileged session.
If trust is gone, keeping that shell alive defeats the point.

### What should happen on revoke:

* terminate SSH process
* remove temporary key / ssh-agent identity if added by SymbiAuth

### Good user option:

* `Kill on revoke` = default on
* advanced users can disable it, but hide that behind advanced settings

---

## 3) Mounted secrets volume

### Default:

**Unmount on revoke**

### Why:

This is exactly the kind of thing that should disappear when trust ends.

### What should happen on revoke:

* unmount volume
* if files are actively in use, try clean detach first, then force after timeout
* if impossible, show warning and fail closed as much as possible

### User option:

* usually no need for “keep mounted”
* for v1, keep it strict

---

## 4) Temp secret files

### Default:

**Delete on revoke**

### Why:

They are temporary by definition.

### What should happen on revoke:

* delete temp files
* if in use and deletion fails, log it and retry briefly
* cleanup timeout fallback

### User option:

* none for v1

---

## 5) Env-var injected launched command

### Default:

**Depends on launcher type**

* generic script/tool: **kill on revoke = on**
* long-running bot/service: **kill on revoke = off**

### Why:

Env vars are only used at process start. Once the process is running, trust ending does not magically remove env vars from that process.

So the decision is really:

* do we allow this process to continue existing after trust?
* not “can we uninject env vars,” because we can’t

### User option:

* per launcher:

  * `Stop on revoke`
  * `Allow to continue`

---

## 6) Signer / wallet session

### Default:

**Kill on revoke**

### Why:

This is high risk. If a signing process remains alive after trust ends, that’s dangerous.

### What should happen:

* stop signer
* remove temp key material
* unmount supporting volume if used

### User option:

* maybe later, but v1 should be strict

---

## 7) Browser / dashboard / exchange session

### Default:

**Do not attempt in v1** beyond maybe launching the app/browser

### Why:

This gets messy fast. Closing tabs, wiping cookies, handling app state is a whole product by itself.

### V1 recommendation:

* don’t make this a core cleanup promise yet

---

# The simplest v1 rule set

## Resources that should always disappear on revoke

* mounted secrets volume
* temp secret files
* signer sessions
* SSH sessions

## Things that may continue after revoke

* long-running bots
* generic launched commands marked “allow continue”

---

# The launcher setting you need

Every launcher should have one very important field:

### **Revoke behavior**

* `Stop when trust ends`
* `Allow to continue after trust ends`

That one choice solves a lot.

You do **not** need 20 cleanup settings in v1.

---

# Best defaults for v1

## Default for new launcher:

* `Stop when trust ends` = **ON**

That keeps the product safe by default.

Then for specific use cases like bots, advanced users can turn it off.

---

# How to explain this to users

Trust controls **starting and access**.
Cleanup controls **what happens after trust ends**.

So the user understands:

* some things are temporary and should vanish
* some things only needed trust to start, and can continue

---

# My product recommendation

For v1, support these cleanup classes:

### Always clean up

* volumes
* temp files
* ssh
* signer

### Per-launcher choice

* command/bot/process

That is the right balance.

If you want, next I can turn this into a concrete launcher schema field like:
`revoke_behavior: "stop" | "allow_continue"`
and explain exactly how the Mac UI should present it.


# Product design idea:
Good. This is the real product question.

Forget the protocol for a second. The Mac app should feel like a **small control tower for trusted actions**.

Not a developer dashboard.
Not a settings graveyard.
Not “Bluetooth manager.”

It should answer only 3 things for the user:

1. **Am I trusted right now?**
2. **What can I do while trusted?**
3. **What will happen when trust ends?**

---

# The Mac app: what it should be

The Mac side should be a **menubar-first app**.

Why:

* this is not a full-blown destination app users want open all day
* trust is stateful and operational
* the actions are short and utility-like

So think of it like:

* 80% of the time: user interacts through the **menubar**
* 20% of the time: user opens a **configuration window** to add/edit launchers, secrets, and policies

---

# The Mac app structure

## 1) Menubar popover = live control panel

This is the thing users will actually use during the day.

It should show:

### Top section: Trust status

Examples:

* **Locked**
* **Trusted**
* **Signal lost — revoking in 4:12**
* **Office mode — active**

This is the heart of the product.

---

### Middle section: Available trusted actions

A clean list of launchers:

* Run Freqtrade
* Open Prod SSH
* Start Signer
* Mount Secrets Volume

Each item should be very obvious:

* name
* tiny description
* maybe one icon
* a Run button

Not too much metadata in the main view.

---

### Bottom section: Session controls

Examples:

* End Trust Now
* Show Details
* Open SymbiAuth

Optional:

* signal/mode label
* paired phone name

---

## 2) Full app window = setup and management

This is where users configure things.

This should have 4 tabs max:

### A. Home / Overview

* trust status
* paired device
* summary of launchers
* recent actions

### B. Launchers

This is the most important setup page.

### C. Secrets

Where user stores secret values or references.

### D. Settings

Modes, cleanup defaults, pairing, advanced stuff.

That’s enough.

---

# The actual user flow

Now let’s go through how a real user would use it.

---

# First-time setup flow

## Step 1: Pair the phone

User opens the Mac app, clicks:

* **Pair iPhone**
* QR appears
* phone scans it
* done

After pairing, the Mac app should clearly show:

* paired phone name
* last seen
* pairing status

This is the “device trust” layer.

---

## Step 2: Add secrets

User goes to **Secrets** tab.

They add things like:

* BINANCE_API_KEY
* BINANCE_API_SECRET
* PROD_SSH_KEY
* RPC_URL

For v1, the simplest UX is:

* Name
* Value
* Save

Later you can improve with categories/types.

At this point the Mac app becomes their **local sensitive-actions hub**.

---

## Step 3: Create launchers

User goes to **Launchers** tab.

They click:

* **New Launcher**

Then they fill a form like:

### Example

* Name: `Run Freqtrade`
* Command: `/bin/zsh`
* Args: `-lc ./run_bot.sh`
* Working directory: `/Users/sergiu/projects/freqtrade`
* Secrets needed:

  * BINANCE_API_KEY
  * BINANCE_API_SECRET
* Revoke behavior:

  * Stop when trust ends / Allow continue
* Mount secrets volume:

  * On / Off

Then save.

That’s it.

So the user is basically teaching the app:

> “When I’m trusted, this is one of the things I may want to run.”

---

# Daily usage flow

This is where the product must feel good.

## Example 1: User wants to run a bot

### On phone

* opens SymbiAuth
* taps Start Session
* Face ID
* trust becomes active

### On Mac

* menubar changes to **Trusted**
* user clicks menubar
* sees launcher list
* clicks **Run Freqtrade**

The app:

* resolves secrets
* injects them
* runs the command
* tracks the process

Then the user goes back to work.

If trust ends later:

* depending on launcher settings, the bot stops or keeps running

That is the real UX.

---

## Example 2: User needs a production SSH session

### On phone

* Start Session → Face ID

### On Mac

* menubar → Run “SSH Prod”

The app:

* makes SSH credentials available for that session
* opens the SSH process

On revoke:

* session dies
* temp key data is removed

This feels magical but is actually simple.

---

## Example 3: User wants access to a private workspace

### On phone

* Start Session

### On Mac

* click “Mount Private Workspace”

The app:

* mounts the secrets volume

When done:

* trust ends or user clicks End Session
* volume unmounts

Very clear. Very useful.

---

# What the launcher screen should actually look like

This matters a lot.

## Launchers page

A list of cards/rows:

### Each row shows:

* launcher name
* a short subtitle:
  “Runs `run_bot.sh` with 2 secrets”
* status:

  * enabled
  * last run
* actions:

  * Run
  * Edit
  * Duplicate
  * Delete

Optional:

* small badge:

  * “Stops on revoke”
  * “Keeps running”

This makes it legible.

---

## New launcher flow

Do not overwhelm the user.

### Step 1: Basic

* Name
* Command / script path
* Args
* Working dir

### Step 2: Secrets

* choose from existing secrets

### Step 3: Behavior

* Stop when trust ends?
* Mount secrets volume?
* Save

That’s enough.

Do not show 25 advanced toggles.

---

# What the secrets page should look like

## Secret list

Rows:

* BINANCE_API_KEY
* PROD_SSH_KEY
* RPC_URL

Actions:

* Add
* Edit
* Delete

For safety:

* values masked
* optional reveal button
* “used by N launchers” label

This is important because users need to understand the connection:

> secret → launcher

---

# What the menubar should feel like

This is critical.

When the user clicks the menubar icon, they should immediately understand the state.

## Locked state

Top:

* **Locked**
* “No active trust session”

Middle:

* launcher list visible but disabled, or hidden behind “Start session on iPhone”

Bottom:

* Pair iPhone
* Open SymbiAuth

---

## Trusted state

Top:

* **Trusted**
* mode/status line
  e.g. `Phone connected` or `Signal lost — revoking in 03:44`

Middle:

* launcher list enabled

Bottom:

* End Session
* Open SymbiAuth

This is the money shot.

---

# What “Open SymbiAuth” full window is for

The full window is not for daily actions.
It is for setup and understanding.

Users go there to:

* create launchers
* manage secrets
* change trust mode defaults
* inspect what happened

So the product has two layers:

* **Control layer:** menubar
* **Configuration layer:** full app

---

# What users really need from the product

Let’s be honest.

Most users do **not** want to “manage trust policies.”
They want:

* “Run my sensitive thing”
* “Know I’m safe when I leave”
* “Not leave secrets behind”

So don’t make the app feel like a security admin console.

Make it feel like:

> “A small trusted launcher panel for dangerous tasks.”

That is much more compelling.

---

# The ideal v1 Mac app flow, simplified

## Setup once

1. Pair phone
2. Add secrets
3. Add launcher(s)

## Use daily

1. Start trust on phone
2. Click launcher on Mac
3. Work
4. Trust ends → cleanup

That’s the product.

---

# What should happen when user adds what they need?

Let’s say user asks:
“I have a script that needs these 2 API keys.”

The Mac app should let them do this in plain English:

### Create launcher

* What do you want to call this?
* What file or command should run?
* Which folder should it run in?
* Which saved secrets should be available to it?
* Should it stop when trust ends?

That is understandable even for non-technical users, as long as you give:

* file pickers
* simple labels
* examples/help text

---

# What not to do on the Mac side

Do not make users:

* write JSON
* understand BLE
* understand TTL/state machine jargon
* think about HMAC/proofs
* set 20 cleanup toggles
* manage too many modes upfront

Security complexity should stay under the hood.

---

# The best way to explain the Mac app to a user

You could say:

> “The Mac app is where you save your sensitive actions.
> Your phone decides when the Mac is trusted.
> While trusted, you can run those actions.
> When trust ends, SymbiAuth cleans up.”

That is clean.

---

# My recommended v1 Mac UI layout

## Menubar popover

* Trust status
* Launcher quick actions
* End session
* Open full app

## Full app tabs

* Overview
* Launchers
* Secrets
* Settings

That’s enough.

---

# Final product truth

The Mac app is not just “the other half” of the phone app.

It is the **place where users define what trust actually unlocks**.

Without launchers/secrets/resources on the Mac side, the trust session means nothing.

---

If you want, next I can design the exact **Mac app screens** one by one:

* menubar popover
* launchers page
* new launcher modal
* secrets page
  with concrete text labels and buttons.


### Current Mac app vs proposed Mac app

Yes — this screenshot makes it obvious.

What you have now is basically a **debug/status utility**, not a product UI.

It tells you:

* fingerprint
* port
* state
* mode
* phone suffix

That’s useful for us while building, but for a real user it answers the wrong questions.

A real user wants to know:

* **Am I trusted right now?**
* **What can I do right now?**
* **What happens if I leave?**

Your current popup answers none of those clearly.

## What’s wrong with the current menubar

The main problems are:

### 1. It feels infrastructural

“Fingerprint”, “Port”, “State: No session” reads like admin/debug tooling.

### 2. The main action is hidden

The only visible meaningful action is “Show Pairing QR Code”.
But the actual future value of the app is not pairing. It’s:

* run trusted action
* start/maintain session
* end session
* see countdown / trust mode

### 3. No hierarchy

Everything has roughly the same visual weight.
There’s no strong “status block”, no “action zone”, no “danger zone”.

### 4. It does not sell the product

If I opened this as a user, I would not understand:

* what this app is for
* what I should do next
* what trust unlocks

---

# What the menubar should become

It should become a **small operational dashboard**.

Not pretty first.
Clear first.

## Structure I’d recommend

### Top block: Trust status

This should be the most visually important thing.

Examples:

**Locked**

* Locked
* No active trust session
* Start a session from your iPhone

**Trusted**

* Trusted
* Phone connected
* or `Signal lost — revoking in 04:32`

**Office mode**

* Trusted
* Office mode active
* Locks on idle/sleep

This is the heartbeat of the product.

---

### Middle block: Quick actions

This is where the product becomes valuable.

Examples:

* Run Trading Bot
* Open Prod SSH
* Mount Secrets Volume
* Start Signer

These should be disabled when Locked, enabled when Trusted.

That immediately communicates:

> “This app is for running sensitive actions safely.”

---

### Lower block: Session controls

Examples:

* End Session
* Trust Mode: Strict / TTL / Office
* Open SymbiAuth

---

### Bottom block: Secondary / maintenance

Move old utility stuff here or into a separate screen:

* Show Pairing QR Code
* Repair Browser Bridge
* Remove Browser Bridge Manifest
* Quit

And debug info like:

* fingerprint
* port
* phone suffix

should not be in the main user view. Put them under:

* Advanced
* Developer
* Diagnostics

---

# What the first improved menubar could look like

## Locked state

**SymbiAuth**
Locked
Start a session from your iPhone

Trusted Actions

* Run Trading Bot
* Open Prod SSH
* Mount Secrets Volume

These are greyed out.

Divider

Pair iPhone
Open SymbiAuth
Developer / Diagnostics
Quit

---

## Trusted state

**SymbiAuth**
Trusted
Phone connected

Trusted Actions

* Run Trading Bot
* Open Prod SSH
* Mount Secrets Volume

Divider

Mode: Office
End Session
Open SymbiAuth
Quit

---

## Signal lost state

**SymbiAuth**
Signal lost
Revoking in 04:32

Trusted Actions

* Run Trading Bot
* Open Prod SSH
* Mount Secrets Volume

Depending on your chosen policy, these remain enabled or not.

Divider

Mode: Background TTL
End Session
Open SymbiAuth
Quit

---

# What to do with the old debug fields

From your screenshot:

* Fingerprint
* Port
* State
* Mode
* iPhone suffix

These are still useful, but not here.

Put them in:

### Developer / Diagnostics

* Mac fingerprint
* Paired iPhone fingerprint suffix
* BLE state
* UDS state
* Trust state
* Last event
* Pairing status

That way:

* normal users aren’t confused
* you still keep your observability

---

# Best immediate next UX move

Before doing visual polish, change the information architecture:

## Current

Infra/debug first, product second

## Needed

Product first, infra/debug hidden

That alone will massively improve the feel.

---

# My blunt take

Your current menubar is not “bad design” because of colors or spacing.
It’s bad because it reflects the **old architecture**, not the **new product**.

It still looks like:

> “TLS utility with a QR function.”

It needs to become:

> “Trusted actions control panel.”

That is the real pivot on the Mac side.

If you want, next I’ll sketch the exact text and sections for:

1. Locked popup
2. Trusted popup
3. Signal lost popup
4. Developer/Diagnostics popup

so you can hand it to the reviewer/dev as a concrete UI spec.
