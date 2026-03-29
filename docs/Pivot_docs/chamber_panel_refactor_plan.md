# Chamber Panel Refactor Plan

## Why This Refactor Is Needed

The current Secret Chamber works, but its panel lifecycle is too fragile.

We have repeatedly hit bugs where:
- the visible panel state did not match the chamber state
- a category looked closed in the spine but the old panel remained on screen
- search/category windows interfered with each other
- trust-proof refreshes could accidentally reactivate the chamber
- Trusted Shell changes broke unrelated chamber behavior

The root problem is not only UI polish. It is structural:
- `AppDelegate.swift` owns too many responsibilities
- panel state and panel window lifecycle are mixed together
- SwiftUI state and imperative `NSPanel` operations are entangled

This plan is to separate those responsibilities before more Trusted Shell work.

## Refactor Goal

Make chamber window behavior explicit and deterministic.

After refactor:
- the chamber should have one clear second-panel state
- the chamber should have one clear third-panel state
- panels should only appear because of those explicit states
- panel show/hide/attach/detach logic should live in one place
- Trusted Shell should stop being able to destabilize search/category behavior

## What We Will Not Change During Refactor

This is a structural pass, not a redesign pass.

Do not change:
- visual theme
- chamber categories
- item data model
- secret/note/document functionality
- Trusted Shell feature scope

Only change:
- code organization
- explicit panel/window state modeling
- panel lifecycle wiring

## Target Architecture

### 1. AppDelegate responsibility

Keep `AppDelegate.swift` responsible only for:
- app lifecycle
- trust lifecycle
- menu bar / high-level actions
- creating the chamber coordinator

It should stop containing:
- chamber views
- chamber panel orchestration details
- most chamber interaction state

### 2. Chamber coordinator

Create a dedicated coordinator/controller layer for chamber panels.

Suggested file:
- `apps/tls-terminator-macos/ArmadilloTLS/Chamber/SecretChamberCoordinator.swift`

This coordinator should own:
- spine panel
- second panel
- third panel
- window positions
- attach/detach rules
- show/hide rules

### 3. Explicit panel state

Define explicit panel state enums.

Suggested:

```swift
enum ChamberSecondPanelState: Equatable {
    case none
    case category(ChamberCategory)
    case search
}

enum ChamberThirdPanelState: Equatable {
    case none
    case detail(itemID: String)
    case editor(kind: ChamberStoredKind)
    case filter
}
```

The coordinator should derive visible windows only from these states.

### 4. Chamber view model

Move chamber state out of `AppDelegate.swift` into a dedicated view model.

Suggested file:
- `apps/tls-terminator-macos/ArmadilloTLS/Chamber/ChamberViewModel.swift`

This should own:
- chamber categories
- selected item
- search text
- filter state
- favorites state
- reveal/copy state
- draft/editor state
- Trusted Shell state

But it should **not** directly manage `NSPanel` window lifecycle.

### 5. Chamber views

Split chamber views into separate files.

Suggested files:
- `ChamberSpineView.swift`
- `ChamberListPanelView.swift`
- `ChamberSearchPanelView.swift`
- `ChamberDetailPanelView.swift`
- `ChamberFilterPanelView.swift`
- `TrustedShellPanelView.swift`

The second and third panel surfaces should become easy to swap without changing window code.

## Refactor Sequence

### Phase 1: Extract models and view model

Move out of `AppDelegate.swift`:
- `ChamberCategory`
- `ChamberItem`
- `ChamberDraft`
- chamber metadata helpers
- chamber-only state and actions

Result:
- chamber logic can compile without touching window code yet

### Phase 2: Extract views

Move SwiftUI chamber views into dedicated files:
- spine
- list
- search
- detail
- filter
- trusted shell

Behavior should remain the same.

Result:
- `AppDelegate.swift` loses most UI weight

### Phase 3: Replace ad hoc panel logic with explicit second/third panel state

In the coordinator:
- introduce `ChamberSecondPanelState`
- introduce `ChamberThirdPanelState`
- remove ad hoc combinations of:
  - `chamberPanelCategory`
  - `chamberSearchVisible`
  - `showingChamberEditor`
  - `selectedChamberItemId`
  where they currently imply window state indirectly

Result:
- one source of truth for visible panel slots

### Phase 4: Centralize show/hide/attach/detach

Move all window operations into coordinator methods:
- `showSpine()`
- `hideSpine()`
- `showSecondPanel(for:)`
- `hideSecondPanel()`
- `showThirdPanel(for:)`
- `hideThirdPanel()`
- `positionPanels()`

No other code should directly manipulate panel visibility.

Result:
- no more random visual mismatch between state and panel visibility

### Phase 5: Revisit Trusted Shell after stabilization

Only after the panel refactor:
- reintroduce a proper large-shell mode
- decide whether it stays as the second panel or becomes a dedicated shell window
- continue `chamber inject`

## Immediate Success Criteria

The refactor is successful when all of these are true:

- start session -> spine only
- click category -> second panel opens
- click same category again -> second panel closes
- click search -> search replaces category panel
- close search -> second panel disappears
- selecting an item opens third panel only when appropriate
- no stale windows survive after close/hide
- no chamber refocus on 12-second proof refresh
- shell changes do not break category/search behavior

## Current Status

As of 2026-03-24, the core structural refactor has been completed far enough to resume product work safely.

Completed:
- `AppDelegate.swift` reduced to app shell responsibilities
- menu bar support extracted
- native messaging support extracted
- chamber views extracted
- chamber window controller extracted
- `PreferencesViewModel` split into:
  - `PreferencesViewModel.swift`
  - `PreferencesViewModel+Chamber.swift`
  - `PreferencesViewModel+Operations.swift`

Current result:
- chamber behavior is no longer buried inside `AppDelegate.swift`
- non-chamber operational logic is isolated from chamber-specific behavior
- future Trusted Shell / chamber work can proceed with materially lower risk of cross-feature regressions

Still true:
- chamber panel state is healthier, but not yet a formal state-machine architecture
- `PreferencesViewModel+Chamber.swift` remains the main future hotspot if chamber complexity grows again

Reference:
- use `docs/Pivot_docs/macos_chamber_file_map.md` as the live ownership map before changing macOS chamber code

## Non-Goals For This Refactor

Do not add during this pass:
- new chamber categories
- new Trusted Shell capabilities
- new visual redesign
- new animation experiments

This pass is about reliability first.

## Recommended First Implementation Slice

The first slice should be:

1. create `ChamberViewModel.swift`
2. move chamber models/state there
3. create `SecretChamberCoordinator.swift`
4. move panel lifecycle methods there
5. leave `AppDelegate.swift` calling into that coordinator

That is the cleanest point to begin.
