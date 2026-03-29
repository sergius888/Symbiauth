# Trusted Shell v1

> Status: Proposed next chamber capability
> Product role: A chamber-owned ephemeral shell session for sensitive CLI work
> Positioning: Not a replacement for Terminal.app. A short-lived trusted shell that can receive chamber secrets on demand and dies when trust ends.

---

## 1. Product Definition

Trusted Shell is a chamber-owned terminal session that:

- is launched from the Secret Chamber spine
- runs a real shell inside a PTY owned by SymbiAuth
- can receive selected chamber secrets during the session
- is terminated automatically when trust ends

The important boundary:

- SymbiAuth does **not** secure the user's existing Terminal.app session
- SymbiAuth does **not** inject secrets into arbitrary already-running shells
- SymbiAuth **does** own the shell process, its PTY, and its secret-injection path

That is what makes the feature real instead of theater.

---

## 2. Why This Feature Fits

Trusted Shell is one of the few power-user features that fits the current chamber model:

- short trust windows still make sense for sensitive command-line work
- the chamber already manages secrets locally
- the chamber already has lifecycle control and trust revocation
- terminal work is one of the few places where "inject only while trusted" has obvious value

Examples:

- run a deployment with an injected token
- use cloud credentials for one short session
- run a DB migration with temporary credentials
- use a signing or API secret without keeping it in a normal long-lived shell

---

## 3. UX Goals

Trusted Shell should feel:

- terminal-native
- chamber-owned
- short-lived
- high-trust, high-intent

It should **not** feel like:

- another giant config form
- a fake Terminal clone
- a launcher bolted onto the side of the chamber

Core UX rule:

- launch the shell first
- inject secrets during the session as needed
- do not force the user to pre-plan every secret before the shell opens

---

## 4. Entry in the Chamber

### Spine

Add a new spine marker:

- `[T]`

Tooltip:

- `TRUSTED SHELL`

Meaning:

- opens the Trusted Shell panel in the second slot

This should behave like any other chamber section:

- click once: open
- click again: close

---

## 5. Panel Architecture

### Level 1

Existing chamber spine remains unchanged except for the new `[T]` marker.

### Level 2

Trusted Shell panel lives in the second slot.

This panel has 2 states:

1. `Shell Setup`
2. `Live Shell`

### Level 3

Avoid using the third panel for initial secret selection.

Reason:

- it breaks the shell-first flow
- it makes the feature feel like another form stack instead of terminal work

The third panel may later be used for advanced shell session metadata or command history, but it is not required for v1.

---

## 6. User Flow

### Flow A: Start Shell

1. User starts trust on iPhone.
2. Chamber spine appears.
3. User clicks `[T]`.
4. Second panel opens in `Shell Setup` mode.
5. User chooses:
   - shell type
   - working directory
   - guard mode (`Strict` or `Background TTL`)
6. User clicks `[ OPEN TRUSTED SHELL ]`.
7. The panel transitions into a live terminal session.

### Flow B: Inject Secrets Mid-Session

1. User is already inside Trusted Shell.
2. User decides they need a chamber secret.
3. User runs a chamber helper command:
   - `chamber inject`
4. An inline terminal selector appears inside the shell view.
5. User selects one or more secrets.
6. The selected secrets are injected into the current shell session environment.
7. Shell returns to prompt.

### Flow C: Add More Secrets Later

1. User runs some commands.
2. User later remembers they need another secret.
3. User runs `chamber inject` again.
4. Selector reappears.
5. New secrets are added to the shell environment for future commands.

### Flow D: Trust End

If `Strict`:

- shell is terminated immediately
- panel seals/closes immediately

If `Background TTL`:

- shell enters a countdown state
- if trust returns before expiry, session survives
- otherwise shell is terminated

---

## 7. Setup Panel

The setup panel should be compact and intentional, not a long form.

### Fields

- `SHELL`
  - default: user's login shell if known, otherwise `/bin/zsh`
- `WORKDIR`
  - default: user's home directory
  - optional chooser later
- `GUARD`
  - `STRICT`
  - `BACKGROUND TTL`
- `TTL`
  - shown only if `BACKGROUND TTL` is selected

### Copy

Title:

- `⌈ TRUSTED SHELL ⌋`

Subtitle:

- `Short-lived chamber-owned shell for sensitive commands.`

Button:

- `[ OPEN TRUSTED SHELL ]`

