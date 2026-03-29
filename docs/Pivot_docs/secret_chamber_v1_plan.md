# Secret Chamber V1 Plan

> Status: proposed replacement plan for the current macOS Preferences-based surface
> Purpose: define the v1 product, UX structure, and transition path clearly enough to implement without drifting back into a mediocre utility panel

---

## Product Definition

SymbiAuth v1 becomes a **phone-gated private workspace on macOS**.

The product is not:
- a DevOps tunnel product in v1
- a generic settings app
- a system-wide app locker
- a wallet
- a cloud secret manager

The product is:
- a local-first chamber that becomes available while iPhone trust is active
- a place where the user can access protected items that SymbiAuth owns
- a structured personal vault for short, intentional use

The chamber should feel like:
- a hidden space that opens when trust starts
- a substantial, designed workspace
- not a form editor
- not Preferences with better colors

---

## Core Constraints

These constraints must shape the product instead of being patched around later.

- iPhone trust is strongest in `Strict` mode and depends on active foreground use.
- The chamber must assume trust can end quickly.
- SymbiAuth can only protect content it owns or starts.
- The product must not imply protection of third-party apps, websites, or arbitrary files outside the chamber.
- The chamber should remain useful even for a user with no DevOps workflow.
- Every surface must have a clear reason to exist.

From this, the correct v1 behavior is:
- when trust starts, the chamber becomes available
- on the first trust activation of a session, the chamber opens automatically
- if the user closes it while trust remains active, it stays closed until manually reopened
- if trust ends, the chamber locks/closes immediately

---

## V1 User Job

The v1 user job is:

**"Access my protected local items only while my paired iPhone is actively trusted."**

That is narrower and more honest than:
- "secure my whole Mac"
- "replace my password manager"
- "protect every local action"

---

## V1 Scope

### Build in v1

- chamber window on macOS
- trust-driven chamber availability
- first-open auto slide-in animation when session starts
- manual reopen from menu bar while trust remains active
- three real content categories:
  - `Secrets`
  - `Notes`
  - `Documents`
- protected item storage and browsing
- item detail / preview
- add / edit / delete
- reveal / copy for text-based content while trust is active
- temporary open / export path for documents
- local history of chamber actions
- `Strict` as the default trust mode

### Defer from v1

- `Images`
- `Recovery`
- wallets
- signing
- managed command execution from the chamber
- drag-and-drop hierarchy
- folders
- browser/app integrations
- global overlays
- single-paste clipboard tracking

These deferred items should not appear as dead tabs in the v1 chamber UI.

---

## Information Architecture

The chamber should not use a top tab bar as the primary navigation model.

### Recommended structure

- left sidebar
- main content area
- right detail pane

This is the correct architecture for the chamber because:
- it scales better than top tabs
- it feels like a real workspace
- it gives categories a stable place
- it supports selection, preview, and future expansion without becoming crowded

### Left Sidebar

Sections:
- `All`
- `Secrets`
- `Notes`
- `Documents`
- `Favorites`
- `Recent`

Optional, later:
- `Recovery`
- `Images`

### Main Content Area

Displays the current category selection.

Mode:
- default to card/grid view for visual warmth and scanability
- allow an internal later switch to list view if needed, but do not build that first

The content area is responsible for:
- item browsing
- search results
- empty states
- quick actions

### Right Detail Pane

Visible when an item is selected.

Shows:
- title
- type
- metadata
- preview / revealed content
- actions

This pane should feel stable and useful, not like a modal inspector.

---

## Window Behavior

### Recommended window shape

Use a large bounded chamber window, not a full-width top-half sheet.

Suggested behavior:
- opens with a slide/fade motion from the menu bar zone on first trust activation
- occupies roughly 60-70% width and 65-75% height
- remains above normal windows while open
- centered or slightly right-biased

Why not full-width top-half:
- it feels like a dashboard, not a private chamber
- it wastes horizontal space
- it makes category navigation weaker
- it is harder to make elegant

### Chamber states

- `Locked`
- `Available`
- `Open`
- `HiddenWhileTrusted`

Rules:
- trust starts -> chamber becomes `Available`
- first availability in a session -> auto-open with animation
- user closes it -> `HiddenWhileTrusted`
- menu bar click while trusted -> reopen
- trust ends -> return to `Locked` and close immediately

This preserves the "magic" of the first open without forcing the chamber back on screen every time the user dismisses it.

---

## Header Model

The header should be **trust-state-first**, not countdown-first.

### Header should show

- `Secret Chamber`
- current trust state:
  - `Trusted`
  - `Trust ending`
  - `Locked`
- paired device context if useful
- search field
- close button
- `End Session` button

### Timer handling

Do not make the timer the main identity of the product.

If a timer is shown:
- it should be secondary and contextual
- visible only in modes where it matters
- not the main right-side hero label

This avoids dragging old TTL-centric thinking into the chamber.

---

## Category Model

Use one unified model: `ProtectedItem`.

### V1 categories

#### Secrets

Examples:
- passwords
- API keys
- tokens
- passphrases
- recovery codes

Primary actions:
- reveal while trusted
- copy while trusted

#### Notes

Examples:
- private notes
- access instructions
- custody notes
- technical snippets

Primary actions:
- read
- edit
- copy selected content

#### Documents

Examples:
- JSON backups
- PDFs
- exported configs
- private text files

Primary actions:
- preview
- export temporarily

### Internal later categories

Keep these documented but not visible in v1:
- `Images`
- `Recovery`

---

## Protected Item Model

All items share a common internal structure.

### Internal fields

- `id`
- `category`
- `title`
- `note`
- `tags`
- `favorite`
- `created_at`
- `updated_at`
- `last_opened_at`
- `encrypted_payload`
- `preview_mode`
- `status`

