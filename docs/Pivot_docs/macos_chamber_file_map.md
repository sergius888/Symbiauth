# macOS Chamber File Map

Last updated: 2026-03-24

This document is the working map for the macOS `ArmadilloTLS` app after the Secret Chamber refactor.

It exists for one reason:
- future changes should start from the correct file instead of guessing or re-expanding monolithic files

## Main App Shell

### [AppDelegate.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/AppDelegate.swift)
Purpose:
- app lifecycle
- startup / shutdown
- core service initialization
- top-level object ownership

Owns:
- `CertificateManager`
- `BonjourService`
- `TLSServer`
- `EnrollmentServer`
- shared controller/view-model references

Should not grow back into:
- chamber UI
- chamber panel orchestration
- large view-model logic

### [AppDelegate+MenuBar.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/AppDelegate+MenuBar.swift)
Purpose:
- menu bar construction
- trust mode menu
- preferences/chamber open actions
- trust-change reactions coming from the app shell

Owns:
- status menu rendering
- chamber auto-open / auto-close lifecycle bridge
- preference window and chamber window creation helpers

### [AppDelegate+NativeMessaging.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/AppDelegate+NativeMessaging.swift)
Purpose:
- browser native messaging manifest install/remove support

Owns:
- Chrome native host manifest generation
- extension ID resolution
- manifest file placement/removal

## Chamber Models / Views / Windowing

### [Chamber/ChamberModels.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/ChamberModels.swift)
Purpose:
- shared chamber data structures

Owns:
- `ChamberCategory`
- `ChamberStoredKind`
- `ChamberStoredItem`
- `ChamberDraft`
- `ChamberItem`
- `SecretPresentationConfiguration`
- `ChamberPresentationMetadata`

### [Chamber/ChamberTheme.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/ChamberTheme.swift)
Purpose:
- shared industrial/terminal chamber styling primitives

### [Chamber/ChamberSpineView.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/ChamberSpineView.swift)
Purpose:
- left spine navigation

Owns:
- `[/]`
- `[S]`
- `[N]`
- `[D]`
- `[>_]`
- `[★]`

### [Chamber/ChamberListViews.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/ChamberListViews.swift)
Purpose:
- second-panel list/search surfaces

Owns:
- category list panels
- search results panel
- item row/card presentation used in list mode

### [Chamber/ChamberDetailViews.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/ChamberDetailViews.swift)
Purpose:
- third-panel detail/editor/filter surfaces

Owns:
- secret detail
- note detail/editing
- document detail/preview
- filter panel
- metadata block rendering

### [Chamber/TrustedShellPanelView.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/TrustedShellPanelView.swift)
Purpose:
- Trusted Shell UI surface

Owns:
- shell setup panel
- shell live transcript surface
- shell controls only

Does not own:
- PTY/process lifecycle logic

### [Chamber/ChamberWindowController.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/ChamberWindowController.swift)
Purpose:
- floating chamber window/panel orchestration

Owns:
- spine window
- second panel
- third panel
- panel positioning / hide / show / attach behavior

This is the main file to inspect first when:
- a panel stays visible when it should be hidden
- a panel opens in the wrong place
- dragging causes detachment/drift

### [Chamber/ChamberHomeViews.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/ChamberHomeViews.swift)
Purpose:
- top-level chamber shell composition

### [Chamber/PreferencesShellViews.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/PreferencesShellViews.swift)
Purpose:
- preferences tabs/surfaces still used by the macOS app shell

### [Chamber/LegacyChamberWorkspaceView.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/LegacyChamberWorkspaceView.swift)
Purpose:
- preserved older chamber workspace implementation

Status:
- not the active industrial chamber path
- kept as reference/legacy code only

## Preferences / Chamber View Model Layer

### [PreferencesViewModel.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/PreferencesViewModel.swift)
Purpose:
- root observable object state
- shared published properties
- lightweight coordination helpers

Think of this as:
- the state hub

Not:
- the place to put all behavior forever

### [PreferencesViewModel+Chamber.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/PreferencesViewModel+Chamber.swift)
Purpose:
- Secret Chamber behavior
- Trusted Shell behavior
- chamber persistence
- chamber clipboard/export cleanup

Owns:
- chamber item derivation
- category/search/filter behavior
- reveal/copy/export
- note/document handling
- chamber metadata persistence
- trusted shell open/close/input/transcript handling

This is the first file to inspect when:
- chamber interaction breaks
- filter/search behavior breaks
- reveal/copy behavior breaks
- trusted shell session behavior breaks

### [PreferencesViewModel+Operations.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/PreferencesViewModel+Operations.swift)
Purpose:
- non-chamber operational logic

Owns:
- trust refresh/status
- launcher refresh/template/save/delete/run
- trust settings load/save
- secret backend CRUD/test
- history persistence
- operational error formatting

This is the first file to inspect when:
- launcher/session behavior breaks
- trust settings stop saving
- Keychain-backed secret backend behavior breaks

### [PreferencesWindowController.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/PreferencesWindowController.swift)
Purpose:
- normal Preferences window host

Owns:
- `PreferencesRootView` hosting window
- refresh/activation behavior for preferences

## Practical Change Guide

If you need to change...

### Chamber panel open/close/position/drag behavior
Start with:
- [ChamberWindowController.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/ChamberWindowController.swift)
- [AppDelegate+MenuBar.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/AppDelegate+MenuBar.swift)

### Chamber categories / list / search / filter
Start with:
- [PreferencesViewModel+Chamber.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/PreferencesViewModel+Chamber.swift)
- [ChamberListViews.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/ChamberListViews.swift)

### Chamber detail / editor / metadata / preview
Start with:
- [ChamberDetailViews.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/ChamberDetailViews.swift)
- [PreferencesViewModel+Chamber.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/PreferencesViewModel+Chamber.swift)

### Trusted Shell
Start with:
- [TrustedShellPanelView.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/Chamber/TrustedShellPanelView.swift)
- [PreferencesViewModel+Chamber.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/PreferencesViewModel+Chamber.swift)

### Menu bar / trust mode / chamber auto-open
Start with:
- [AppDelegate+MenuBar.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/AppDelegate+MenuBar.swift)

### Trust settings / launcher operations / secret backend CRUD
Start with:
- [PreferencesViewModel+Operations.swift](/Users/cmbosys/Work/Armadilo/apps/tls-terminator-macos/ArmadilloTLS/PreferencesViewModel+Operations.swift)

## Remaining Structural Debt

Still not perfect:
- `PreferencesViewModel+Chamber.swift` is still large
- chamber panel lifecycle is better isolated, but not yet a fully formal state machine
- Trusted Shell is still an early implementation, not a finished terminal subsystem

But the current structure is now healthy enough to resume product work without piling everything back into one file.