Guard helper:

- `STRICT`: shell ends immediately when trust ends
- `BACKGROUND TTL`: shell survives briefly after trust loss

### Important rule

Do not ask the user to select secrets here by default.

Secrets are injected later from inside the running shell.

---

## 8. Live Shell UX

The live shell should look like a real terminal, not a text field pretending to be one.

### Structure

Top rail:

- `⌈ TRUSTED SHELL ⌋`
- `MODE: STRICT` or `MODE: TTL`
- `DIR: …`
- maybe `ENV: 3` once secrets are injected

Main body:

- PTY-backed terminal output
- scrollback
- selection/copy
- normal prompt and command behavior

Bottom status line:

- trust state
- transient messages such as:
  - `Injected 2 secrets into current shell`
  - `Trust lost. Terminating shell.`

### Tone

The shell must visually belong to the chamber:

- mono
- dense
- industrial
- restrained accenting

But it must not become unreadable or decorative.

---

## 9. Secret Injection Model

### User Command

Use a shell helper command:

- `chamber inject`

Optional future helpers:

- `chamber list`
- `chamber clear`
- `chamber status`

But v1 only needs:

- `chamber inject`

### Selector UX

When user runs `chamber inject`, the terminal shows an inline selector:

```text
[ INJECT SECRETS ]

[ ] AWS_ACCESS_KEY_ID
[ ] AWS_SECRET_ACCESS_KEY
[ ] DEPLOY_TOKEN
[ ] DB_PASSWORD

↑/↓ move   space select   enter inject   esc cancel
```

After confirm:

```text
Injected: AWS_ACCESS_KEY_ID, DEPLOY_TOKEN
```

Then terminal returns to prompt.

### Why inline selector is better

- terminal-native
- works mid-session
- no chamber category hopping
- no preplanning friction

---

## 10. Secret Injection Semantics

This matters:

- injected secrets become available to the current chamber-owned shell session
- commands launched **after** injection inherit them
- already-running child processes do not retroactively gain them

That behavior is normal and should be documented.

### Names

By default, secret names map directly to env var names.

Example:

- secret `DEPLOY_TOKEN` -> env `DEPLOY_TOKEN`

Later we can support aliases, but not in v1.

---

## 11. Trust Guard Modes

### Strict

Default for Trusted Shell.

Behavior:

- immediate termination on trust end

Use case:

- very sensitive short CLI work

### Background TTL

Optional advanced mode.

Behavior:

- shell survives briefly after trust loss
- if trust does not return before expiry, shell dies

Use case:

- user temporarily switches phone state and does not want hard interruption mid-flow

### Recommendation

For Trusted Shell, support:

- `STRICT`
- `BACKGROUND TTL`

Do not support:

- `OFFICE`

Reason:

- too fuzzy for a shell session
- weakens the mental model

---

## 12. Technical Model

### Correct architecture

The app launches:

- a PTY
- a real shell process (`zsh`, or user's shell)
- chamber helper loaded into that shell environment

SymbiAuth owns:

- the PTY
- the shell process
- the child process tree
- secret injection path

### Incorrect architecture

Do not:

- launch the user's existing Terminal.app and call it secure
- try to modify arbitrary existing shells
- inject into shells the app does not own

---

## 13. Security Boundaries

Trusted Shell is useful, but not magic.

Must be stated clearly:

- commands inside the shell can read injected secrets
- shell actions can still write files or persist data
- already-running tools may keep their own side effects
- this is controlled execution, not full containment

So the promise is:

- chamber owns the shell session
- secrets are scoped to that session
- trust end kills the session

Not:

- nothing can ever leak or persist

---

## 14. Good v1 Scope

Build only:

- `[T]` spine entry
- setup panel
- PTY-backed shell
- strict / background TTL
- `chamber inject`
- inline secret picker
- kill shell on trust end

Do not build yet:

- multiple shell tabs
- Terminal.app integration
- alias mapping
- shell history virtualization
- command recording
- pane splitting
- advanced shell profile editor

---

## 15. Why This Is Worth Building

This is a meaningful chamber-native capability because it:

- deepens the chamber beyond passive storage
- gives technical users a real action surface
- fits the trust lifecycle you already have
- avoids the “feature count” trap of random extra categories

If implemented cleanly, Trusted Shell can become the chamber's strongest advanced feature without dragging the product back into the old DevOps launcher mess.
