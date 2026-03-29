# SymbiAuth Product Direction: Managed Sessions

## Purpose

This document locks the current product direction so implementation, copy, UI, and roadmap decisions stop drifting.

SymbiAuth is not a general security tool, not a vault replacement, and not a generic "proximity auth" product.

SymbiAuth is a presence-bound kill switch for sensitive local access sessions on macOS.

In plain language:

- SymbiAuth starts a managed sensitive process.
- It keeps that process alive only while phone-presence trust is active.
- If trust ends, SymbiAuth terminates that managed process.

## Primary User

Build first for:

- infrastructure engineers
- DevOps / SRE operators
- platform engineers
- security-conscious consultants

These users open temporary high-trust access paths on their Mac and do not want those paths left alive when they step away.

Do not optimize first for:

- general consumers
- crypto as a primary audience
- generic secret-manager users
- vague "AI agent security" users

## Core Job To Be Done

The product must solve one clear job:

"If I forget to shut down sensitive access, shut it down for me."

This is the center of the product. Everything else is secondary.

## Official Narrative

Short version:

"Sensitive access should not stay open when you walk away."

Expanded version:

- screen locks and Keychain help, but they do not automatically shut down already-running sensitive access paths
- SymbiAuth manages those access paths and can terminate them when physical trust is lost

Best one-line pitch:

"A dead man's switch for sensitive tunnels and admin sessions."

## What SymbiAuth Is

SymbiAuth is:

- a managed-process control layer
- a trust-gated execution path
- a runtime kill switch for sensitive local access sessions

## What SymbiAuth Is Not

SymbiAuth is not:

- a password manager
- a Keychain replacement
- a vault-first product
- a generic Mac locker
- a malware-proof secret system
- a product that protects arbitrary apps it did not start

## Current Technical Boundary

The honest product boundary must remain explicit:

- SymbiAuth only manages processes it starts
- trust-gated execution applies to managed sessions launched through SymbiAuth
- `continuous` managed sessions can be terminated on trust loss
- `start_only` managed sessions are intentionally preserved
- secrets may be injected from Keychain for managed workflows

Do not claim more than this.

## First Wedge

The first wedge is not "launchers" as a generic concept.

The first wedge is:

- Managed Tunnel

This means a user-facing workflow centered on sensitive temporary access paths such as:

- SSH local port forwards
- SSH dynamic proxies
- Kubernetes port-forwards
- similar process-bounded access sessions

## First Workflow To Ship

Ship one excellent workflow first:

- Managed Tunnel via SSH local port forward

Reference example:

```bash
ssh -N -L 15432:localhost:5432 user@dev-host
```

Why this workflow:

- simple mental model
- common enough to be credible
- clear kill semantics
- low ambiguity
- not vendor-specific
- testable without a production environment

## User-Facing Terminology

Use:

- Managed Sessions
- Managed Tunnel
- Hardware Link
- Proximity Link Active
- Session terminated by trust policy
- Ended because you left trusted range

Avoid:

- Launcher
- Trust proof
- BLE
- cryptographic jargon in primary UX copy
- vague "secure everything" language

## Core UX Copy Direction

Home:

- Title: `SYMBIAUTH`
- Supporting line: `Sensitive access stays open only while you are near.`
- Primary action: `Establish Hardware Link`

Managed Sessions screen:

- Header: `Managed Sessions`
- Supporting line: `Start tunnels and privileged sessions that terminate when trust ends.`

Session screen:

- `Proximity Link Active`
- `Managed sessions will terminate if the link is lost.`

Logs screen:

- `Session History`
- `Review what happened after a session ended.`

## Secrets Positioning

Secrets are a supporting feature, not the wedge.

Honest value:

- avoid plaintext secrets in local repos for managed workflows
- avoid `.env`-style accidental exposure in simple cases
- inject secrets only when launching a managed session

Do not market this as:

- malware-proof local secret security
- a replacement for established secret-management products

Correct hierarchy:

- primary story: managed sensitive processes die when trust ends
- secondary story: those managed processes can receive secrets without plaintext `.env` files

## First Template Spec

Template name:

- Local Port Forward

Template description:

- Open a local SSH tunnel that stays alive only while your hardware link is active.

Fields:

- Name
- SSH host
- SSH user
- Local port
- Remote host
- Remote port
- Optional identity file path
- Optional secret refs

Generated command shape:

```bash
ssh -N -L <local_port>:<remote_host>:<remote_port> <user>@<host>
```

## Acceptance Criteria For The First Real Workflow

The first workflow is only complete when all of the following are true:

1. A user can create a managed tunnel without editing YAML manually.
2. The tunnel cannot start unless trust is active.
3. The tunnel starts and is visibly marked as running.
4. Trust loss terminates the managed tunnel automatically.
5. Logs clearly show:
   - session started
   - trust granted
   - managed tunnel started
   - signal lost or manual end
   - managed tunnel terminated
6. Failure states are understandable to a user.
7. No copy implies that SymbiAuth protects processes it did not start.

## Testing Strategy

Start with the safest possible proof path.

Layer 1: harmless process-control proof

- use a benign long-running managed process to validate start, trust loss, and termination behavior

Layer 2: real managed-tunnel proof

- use a dev-only SSH local port forward
- not production
- not sensitive data

Pass conditions:

- start works
- trust gate works
- trust loss kills process within expected timeout
- logs explain what happened clearly

## Near-Term Build Order

1. Rename user-facing `Launcher` language to `Managed Session` or `Managed Tunnel` where appropriate.
2. Add a first-class `Local Port Forward` template.
3. Tighten logs around managed-session start, stop, and trust-loss termination.
4. Make the macOS UX clearly revolve around managed sessions rather than generic launcher machinery.
5. Add local log persistence after the event model and workflow are proven cleanly.

## What Not To Build Yet

Do not prioritize these items before the first managed-tunnel workflow is solid:

- broad secret-manager positioning
- deleting major subsystems only because the narrative changed
- crypto-first positioning
- AI-agent positioning
- multiple templates before one excellent template exists
- storage/persistence work before the core workflow is proven
- broad marketing claims about securing the whole Mac

## Honest Claims

Safe claims:

- SymbiAuth manages sensitive local access sessions.
- It can terminate managed continuous sessions when trust is lost.
- It reduces plaintext secret exposure in managed workflows.

Unsafe claims:

- SymbiAuth secures the whole Mac.
- SymbiAuth prevents malware from stealing secrets.
- SymbiAuth replaces Keychain.
- SymbiAuth protects processes it did not start.

## Roadmap Framing

Phase 1:

- make one managed-tunnel workflow excellent
- make logs prove the value
- tighten product copy around managed sessions

Phase 2:

- validate with safe dev-only tunnel scenarios
- improve predictability and operational clarity

Phase 3:

- add local log persistence
- improve macOS/iOS consistency around managed sessions
- add one adjacent workflow only after the tunnel story is proven

Later, if earned by usage:

- expand into adjacent managed-session categories such as privileged scripts or local AI agents with real system access

## Decision Lock

Until new evidence appears, the official product direction is:

SymbiAuth is a presence-bound kill switch for sensitive local access sessions on macOS, with Managed Tunnel as the first wedge and primary workflow.
