# iOS SymbiAuth Home Screen - Ferrofluid Redesign

This document outlines the structural layout for the iOS app redesign, focusing on the centralized ferrofluid action button, the removal of scrollable cards, and robust handling of long data fields.

## Core Principles
1. **Zero Scroll:** Everything fits on a single screen viewport.
2. **Central Focus:** The primary interaction (Start/End Session) commands the center.
3. **Flight Instrument Data:** Supportive data is compressed into a rigid, non-breaking grid below the action point.
4. **Bottom Navigation:** Secondary flows (Mac list, Logs, Settings) are moved to dedicated tabs.

---

## Layout Structure (ASCII Mockup)

```text
┌──────────────────────────────────────────┐
│                                          │
│  SYMBIAUTH                               │
│                                          │
│           SECURE NODE ACCESS             │
│   INDUSTRIAL CYBERSECURITY TOOL          │
│                                          │
│                                          │
│──────────────────────────────────────────│
│                                          │
│                                          │
│            .──────────.                  │
│          /~   fluid    ~\                │
│         |     START      |               │
│         |    SESSION     |               │
│          \~   button   ~/                │
│            '──────────'                  │
│                                          │
│                                          │
│──────────────────────────────────────────│
│                                          │
│  STATUS                  SESSION         │
│  Active (Strict)         02:14:09        │
│                                          │
│  DATA LINK               ACTIVE NODE     │
│  Reconnecting            Development Wo… │
│                                          │
│──────────────────────────────────────────│
│                                          │
│  [⎈]        [💻]        [≡]        [⚙️]  │
│  HOME       MACS       LOGS      SETTINGS│
└──────────────────────────────────────────┘
```

## Component Breakdown

### 1. Header (Top)
- **App Name:** `SYMBIAUTH` replaces placeholder text.
- **Icon Removed:** The generic cloud account `[👤]` icon is removed to enforce the zero-trust, local-hardware feel.
- **Subtitles:** Plain, industrial descriptions setting the tone.

### 2. Primary Action Area (Center)
- **Ferrofluid Button:** Takes up significant vertical space. Changes state between "START SESSION" (calm fluid) and "END SESSION" (active/expanded fluid).

### 3. Data Readout Grid (Bottom Section)
This uses the "Solution A" approach discussed previously. It's a structured 2x2 grid that prevents layout breakage on long names.
- **Left Column:** System states (`STATUS` and `DATA LINK`).
- **Right Column:** Contextual identifiers (`SESSION` duration/age and `ACTIVE NODE` name).
- **Truncation Safety:** If the Mac name (`ACTIVE NODE`) is excessively long ("Development Workstation Alpha"), it truncates gracefully with an ellipsis (`…`) within its half-width cell, preventing it from pushing other elements off-screen or wrapping awkwardly.

### 4. Tab Bar (Footer)
- **HOME:** The main session screen (this mockup).
- **MACS:** Replaces the inline "Active Mac" card. Includes the full list of paired devices and the "Add New Mac" flow.
- **LOGS:** A dedicated view for detailed connection/trust event logs, keeping the Home screen clean.
- **SETTINGS:** The deep configuration view (dev toggles, forget endpoint).

---

## The Ferrofluid Action Button Implementation

To achieve the premium, physical feel of the liquid metal button and the full-screen transition, we use extreme contrast and native iOS Metal shaders.

### 1. The Color Palette (Extreme Contrast)
The aesthetic relies entirely on matte vs. glossy contrast rather than complex colors.
- **App Background:** A textured, matte **Light Grey** (e.g., `#F2F2F7` or `#E5E5EA`).
- **Cards/Panels:** Stark **White** (`#FFFFFF`) with zero shadow and sharp corners.
- **The Fluid (The Button):** Pitch **Black** (`#000000`) with high-gloss modifiers.

*Why:* Placing white geometric shapes on a light grey background creates a clean, architectural canvas. The pitch-black glossy fluid sits in the middle, drawing the eye completely.

### 2. The SwiftUI + Metal Architecture

The animated button is constructed in three layers:

**Layer A: The Glossy Black Base**
- A standard SwiftUI `Circle()` filled with `Color.black`.
- Applied modifiers: `.innerShadow` (a semi-transparent white curve at top left for reflection) and a harsh, tight `.shadow` to give it physical weight on the canvas.

**Layer B: The Metal Shader (The "Spikes")**
- Using iOS 17's native shader modifiers (`.distortionEffect`), a `.metal` shader file is applied to the circle.
- The shader uses Simplex Noise driven by time (`startDate.timeIntervalSinceNow`) to continuously distort the perfect circular edge, pushing it outward into slow, heavy, undulating spikes—like a magnet interacting with ferrofluid.

**Layer C: The Press & Transition**
- Wrapped in a custom `ButtonStyle` or `onLongPressGesture`.
- **On Press Down:** An `energy` variable is passed to the shader, escalating the speed and sharpness of the spikes, making it physically react to touch.
- **On Release (Session Start):** The button expands using a massive `.scaleEffect` (or `.matchedGeometryEffect`), blowing up the black spiky liquid until it completely engulfs the screen, turning the entire app background pitch black. The "TRUSTED SESSION" readouts then fade in (in pure white) over the new dark void.

*Performance:* Because the shader uses Metal, the fluid animation calculation runs entirely on the GPU at 120fps, costing virtually zero CPU and preserving battery life for the background trust operations.
