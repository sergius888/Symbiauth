# SymbiAuth Beta PMF Direction

## Summary
SymbiAuth currently has a credible product hypothesis, not proven product-market fit.

The strongest beta wedge is:
- phone-keyed managed tunnels for DevOps / SRE / infrastructure users on macOS

Plain-English narrative:
- start a managed tunnel or long-running session on the Mac
- require iPhone trust before it can run
- terminate continuous sessions when trust ends

This is the current beta story to validate. It is intentionally narrower than the broader "phone trust for everything" narrative explored earlier.

## What The Product Is
SymbiAuth is a paired iPhone + macOS system that:
- establishes a trusted session between phone and Mac
- lets the Mac run configured managed sessions
- gates those sessions on active trust
- can terminate continuous managed sessions when trust ends
- records recent trust/session history

It is not:
- a general-purpose sandbox
- a replacement for Keychain
- protection for processes it did not start
- malware-proof secret storage
- a complete security layer for the whole Mac

## Beta Hypothesis
The best current hypothesis is:

> DevOps / SRE users who open sensitive local tunnels or access sessions may want the iPhone to act as the live possession key for those sessions.

Why this is plausible:
- the current implementation already fits managed process control
- tunnels and port-forwards are process-bounded and understandable
- the history surface can explain why a session ended

Why this is still only a hypothesis:
- we have not yet validated sustained real-world usage
- we have not yet proven users prefer this over their current hygiene
- we have not yet proven willingness to install, trust, and keep using it

## Target Beta Users
Primary target:
- mid/senior DevOps engineers
- SREs
- platform / infrastructure engineers
- security-conscious consultants using Mac laptops

Good fit:
- users who run non-interactive local tunnels, port-forwards, and long-running access sessions
- users who care about the lifecycle of those sessions after launch

Poor fit:
- general consumers
- people looking for a password manager
- users expecting a general Mac hardening tool
- workflows that depend on interactive shells or prompts

## Current Core Workflow
Beta workflow to validate:

1. User pairs iPhone with Mac.
2. User starts a trusted hardware link from iPhone.
3. User runs a managed tunnel/session from the Mac menu bar or Preferences.
4. Session stays alive while trust remains active.
5. User manually ends trust or trusted presence is lost.
6. Continuous managed session is terminated.
7. History shows that the session ended because trust ended.

The product promise is narrow:
- SymbiAuth only governs sessions it starts
- continuous sessions may be terminated when trust ends

## MVP Templates
The MVP should ship only the lowest-risk, clearest templates.

### 1. SSH Port Forward
Primary template.

Purpose:
- start a local SSH port-forward as a managed session

Requirements:
- must be fully non-interactive
- must fail fast if forwarding cannot be established
- must not rely on password prompts

Example command shape:

```bash
ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -N -L 15432:db.internal:5432 bastion.company.com
```

Notes:
- if a secret is used for `-i`, the implementation must distinguish between a file path and raw key material
- this template is only valid if the underlying SSH auth already works unattended

### 2. kubectl port-forward
Second template.

Purpose:
- expose a Kubernetes service locally while trust is active

Example command shape:

```bash
kubectl port-forward svc/myapp 8080:80 -n prod
```

Requirements:
- kube config and auth must already be valid non-interactively
- user should understand that the local forwarded port disappears when trust ends

### 3. Generic Long-Running Script
Low-risk third template.

Purpose:
- run a deterministic long-running script or command that should stop when trust ends

Examples:
- maintenance script
- local automation
- long-running helper process

This template is safer for beta than machine-wide networking changes.

## What We Are Explicitly Not Shipping In MVP
Not in the first beta:
- Tailscale / ZeroTier machine-wide state mutation templates
- interactive shell templates as a headline workflow
- claims about full-machine protection
- claims about stopping malware
- enterprise / Slack / compliance features
- pricing/ARR assumptions presented as facts

## UX / Copy Guardrails
All product copy should stay within these boundaries:

Use:
- managed sessions
- managed tunnels
- hardware link
- trust must be active before launch
- continuous sessions terminate when trust ends
- non-interactive commands only

Avoid:
- "protects your whole Mac"
- "zero traces"
- "malware-proof"
- "commercial gold"
- "walk away and everything is safe" as a blanket claim

## Beta Safety / Risk Posture
Reasonable product stance:
- local-first reduces cloud/data-handling exposure
- but the product still launches commands, injects secrets, and kills processes
- users can break their own workflow with bad configs

Therefore beta posture must include:
- explicit "test with non-production targets first" guidance
- explicit "non-interactive only" guidance
- explicit "continuous sessions terminate when trust ends" warning
- no exaggerated security claims
- visible history/logs so users can understand why a session ended

## Validation Plan
This is a beta validation plan, not proof of PMF.

Validation goals:
- do target users understand the product in one sentence
- can they configure a real managed tunnel successfully
- do they use it repeatedly
- do they say it solves a real operational problem

Suggested early channels:
- small DevOps communities
- trusted operator/SRE contacts
- limited beta outreach with direct feedback collection

Suggested success signals:
- users can complete setup without hand-holding
- users run sessions repeatedly in a week
- users say the termination/history behavior is useful, not just interesting

Suggested failure signals:
- users are confused about when/why sessions end
- users do not have non-interactive tunnel workflows
- users say normal screen locking is sufficient
- users cannot map SymbiAuth to a real job in their day

## Current Decision
Proceed with:
- DevOps / SRE managed tunnels as the beta wedge
- SSH port forward + kubectl port-forward + generic script as MVP templates
- disciplined beta validation

Do not proceed with:
- broad security positioning
- pricing or market-size certainty
- legal-confidence language beyond clear disclaimers and scope boundaries
