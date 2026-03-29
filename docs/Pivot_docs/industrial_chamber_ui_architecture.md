# Secret Chamber v1 — Industrial Terminal Architecture

> Status: Approved UI/UX Direction
> Concept: "Successive Floating Panels" (Spatial / Miller Column approach) combined with an industrial, mono-spaced, ASCII-accented terminal aesthetic.

---

## 1. Core Architecture: The Disjointed Panels

Instead of one monolithic fixed-size window, the Secret Chamber is composed of up to **three separate `NSPanel` / `NSWindow` instances** that float on the desktop and spawn right-to-left. 

They do not share a background. The macOS desktop (or underlying user workspace) is visible *between* and *around* them.

### The Flow:
1. **Level 1 (The Spine):** Trust starts → The thin vertical Nav Bar appears.
2. **Level 2 (The List):** User clicks "Secrets" → The `Secrets List Panel` spawns physically attached to the right edge of the Spine.
3. **Level 3 (The Detail):** User clicks a specific secret → The `Detail Panel` spawns physically attached to the right edge of the List Panel.

```
┌──────┐ ┌────────────────────┐ ┌────────────────────┐
│      │ │ ╔ SECRETS ╗        │ │ ╔ API_KEY_PROD ╗   │
│ ⌕    │ │                    │ │                    │
│ ◈    │ │ [SECRET]           │ │ •••••••••••••••••  │
│ ⊛ ←──│─│─▶ api_key_prod   ─ │─│─▶ [ Reveal ]       │
│ ⊟    │ │                    │ │   [ Copy ]         │
│ ⊞    │ │ [SECRET]           │ │                    │
│      │ │   github_token     │ │                    │
│ ◇    │ │                    │ │                    │
│      │ └────────────────────┘ └────────────────────┘
│ [●]  │
│ ▓▒░  │
└──────┘
 Level 1        Level 2                 Level 3
 (Spine)        (List)                  (Detail)
```

### Window Behavior Rules
- **Non-Activating Panels:** All three should ideally be `NSPanel` with `.nonactivatingPanel` set so they don't steal key focus from the user's terminal/editor unless explicitly typing in a search box.
- **Snapping:** Level 2's `x` coordinate = Level 1's `maxX + spacing (e.g., 14px)`. They move together logically.
- **Auto-Dismissal:** If the user clicks `All` on Level 1, the existing Level 2 window is swapped, and Level 3 is closed.
- **Total Teardown:** When trust ends, all open panels dissolve/close simultaneously.

---

## 2. Visual Aesthetic: Industrial Terminal

The visual language moves away from standard macOS HIG and into a "cyberdeck" / bare-metal terminal feel. 

### Typography
- **Primary Font:** `IBM Plex Mono` (or macOS native `SF Mono` / `Menlo`).
- **Hierarchy:** Rely on all-caps, brackets, and ASCII borders rather than heavy font weights.
  - Headers: `╔ SECRETS ╗`
  - Separators: `── SEARCH CHAMBER ──`

### Color Palette
- **Backgrounds:** Pure black `#000000` or ultra-dark `#080808`. No gradients, no blur/vibrancy.
- **Borders:** `#1C1C1C` for panel borders. `#2A2A2A` for hover states. 1px solid, sharp.
- **Text:** 
  - Primary text: `#D8D8D8`
  - Secondary metadata/noise: `#555555` to `#333333`
- **Ferrofluid / Symbiote Accent:** No bright colors. Represented via ASCII block characters (`▓▒░`) and a single pulsing trust dot.

### The "Noise" Background (Optional but recommended)
The HTML mockup includes a `fluid-bg` layer of random ASCII characters (`░▒▓▒░ ∿∾≋`) rendered very faintly (`#111`) behind the text. This gives the empty space a physical, textured, "magnetic fluid" feel without needing heavy graphics. 

---

## 3. Component Specs

### Level 1: The Nav Spine
- **Width:** `52px` fixed.
- **Height:** Flexible, roughly `400px - 500px`.
- **Contents:**
  - Search icon (`⌕`)
  - Separator lines
  - Category icons (`[ * ] All`, `[ S ] Secrets`, `[ N ] Notes`, `[ D ] Docs`, `[ ★ ] Favs`)
  - **Bottom anchor:** The trust indicator. A pulsing circle (`[●]`) + ASCII liquid blocks (`▓▒░`) + App version string (`v1.0`).

### Level 2: The Content List
- **Width:** `320px` fixed.
- **Header:** ASCII title + Subtitle + `[+ NEW]` button.
- **Cards:**
  - 1px border (`#161616`).
  - Hover state lightens the border to `#2A2A2A`.
  - Content: Category tag (`• SECRET`), Title, 1-2 lines of preview, metadata.

### Level 3: The Detail & Add Window
- **Width:** `320px` to `400px` fixed.
- **Purpose:** Used for reading a Note, revealing/copying a Secret, or the form to Add a new item.
- **Actions:** Buttons are styled as raw text brackets e.g., `[ REVEAL ]` `[ COPY ]`

---

## 4. Why This Works (UX Advantages)

1. **Zero Wasted Space:** A monolithic window forces empty space. This spatial model only puts pixels on the screen for what the user is actively doing.
2. **True Coexistence:** Because the desktop sits between the panels, it feels like a transparent layer *over* the user's work rather than a wall blocking it.
3. **Copy-Paste Optimized:** The user can keep the Spine and the List open on the left side of their screen, keeping the right side totally free for their Terminal or IDE.
4. **Strong Identity:** It entirely escapes the "looks like macOS System Preferences" trap. It looks like a high-end, secretive developer tool. 

---

## 5. Implementation Steps for Engineer

1. **Window Management:** Create a robust controller that manages 3 `NSWindow` / `NSPanel` instances. 
2. **Positioning Logic:** 
   - Panel 1 (Spine) is dragged/placed by the user (or spawns center-left).
   - Panel 2 observers Panel 1's frame and dynamically anchors to `Panel1.maxX + 14`.
   - Panel 3 anchors to `Panel2.maxX + 14`.
3. **Styling Override:** Strip all native macOS window chrome (`.titlebarAppearsTransparent = true`, `.titleVisibility = .hidden`, `.styleMask = [.borderless]`).
4. **Custom Drawing:** Implement the 1px `#1C1C1C` border and `6px` corner radius via a custom NSView or SwiftUI `.overlay(RoundedRectangle())`.