Users should not see schema-level fields directly.

### User-facing add/edit fields

Only ask for:
- `Type`
- `Title`
- `Content` or `Choose File`
- optional `Note`
- optional `Tags`

This keeps the data model strong without making the UI feel like a database form.

---

## Trust-Bound Content Behavior

This is the most important behavioral rule set in the chamber.

### Reveal behavior

Do not use arbitrary 10-second reveal timers as the primary model.

For v1:
- text content stays revealed while trust remains active and the user is viewing it
- when trust ends, content re-locks immediately
- when the user navigates away, the item can remain selected but locked again if needed

### Copy behavior

For v1:
- allow copy while trust is active
- chamber should visibly indicate when protected clipboard content is present
- clear clipboard best-effort when trust ends
- allow optional timeout-based clearing as a setting later

Do not promise:
- exact paste detection
- exact one-paste lifecycle
- global cursor indicators

### Document behavior

For v1:
- preview within the chamber when possible
- allow temporary export only while trusted
- revoke/remove temporary exports when trust ends where possible
- clearly signal that exported files are temporary

---

## UX Principles

These rules should govern every screen and interaction.

- the chamber must feel deliberate, not assembled
- no dead-end settings-heavy screens on the main path
- every action should map to a real object the app owns
- category placement must feel stable
- trust changes must cause obvious chamber state changes
- editing and viewing should happen in context, not through endless modal churn
- avoid fake complexity and "security theater"

If a feature has no clear place in this structure, it should not be in v1.

---

## Visual Direction

Keep the dark matte direction from the earlier spec.

### Keep

- black / charcoal palette
- subtle borders
- no neon
- no purple
- no fake "cyber" styling

### Change

- design the chamber as a premium bounded workspace, not a stretched dashboard panel
- make the sidebar and detail pane feel like architectural elements, not just dividers
- trust activation should create a subtle "opening" effect
- closing on trust end should feel decisive, not decorative

---

## macOS App Structure Transition

The current macOS app still reflects old product phases.

### Current problems

- `Diagnostics` is too prominent for the new product
- `Sessions` / managed commands are still occupying first-class product space
- `Secrets` exists as a support panel, not the product itself
- the overall app still reads like an operator utility, not a coherent product

### Target structure

The new app should move toward:
- chamber as the primary surface
- trust/session state as a supporting surface
- history as a supporting surface
- settings as an advanced surface

### Recommended top-level surfaces

- `Secret Chamber`
- `History`
- `Session`
- `Settings`

Notes:
- the chamber should be accessible from the menu bar and also through the main app shell
- `History` should include trust and content-use events
- `Session` should explain current trust state and paired phone context
- `Settings` should contain advanced trust mode settings and app behavior

---

## What To Do With The Existing Managed Session / DevOps Work

Do not delete it casually.

It is still real engineering work and may become:
- a later advanced feature
- a separate experimental mode
- a future v2 product branch

### Professional handling

The correct move is:
- remove it from the primary UI path
- preserve the code and documentation
- mark it as parked / deferred
- avoid showing it as active product identity

### How to treat it in docs

Create a clear parked-feature note:
- what exists
- why it is not in v1
- what conditions would justify reviving it

### How to treat it in code/UI

For now:
- hide or demote managed-session surfaces from the main product shell
- do not rip them out unless they block progress
- keep labels and code paths understandable for future reactivation

This is better than deleting useful work or letting it clutter the new chamber product.

---

## Menu Bar Transition

The menu bar should move from utility clutter toward clear chamber-centric behavior.

### V1 menu bar priorities

- trust state
- open chamber
- start/end session
- recent chamber actions if useful
- settings

### De-emphasize

- raw diagnostics
- old managed-session language
- DevOps-oriented actions

The menu bar should feel like:
- the door to the chamber
- not a generic operator console

---

## Strict vs Advanced Modes

`Strict` should be the default chamber mode.

Reason:
- it matches the chamber mental model
- content exists only while the phone is actively trusted
- it is the cleanest and safest product story

Advanced modes such as:
- `Background TTL`
- `Office`

should be:
- preserved if needed
- moved into advanced settings
- behind a clear warning/confirmation flow

The chamber UX should not be designed around these relaxed modes.

---

## Implementation Phases

### Phase 1: Product shell reset

- define chamber as the primary product surface
- demote or hide old managed-session-first navigation
- add parked-feature documentation for DevOps/managed sessions
- simplify top-level app structure

### Phase 2: Chamber window and architecture

- build new chamber window
- implement trust-bound open/close behavior
- add left sidebar, content area, and right detail pane
- implement first-open auto slide on session start

### Phase 3: V1 item model and interactions

- implement `Secrets`, `Notes`, `Documents`
- add add/edit/delete
- add reveal/copy/preview behavior
- add search, favorites, recent

### Phase 4: Cleanup and polish

- trust-state-focused header
- chamber animation polish
- history integration
- clipboard and temporary export cleanup behavior

---

## Success Criteria

The chamber is successful when all of these are true:

- the app no longer feels like Preferences dressed up as a product
- a new user can understand what the chamber is in under a minute
- trust start creates a clear, satisfying chamber-open moment
- closing the chamber while trusted feels intentional, not broken
- trust end reliably closes/locks the chamber
- the user can store and access protected items without thinking about implementation details
- old managed-session work is preserved without polluting the new identity

---

## Immediate Decision

Use this plan as the implementation baseline instead of following `mac_secret_chamber_ui_spec.md` verbatim.

What to borrow from the earlier spec:
- name
- dark matte visual direction
- protected item model
- add-item simplicity
- detail-pane concept

What to replace:
- top tabs
- full-width top-half layout
- countdown-centric header
- timed reveal as the default interaction model
- visible v2 categories

