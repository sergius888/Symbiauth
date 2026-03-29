# Secret Chamber Progress Log

## Purpose

This document records the transition from the earlier managed-session / DevOps-oriented macOS utility into the current `Secret Chamber` product direction.

It is meant to answer:

- what was changed
- which files were changed
- what the current Secret Chamber UI does
- how the current chamber window is structured
- what is implemented versus what is still rough

## Current Product Shape

The current macOS product is no longer centered on launchers, tunnels, or a generic preferences utility.

It is now centered on:

- a trust-gated private workspace called `Secret Chamber`
- revealed only while iPhone trust is active
- closed immediately when trust ends
- intended to hold and expose protected local content under chamber control

The current v1 chamber content types are:

- `Secrets`
- `Notes`
- `Documents`

The chamber is opened automatically on trust start, can be manually dismissed while trust remains active, and can be reopened from the menu bar while trusted.

## Main Files Changed

### macOS app

- [AppDelegate.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/AppDelegate.swift)

This is the main implementation file for:

- menu bar shell
- trust lifecycle handling
- Preferences shell
- Secret Chamber window controller
- Secret Chamber SwiftUI workspace
- chamber data model and local persistence

### agent backend

- [bridge.rs](/Users/cmbosys/Work/Armadilo/apps/agent-macos/src/bridge.rs)
- [secrets.rs](/Users/cmbosys/Work/Armadilo/apps/agent-macos/src/secrets.rs)

These backend changes enabled trust-gated secret reads for chamber reveal/copy behavior.

## Progress by Slice

### 1. Product shell pivot

The old macOS top-level identity was changed away from:

- Diagnostics
- Sessions
- Secrets
- Settings

and replaced with:

- Chamber
- History
- Session
- Settings

This was the first step in making the app read like a chamber product instead of an operator control panel.

### 2. Chamber window lifecycle

The chamber stopped being just a tab concept inside Preferences and became its own window/panel.

Implemented:

- dedicated `SecretChamberWindowController`
- trust-driven auto-open on session start
- manual close remembered for the current trust session
- reopen from menu bar while trusted
- immediate close when trust ends

### 3. Chamber data model and persistence

The current chamber content model was added inside [AppDelegate.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/AppDelegate.swift):

- `ChamberCategory`
- `ChamberStoredKind`
- `ChamberStoredItem`
- `ChamberDraft`
- `ChamberItem`

Notes and documents are chamber-owned data persisted locally.

That persistence is encrypted at rest using:

- local symmetric key stored in Keychain
- AES.GCM for the chamber persistence files

Current chamber persistence files:

- `~/.armadillo/chamber_items.json`
- `~/.armadillo/chamber_metadata.json`

The metadata file stores presentation-state metadata such as:

- favorite secret names
- recent secret access timestamps

### 4. Trust-gated secret reveal

The Rust backend was extended to support trust-gated secret reads.

Implemented:

- backend route: `secret.get`
- chamber secret reveal
- chamber secret copy
- reveal state cleared when trust ends

This allows the chamber to show real secrets from the existing local SymbiAuth secret path instead of only placeholder rows.

### 5. Notes and documents

The chamber now supports:

- creating notes
- editing notes
- importing documents
- temporary document export

Document export behavior was changed so that it is chamber-owned and trust-bound:

- export goes to a temporary chamber export directory
- file is surfaced in Finder
- export file is removed when trust ends

### 6. Cleanup on trust end

When trust ends, the chamber now clears:

- revealed secrets
- protected clipboard content
- temporary export files
- chamber editor sheet

This makes the chamber behave like a temporary private workspace instead of a normal always-open document UI.

### 7. Legacy UI cleanup

The old inactive UI/views were removed from the active macOS path:

- old launcher helpers from the menu path
- old secrets menu helpers
- `LaunchersTabView`
- `SecretsTabView`
- old placeholder tab code

Managed sessions were not deleted conceptually, but they were removed from the active product shell and parked for later reference.

### 8. Chamber design pass

The chamber UI was redesigned from a plain utility layout into a more intentional private-space layout.

Implemented:

- stronger chamber header
- chamber metrics row
- clearer trust-state badges
- more intentional left navigation
- richer category intro copy
- category-specific cards for secrets / notes / documents
- stronger detail pane styling

### 9. Chamber interaction pass

Implemented:

- real `Favorites` and `Recent` behavior
- inline note editing in the detail pane
- favorite toggling for secrets and chamber-owned items
- recent tracking for both stored items and secrets

### 10. Trust heartbeat refresh fixes

The trust proof cadence was causing visible chamber refresh/blink behavior.

