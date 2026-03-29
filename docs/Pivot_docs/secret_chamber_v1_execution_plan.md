# Secret Chamber V1 Execution Plan

> Purpose: translate the v1 chamber direction into implementation slices for the existing macOS/iOS codebase
> Scope: execution order, acceptance criteria, and transition rules

---

## Why This Plan Exists

The current app shell still reflects previous product phases:
- diagnostics-first thinking
- managed sessions / DevOps tunnel surfaces
- a `Secrets` tab that behaves like support configuration instead of the product

If we start coding the chamber without restructuring the app shell first, we will recreate the same problem:
- useful capabilities
- mediocre product shape
- no coherent hierarchy

So the chamber needs to be built in slices, with a clear rule:

**the product shell changes first, then the chamber surface, then the content interactions.**

---

## Codebase Areas Affected

### Primary macOS surface

- [AppDelegate.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/AppDelegate.swift)

This file currently contains:
- menu bar setup
- app menu construction
- the current tabbed Preferences shell
- managed session views
- secrets editor views
- settings
- session history views

This means the chamber transition will require both:
- structural UI rework
- careful preservation of existing transport/trust/runtime logic

### Supporting trust/runtime layers

- [TLSServer.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/TLSServer.swift)
- BLE and transport files under [ArmadilloTLS](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS)

These should not be redesigned casually as part of the chamber UI pass.
They already carry the core trust state we need.

---

## Implementation Principles

- chamber-first UX, not Preferences-first UX
- preserve old work unless it blocks progress
- hide/demote old product surfaces before deleting anything
- only build visible v1 features
- do not expose future categories as disabled placeholders
- keep `Strict` as the default trust mode
- preserve advanced modes in settings, behind advanced framing

---

## Slice 1: App Shell Reset

### Goal

Stop presenting the product as a tabbed utility app.

### Changes

- remove the current `PreferencesRootView` as the main conceptual shell
- introduce a new chamber-centered root structure
- reduce top-level surfaces to:
  - `Secret Chamber`
  - `History`
  - `Session`
  - `Settings`
- make `Secret Chamber` the default primary surface

### What should happen to old tabs

- `Diagnostics`
  - demote into `Session` or `History`
  - keep useful technical information, but do not give it top billing

- `Sessions` / `Managed Sessions`
  - remove from primary navigation
  - preserve code and models
  - move behind a parked/experimental access point later if needed

- `Secrets`
  - stop treating it as a config list
  - evolve it into the chamber content model

### Acceptance criteria

- opening the app no longer looks like an operator console
- the chamber is visually and structurally the primary feature
- old surfaces are no longer defining the product identity

---

## Slice 2: Chamber Window Lifecycle

### Goal

Introduce the actual chamber behavior tied to trust state.

### Changes

- add a dedicated chamber window/panel
- first trust activation in a session auto-opens the chamber with animation
- if the user closes it while trust remains active, the chamber stays available but hidden
- menu bar can reopen it while trust is active
- trust end immediately closes/locks it

### Important behavior rules

- auto-open only once per trust session
- do not keep forcing the chamber back on screen after manual dismissal
- do not auto-open when there is no trust

### Acceptance criteria

- trust start creates a distinct chamber-open moment
- manual close does not end trust
- trust end closes the chamber every time

---

## Slice 3: Chamber Information Architecture

### Goal

Replace top tabs with a stable workspace layout.

### Layout

- left sidebar:
  - `All`
  - `Secrets`
  - `Notes`
  - `Documents`
  - `Favorites`
  - `Recent`

- main content area:
  - grid of protected items
  - search results
  - empty states

- right detail pane:
  - selected item preview
  - metadata
  - actions

### Acceptance criteria

- categories have a permanent, predictable place
- the chamber feels like a workspace, not filtered tabs
- details are visible without pushing users through constant modal churn

---

## Slice 4: V1 Content Model

### Goal

Implement only the real v1 content categories.

### V1 categories

- `Secrets`
- `Notes`
- `Documents`

### Explicitly not in v1 UI

- `Images`
- `Recovery`
- `Wallets`
- `Signing`

### Add flow

User-facing inputs only:
- type
- title
- content or choose file
- optional note
- optional tags

### Acceptance criteria

- adding an item does not feel like filling a database schema
- all three categories behave coherently in the same chamber
- no disabled/dead v2 categories appear in the main UI

---

## Slice 5: Trust-Bound Interactions

### Goal

Make chamber actions align with trust reality.

### Behavior

- secrets reveal while trust remains active
- copy works while trust remains active
- notes are readable/editable while trust remains active
- documents preview/export while trust remains active
- trust end:
  - relocks text content
  - closes previews
  - clears protected clipboard best-effort
  - revokes/removes temporary exported files where possible

### Do not implement in this slice

- one-paste clipboard tracking
- cursor indicators
- arbitrary micro-timers as the main behavior model

### Acceptance criteria

- trust state visibly governs chamber access
- content does not linger after trust ends
- the product feels coherent without relying on gimmicky timers

---

## Slice 6: History and Session Surfaces

### Goal

Retain useful transparency without making diagnostics the product.

### History should cover

- trust started
- trust ended
- chamber opened
- chamber closed
- item revealed
- item copied
- document exported
- clipboard cleared

### Session surface should cover

- current trust state
- paired device context
- active trust mode
- advanced mode warnings

### Acceptance criteria

- users can understand what happened after the fact
- technical state exists, but does not dominate the product

---

## Slice 7: Settings Cleanup

### Goal

Keep settings real and minimal.

### Keep

- trust mode
- background TTL / office settings as advanced options
- chamber behavior options later if needed

### Remove from primary emphasis

- DevOps template guidance
- managed-session-first language
- old tunnel beta messaging

### Acceptance criteria

- settings feel advanced, not like the main app
- `Strict` is clearly the default recommendation

---

## Parking Policy For Old Managed Session / DevOps Work

### Preserve

- runtime models
- backend logic
- templates
- docs
- event history logic that is still generally useful

### Remove from main product identity

- first-class nav exposure
- prominent managed-session messaging
- tunnel-first onboarding

### Professional rule

Do not delete the feature set just because the product focus changed.

Instead:
- document it as parked
- keep it buildable if possible
- isolate it from the chamber-first product shell

---

## Recommended Build Order

1. App shell reset
2. Chamber window lifecycle
3. Chamber layout
4. V1 categories and item model
5. Trust-bound interactions
6. History/session cleanup
7. Settings cleanup

This order matters.

If we start by adding chamber content into the current shell, the structure will remain mediocre even if the visuals improve.

---

## Immediate Next Coding Slice

The next coding slice should be:

**replace the current tabbed Preferences root with a chamber-first shell placeholder**

That means:
- keep the existing runtime/view-model plumbing
- stop showing `Diagnostics / Sessions / Secrets / Settings` as the main identity
- introduce the chamber as the primary destination

This is the correct first implementation move because it fixes the product hierarchy before we polish the chamber details.

