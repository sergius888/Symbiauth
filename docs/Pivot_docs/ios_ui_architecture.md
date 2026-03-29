# SymbiAuth iOS — UI Architecture & Screen Map

**Purpose:** Establish clear UI structure **before** coding, so every new feature has a defined home.
**Current state:** Chaotic — everything lives in one 292-line `ContentView.swift`, dev buttons mixed with user features, no navigation structure.

---

## Current Screen Audit

### What exists today (3 screens, 3 Swift files)

| Screen | File | Screenshot | Problems |
|--------|------|------------|----------|
| **Landing / Mac List** | `ContentView.swift` → `PairingView` | Screenshot 1 | Title says "Armadillo Mobile MVP Testing App". Status message is dev-facing. Toggles (Auto-connect, BLE presence) are exposed to users with no explanation. |
| **Connected View** | `ContentView.swift` → `ConnectedView` | Screenshot 3 | Dev buttons everywhere: Ping Test, Vault Test, Write/Read/Delete/Seed bank cred, Prox Intent/Pause/Status, Generate Phrase, Rekey. "Disconnect" label is misleading — it navigates back, doesn't disconnect BLE. No session/trust UI. |
| **Settings** | `SettingsView.swift` | Screenshot 2 | Duplicate of Landing's Mac list. Dev toggles mixed with user settings. "Forget endpoint" is destructive with no confirmation. |

### Structural problems

1. **No navigation architecture** — `ContentView` uses an `if/else` on connection state. No `NavigationStack`, no proper routing.
2. **One file, two views** — `PairingView` and `ConnectedView` are both inside `ContentView.swift` (292 lines). No separation.
3. **Dev UI mixed with user UI** — Ping Test, Vault Test, Rekey, Prox Intent are all visible. `devMode` toggle only guards a subset.
4. **Duplicate Mac list** — appears on both Landing and Settings with slightly different layouts.
5. **No session/trust screen** — the core feature (Start Session → Face ID → Trusted) has no dedicated screen.
6. **"Disconnect" mislabeled** — navigates to Landing but BLE stays alive. Should be "Back" or the navigation pattern should handle this.
7. **No visual hierarchy** — flat VStack of buttons, no cards, no sections, no breathing room.
8. **Duplicate pairings** — same Mac appears multiple times from re-scanning QR. No dedup in `PairedMacStore`.

---

## Proposed Screen Hierarchy (v1)

```
┌──────────────────────────────────────────────────────┐
│                   App Launch                          │
│            (check paired macs count)                  │
└───────────┬──────────────────────┬────────────────────┘
            │                      │
     0 macs paired           ≥1 mac paired
            │                      │
            ▼                      ▼
┌─────────────────┐    ┌──────────────────────────────┐
│  Onboarding /   │    │      Hub Screen               │
│  First Pair     │    │  (your "Landing page")        │
│                 │    │                                │
│  "Scan QR to    │    │  ┌──────────────────────────┐ │
│   pair your     │    │  │  Active Mac Card          │ │
│   first Mac"    │    │  │  ┌─────────────────────┐  │ │
│                 │    │  │  │ SecureShield-A66E    │  │ │
│  [Scan QR]      │    │  │  │ Status: Idle         │  │ │
│                 │    │  │  │ ● On / ○ Off toggle  │  │ │
│                 │    │  │  │                       │  │ │
│                 │    │  │  │ [Start Session]       │  │ │
│                 │    │  │  └─────────────────────┘  │ │
│                 │    │  └──────────────────────────┘ │
│                 │    │                                │
│                 │    │  Other paired Macs (collapsed) │
│                 │    │  ┌ Legacy Mac          ── Off ┐│
│                 │    │  └────────────────────────────┘│
│                 │    │                                │
│                 │    │  [+ Add Mac]            [⚙]   │
│                 │    └──────────────────────────────┘ │
└─────────────────┘                                     │
                                                         │
                       ┌─────────────────────────────────┘
                       │  tap "Start Session"
                       ▼
              ┌─────────────────────────┐
              │   Face ID Gate          │
              │   (system biometric)    │
              └──────────┬──────────────┘
                         │ success
                         ▼
              ┌─────────────────────────────────┐
              │      Session Screen              │
              │                                  │
              │   Status: Trusted ✓              │
              │   Mode: Background TTL (5 min)   │
              │                                  │
              │   ┌─────────────────────────┐    │
              │   │  Symbiotic visual area  │    │
              │   │  (future: ferrofluid)   │    │
              │   │  (now: simple pulse)    │    │
              │   └─────────────────────────┘    │
              │                                  │
              │   Signal: Present ●              │
              │   Connected since: 2:34 ago      │
              │                                  │
              │   [End Session]                   │
              │                                  │
              └─────────────────────────────────┘
```

