# Execution Plan: Managed Sessions Pivot

This document breaks down the product direction from `managed_sessions_product_direction.md` into concrete, executable slices.

## Slice 1: The Lexicon & Primary Template
**Goal:** Align the user-facing language and default configuration with the "Managed Tunnel" product truth. No rust structural changes needed, just mapping UI semantics and defaults.

### Tasks:
- [ ] **macOS UI Renaming:** Update `AppDelegate.swift`, menubar strings, and Preferences window.
  - "Launchers" tab → "Managed Sessions" 
  - "Trusted Actions" → "Managed Tunnels"
  - "Run Launcher" → "Establish Hardware Link" (or "Start Session")
- [ ] **iOS UI Renaming:** Update terminology in `HubView`, `SessionView`, and `LogsView`.
  - "Trust Session" → "Proximity Link"
  - "Active Proofs" → "Hardware Link Status"
- [ ] **Default Configuration:** Create the first-class `Local Port Forward` template.
  - Add to the default template list returned by Rust (`launcher_template.list`).
  - Pre-fill `exec_path`: `/usr/bin/ssh`
  - Pre-fill `args`: `["-N", "-L", "15432:localhost:5432", "user@dev-host"]`
  - Pre-fill `trust_policy`: `Continuous`

---

## Slice 2: The Proof of Concept (Logs & Visibility)
**Goal:** Ensure the Logs immediately explain the value proposition when a tunnel is killed by roaming out of range. 

### Tasks:
- [ ] **Log Terminology:** Ensure the iOS `LogsView` explicitly uses "Managed Tunnel Terminated" when a continuous process is killed upon trust loss.
- [ ] **Error/State Formatting:** Make sure failure states (e.g., SSH fails to connect or tunnel process crashes early) are cleanly surfaced in the macOS diagnostic tab and iOS logs.
- [ ] **Local Persistence (Optional for Slice 2, required for production):** Write recent logs to a local SQLite or JSON file on iOS so that if the app is background-killed, the historical context survives.

---

## Slice 3: The Ferrofluid UI/UX Pass (Aesthetic Polish)
**Goal:** Bring the visual architecture up to the "Mission Critical Hardware Tool" tier we defined, centering the entire iOS app around the single Managed Session interaction.

### Tasks:
- [ ] Implement the iOS Tab Bar architecture (Home, Macs, Logs, Settings).
- [ ] Build the "Flight Instrument" data grid for the Home tab.
- [ ] Implement the High-Contrast (White/Matte Grey/Black Fluid) aesthetic tokens.
- [ ] Build the `.metal` Shader-backed Ferrofluid "Establish Link" button.

---

## Acceptance Criteria for Slice 1:
- User pairs app, opens macOS preferences, and goes to "Managed Sessions".
- User clicks "Add from Template" and selects "Local Port Forward".
- The resulting workflow makes immediate sense in the context of securing a dev tunnel.