The known fixes already applied:

- trust-state notifications no longer trigger a full `viewModel.refresh()`
- `refreshTrustStateOnly()` was added to avoid re-fetching unrelated data on each proof tick
- if the chamber is already visible for the current trust session, the lifecycle path no longer re-opens or re-animates it
- `showChamber()` no longer performs a full refresh when the chamber is already visible

This area still needs live behavior validation because proof/heartbeat behavior can still cause visible UI disturbance if any part of the chamber is invalidating too aggressively.

## Current Secret Chamber UI Structure

The current chamber window is implemented in:

- `SecretChamberWorkspaceView`

### Window behavior

The chamber window is:

- a floating panel
- not fullscreen
- large enough to feel like a dedicated workspace
- auto-opened at session start
- manually closable during an active session
- closed immediately when trust ends

### Overall layout

The chamber window is structured into 3 vertical regions:

1. left sidebar
2. center content area
3. right detail pane

Above those 3 regions there is a chamber header and status strip.

### Header

The current header contains:

- chamber title
- trust-dependent descriptive copy
- search field
- `Clipboard Armed` badge when relevant
- trust-state badge
- metrics row

Current metrics shown:

- visible surface state
- secret count
- note count
- document count

### Sidebar

The left sidebar contains navigation and chamber context.

Current sections:

- All
- Secrets
- Notes
- Documents
- Favorites
- Recent

It also includes a `Session` explanation block and a `Current Focus` explanation block.

### Center content area

The center area shows:

- current category title
- short category intro text
- `Add Item` menu
- empty state or item grid

The grid is currently card-based and category-aware:

- secret cards
- note cards
- document cards

### Right detail pane

The detail pane shows:

- selected item badge
- title
- optional note
- item-specific content
- tags
- created date
- actions

Current item-specific actions:

- secret: reveal / copy / favorite / edit / delete
- note: inline edit / save / cancel / copy / favorite / delete
- document: temporary export / favorite / edit / delete

## How the Current UI Was Built

The current UI was built in stages rather than as one clean rewrite.

### Stage 1

Replace the old shell first:

- remove `Launchers` / `Secrets` from the top-level product identity
- make `Chamber` the first-class surface

### Stage 2

Create the chamber as a real panel:

- not a tab-only concept
- not another preferences subsection

### Stage 3

Build real chamber content:

- secret reveal
- local notes
- local documents

### Stage 4

Add cleanup semantics:

- trust-end close
- clipboard clear
- export clear
- reveal clear

### Stage 5

Refine structure and appearance:

- stronger header
- sidebar navigation
- category-specific cards
- detail pane styling

### Stage 6

Add interaction polish:

- favorites
- recents
- inline note editing

So the current UI is the result of:

- preserving the working trust/session substrate
- replacing the old product shell
- layering chamber-specific structure on top
- then removing more legacy UI once the new path was stable

## What Is Working Now

Current working behavior:

- chamber auto-opens on trust start
- chamber closes on trust end
- secrets can be revealed and copied
- notes can be added and edited
- notes now support inline editing in the detail pane
- documents can be imported
- documents can be exported temporarily
- exported files are removed when trust ends
- chamber-owned content is encrypted at rest
- favorites and recents now have actual behavior

## What Is Still Rough

These areas are still not final:

- the chamber still lives inside an oversized `AppDelegate.swift`
- some transitions may still feel too reactive to trust proof updates
- in-context editing is only done for note body right now, not for all metadata
- item creation still relies on a sheet
- visual polish is stronger than before, but not final-quality product design yet
- images / recovery content types are still intentionally out of scope

## Build / Verification State

The chamber work has been repeatedly verified with:

- `cargo check --manifest-path apps/agent-macos/Cargo.toml --bin agent-macos`
- `xcodebuild -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj -scheme ArmadilloTLS -configuration Debug -derivedDataPath apps/tls-terminator-macos/build build`

Current known remaining warning in the macOS build:

- unrelated Xcode App Intents metadata warning

## Practical Reading of the Current UI

The current Secret Chamber UI should be understood as:

- already a real product surface
- no longer a placeholder
- structurally coherent
- functionally usable
- still open to UX correction and refinement

It is no longer the earlier mediocre utility/preferences experience, but it is also not yet the final polished chamber experience.

## Next Review Questions

Before the next implementation pass, the useful review questions are:

- does the chamber still visibly react to every proof refresh
- does the auto-open / manual close / reopen behavior feel right
- does inline note editing feel good enough to keep
- should item creation stay sheet-based or move more in-context
- what should be changed in the visual hierarchy before adding any new content type