---

## Screen Definitions (v1)

### Screen 1: Hub (Landing)

**Purpose:** The home screen. Shows your paired Macs and lets you start a trust session.

| Element | Behavior |
|---------|----------|
| **Active Mac card** | Shows the currently selected Mac (sticky selection). Large card with name, fingerprint snippet, connection toggle (On/Off), status indicator. |
| **Start Session button** | Only visible when Mac's toggle is On. Triggers Face ID → starts BLE GATT advertising → enters Session Screen. |
| **Other Macs** | Collapsed list of other paired Macs. Tap to switch active Mac (with confirmation). Swipe to remove. |
| **+ Add Mac** | Opens QR scanner (existing flow). After scan, new Mac appears in list. |
| **⚙ Settings gear** | Pushes to Settings screen. |

**What this replaces:** Current `PairingView` in `ContentView.swift`.

**Key UX rule:** The hub is always accessible. Going "back" from Session Screen returns here. BLE state doesn't change on navigation — only a user action (End Session / toggle Off) changes BLE.

---

### Screen 2: Session (Trust Active)

**Purpose:** The "you are live" screen. Shown while a trust session is active.

| Element | Behavior |
|---------|----------|
| **Status badge** | Large: "Trusted ✓" (green) / "Signal Lost" (amber) / "Revoking…" (red) |
| **Mode indicator** | "Strict" / "Background TTL: 4:32" / "Office Mode" |
| **Visual area** | v1: simple animated pulse/glow tied to signal state. Future: ferrofluid-inspired reactive animation. |
| **Signal indicator** | "Present ●" / "Lost ○" with last-seen timestamp |
| **Connection info** | Mac name, session duration, trust mode |
| **End Session** | Prominent destructive button. Immediately sends `trust.revoke`, stops GATT, returns to Hub. |

**Navigation:** Presented modally over Hub (or as a full-screen push). Cannot navigate away without ending session (app backgrounding auto-revokes by design). "Back" = End Session with confirmation dialog.

**What this replaces:** The connected state portion of current `ConnectedView` — but without the dev buttons.

---

### Screen 3: Settings

**Purpose:** App-level settings and Mac management.

| Section | Contents |
|---------|----------|
| **Paired Macs** | Same data as Hub's list but with full management: rename, set active, remove (with confirmation), show fingerprint. |
| **Appearance** | Theme toggle (future: symbiotic/clean), haptics on/off |
| **Advanced** | HMAC freshness timeout, notification preferences |
| **Developer** (hidden by default) | Toggled via "tap version 7 times" pattern. Contains: JSON logs, Redact sensitive data, Ping Test, Vault Test, Prox tools, Rekey tools, Forget endpoint, Copy recovery phrase. **All current dev buttons move here.** |
| **About** | Version, build, licenses |

**What this replaces:** Current `SettingsView.swift` — but dev section is **hidden by default** behind a discovery gesture.

---

### Screen 4: QR Scanner (existing — keep)

**Purpose:** Scan Mac's QR code for initial pairing.

No changes needed to this flow. It remains a sheet presented from Hub.

---

### Screen 5: Onboarding (new — v1.1)

**Purpose:** First-run experience when no Macs are paired.

Simple: branded splash → "Scan your first Mac" → QR scanner → Hub.

Not blocking for v1; current "No Macs paired yet" empty state is adequate to start.

---

## Navigation Architecture

```
NavigationStack {
    HubView                          // root
        → .sheet: QRScannerView      // add Mac
        → .navigationDestination: SettingsView
        → .fullScreenCover: SessionView   // trust session (modal)
}
```

**Why `fullScreenCover` for Session:**
- User shouldn't accidentally swipe-dismiss a trust session.
- Background/foreground transitions are the exit path (by iOS design).
- Clear visual separation: "you are in a session" vs "you are configuring."

---

## Proposed File Structure

