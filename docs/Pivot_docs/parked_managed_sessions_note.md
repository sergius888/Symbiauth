# Parked Feature Note: Managed Sessions / DevOps Surface

> Status: parked, not deleted
> Reason: useful engineering work exists, but it no longer matches the primary v1 chamber product

---

## What Exists Today

The project already includes a real managed-session capability on macOS:
- non-interactive command/session definitions
- trust-gated launch behavior
- continuous session termination on trust end
- template support
- local event history around session start/stop/termination

This work is real and should not be treated as throwaway.

---

## Why It Is Parked

It is parked because the current product focus changed.

Primary reasons:
- iPhone foreground trust makes long-lived workflows less central
- the founder cannot validate the DevOps workflow firsthand
- the chamber workspace is a clearer v1 product
- keeping managed sessions first-class in the UI makes the app feel like an operator console instead of a coherent chamber product

So the decision is not:
- "managed sessions were fake"

The decision is:
- "managed sessions are not the primary v1 product surface"

---

## What To Preserve

- backend/runtime logic
- template definitions
- trust-based process termination logic
- related documentation
- event history ideas that remain generally useful

---

## What To Remove From Primary UX

- top-level tab prominence
- chamber-adjacent onboarding
- tunnel-first product copy
- session templates in the main path

---

## Conditions For Revival

Managed sessions should only return to the main product when at least one of these becomes true:

- a strong user demand appears for trust-gated command execution
- a clearer short-duration managed-session use case emerges
- the team decides to ship it as an advanced or experimental mode
- a separate product branch is created around that capability

Until then, it stays parked.

---

## Code Handling Rule

Unless it blocks the chamber build:
- do not delete the code
- do not keep expanding the UI
- keep it understandable and recoverable

This is the professional middle ground between:
- ripping out useful work
- and letting old work dictate the new product