```
Features/
├── Hub/
│   ├── HubView.swift              // Landing screen with active Mac card
│   ├── MacCardView.swift          // Reusable Mac card component
│   └── MacListView.swift          // Collapsed list of other Macs
│
├── Session/
│   ├── SessionView.swift          // Trust session screen
│   ├── SessionViewModel.swift     // Session state, BLE/GATT coordination
│   ├── TrustStatusView.swift      // Status badge + mode + signal
│   └── PulseAnimationView.swift   // Animated visual (v1: pulse, future: ferrofluid)
│
├── Pairing/
│   ├── QRScannerView.swift        // Keep existing
│   ├── QRPayload.swift            // Keep existing
│   ├── PairingViewModel.swift     // Refactor: remove session & dev logic
│   └── FaceIDAuthenticator.swift  // Keep existing
│
├── Settings/
│   ├── SettingsView.swift         // Rebuilt: clean sections
│   ├── PairedMacManagementView.swift  // Full Mac management
│   └── DeveloperView.swift        // All dev tools, hidden by default
│
├── BLE/
│   └── BLETrustServer.swift       // NEW: GATT peripheral (from implementation plan)
│
└── Common/
    ├── SymbiAuthTheme.swift        // Colors, fonts, animations, spacing
    └── StatusBadgeView.swift       // Reusable status indicator
```

---

## What Moves Where (Migration Map)

| Current location | Current purpose | New location |
|-----------------|----------------|--------------|
| `ContentView.swift` → `PairingView` | Landing + Mac list + toggles | `HubView.swift` |
| `ContentView.swift` → `ConnectedView` (top half) | Connection status | `SessionView.swift` |
| `ContentView.swift` → `ConnectedView` (dev buttons) | Ping, Vault, Write/Read/Delete, Prox tools | `DeveloperView.swift` (hidden) |
| `ContentView.swift` → `ConnectedView` (Rekey section) | Generate Phrase, Start/Commit/Abort Rekey | `DeveloperView.swift` (hidden) |
| `ContentView.swift` → "Disconnect" button | Navigate back (misleads — doesn't disconnect) | Remove. Use NavigationStack back / "End Session" |
| `PairedMacListView.swift` | Small Mac list | `MacListView.swift` + `MacCardView.swift` |
| `SettingsView.swift` | Settings + duplicate mac list + dev toggles | `SettingsView.swift` (rebuilt) + `DeveloperView.swift` |
| Auto-connect / BLE presence toggles | User-facing toggles on Landing | Move to Settings (confusing on Landing page) |

---

## Naming Fixes (Immediate)

| Current | Problem | New label |
|---------|---------|-----------|
| "Disconnect" | Doesn't disconnect, just navigates back | "End Session" (if ending) or ← back button (if just navigating) |
| "Armadillo Mobile" | Wrong brand name | "SymbiAuth" |
| "MVP Testing App" | Dev-facing subtitle | Remove (or "v1" if you want a version badge) |
| "Connection closed" | Ambiguous — closed by whom? | "Idle — no active session" |
| "Auto-connect paused (59s)" | Dev-facing auto-reconnect message | Move to Developer section / hide from normal users |
| "Set Active" | Unclear what "active" means | "Use this Mac" |
| "Forget endpoint" | Dev jargon | "Forget all pairing data" (with confirmation) |
| "BLE presence (Phase 1)" | Dev-facing toggle | Hide in Developer section |

---

## Visual Direction Notes (for later)

The user envisions a **symbiotic/ferrofluid** aesthetic:
- Dark theme with deep blacks and iridescent accents
- A central animated element (like ferrofluid responding to magnetic fields) that reacts to BLE signal strength / trust state
- Minimalist cyberpunk: few elements, lots of negative space, each element has weight
- The animation is the hero — UI elements are secondary

**v1 placeholder:** A simple glowing pulse circle on the Session Screen that:
- Breathes slowly when Trusted + signal present (calm, green/teal)
- Pulses faster with amber tones when signal is lost
- Flatlines (static, dim red) when revoking/locked

This is trivially replaceable with the ferrofluid shader later without touching any logic.

---

## What NOT to build yet (scope guard)

| Feature | Why not now |
|---------|------------|
| Ferrofluid animation | Needs Metal shader / SceneKit. Build after backend works. |
| Onboarding flow | "No Macs paired" empty state is fine for v1. |
| Wi-Fi sharing shortcut | Great idea (noted in `random-ideas-forfuture.md`). v1.1. |
| Widget trust status | Widget extension already exists but needs backend first. |
| Theme customization | Single dark theme for v1. |
| Mac-side pairing duplicate dedup | Backend fix in `PairedMacStore`, not UI. Flag for cleanup pass. |
