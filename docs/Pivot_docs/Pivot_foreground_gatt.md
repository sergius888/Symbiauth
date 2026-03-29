> ⚠️ **PARTIALLY SUPERSEDED** — This doc is a good **narrative/history** of why we pivoted.
> However, the technical details (HMAC verification, TTL model, UDS messages, Face ID caching)
> are outdated. For the canonical spec, see
> [`v1_product_spec_states.md`](docs/Pivot_docs/v1_product_spec_states.md).
>
> **Key corrections:** (1) HMAC is verified by **Rust**, not Mac Swift. Swift is transport only.
> (2) TTL is optional — we have 3 trust modes (Strict/Background TTL/Office). (3) Face ID is
> required every time the app opens, no session caching. (4) Mode/TTL selection is on the Mac, not iPhone.

---

# SymbiAuth Pivot Narrative: Foreground Trust + BLE GATT (Plan A)

**Date:** March 2026
**Status:** Approved direction for v1

## 1) What this project was trying to do

We originally aimed for “phone in pocket unlocks Mac automatically” using iPhone BLE advertising (first service-data, then iBeacon). The Mac would detect the phone’s presence via BLE and unlock/keep a vault unlocked.

That goal looks simple, but it hits a hard platform constraint:

### iOS constraint (the wall we hit)

**iPhone BLE advertising is not reliable in background/lock.**
We tested this extensively: the app can *think* it is advertising, logs can still print, but the Mac stops receiving packets once the app backgrounds/locks. This is policy/OS behavior, not our bug.

So “ambient proximity unlock” using iPhone advertising is not a stable foundation for a real product.

## 2) The decision: embrace “foreground-only” as a feature

We pivot to a model that is:

* **predictable**
* **secure**
* **shippable**

### New v1 rule

**Trust exists only when the iPhone app is foreground and Face ID has been approved for the session.**

If the app leaves foreground (background/lock/app switch), the phone stops participating, and the Mac’s trust lease **expires automatically** by TTL.

This is intentional. It turns iOS constraints into a safety property:

> “No ambient unlock. No pocket unlock. No silent unlock.”

## 3) What we are building now (v1)

A **foreground-gated trust session** used for short, high-trust workflows (2–10 minutes):

* User opens iPhone app → Face ID → “Start Session”
* iPhone becomes “trust authority”
* Mac becomes “resource gatekeeper”
* Trust is granted temporarily (TTL), then **auto-revoked with cleanup**

No cloud, no Wi-Fi/TLS dependency for trust proof.

## 4) Why the previous BLE approach is not enough (security)

Before pivot, the iPhone was broadcasting a token (iBeacon major/minor derived from an HMAC bucket). This is “broadcast-only.”

Broadcast-only has two issues:

1. It can be recorded and replayed within a short window.
2. It does not allow the Mac to ask a fresh question (“prove it now”)—no challenge-response.

### New security baseline

We need **interactive challenge–response**, which requires a BLE connection (GATT).

## 5) New technical plan (Plan A)

We keep the “iPhone advertises” direction, but we stop using iBeacon.

### Old: iBeacon-only (remove)

* iPhone: CLBeaconRegion → manufacturer payload advertising
* Mac: scans iBeacon packets + validates token

### New: BLE Service UUID + GATT (implement)

* iPhone: **BLE peripheral (GATT server)** advertising a **Service UUID**
* Mac: **BLE central** scans for that service UUID, connects, sends challenges, verifies proofs

#### Challenge–response

* Mac generates random `nonce16`
* iPhone replies `HMAC(k_shared, "PROOF" || nonce16 || corr_id || phone_fp || ttl)`
* Mac verifies → grants trust lease (TTL)

This kills replay/spoofing without relying on Wi-Fi/TLS.

## 6) What stays the same

We keep the “big rocks” already built:

* **Pairing identity** and device fingerprint handling
* **Vault/policy/cleanup model** in Rust
* **TTL-based revocation** as the primary safety mechanism
* Menubar UI concept and UDS message routing concept

We are changing *how trust is established*, not the whole product.

## 7) What changes (explicitly)

### Remove / de-prioritize

* iBeacon-based BLE advertiser and Mac iBeacon scanner logic as the trust primitive
* Any attempt to make iPhone advertising work locked/background for “pocket unlock”

### Add

* iPhone GATT peripheral service with two characteristics:

  * `challenge` (Mac → iPhone)
  * `proof` (iPhone → Mac)
* Mac BLE central implementation that:

  * scans for service UUID
  * connects
  * exchanges challenge/proof
  * sets `trust_until`
* Foreground session gating on iPhone:

  * On app active → Face ID required for session
  * On app background/inactive → stop BLE/GATT participation

## 8) Intended UX (so dev builds the right thing)

* iPhone has a **Start Session** button + TTL choice
* Face ID happens once per foreground session (banking style)
* While foreground session is active: Mac can grant/renew trust
* If user backgrounds the app: the trust will naturally expire on Mac

This is not a “presence detector.” It’s “explicit trust sessions.”

## 9) Trust + cleanup semantics (v1)

* Mac treats trust as a **lease**: `trust_until = now + ttl`
* When trust expires or user ends session:

  * unmount DMGs
  * kill tracked processes
  * clear sensitive temp state
  * update UI to Locked

We do not try to perfectly detect “left the room.” TTL + cleanup is the safety boundary.

## 10) Dev implementation guidance (practical)

### Where to implement “Mac BLE central”

**Recommended:** implement BLE central in the **Swift macOS app** (menubar / terminator side) and send:

* `trust.granted(until, ttl, phone_fp)`
* `trust.revoked(reason)`
  to the Rust agent over UDS.

Rationale: CoreBluetooth is native in Swift; doing it in Rust via objc bindings is doable but slower and flakier.

### UUID naming

We will use one “service UUID” constant:

* `SYMBIAUTH_V1_SERVICE_UUID`

(We can reuse the same UUID value previously used for beacon UUID, but it is now a *service* identifier.)

## 11) Definition of done for the pivot

* iPhone foreground session + Face ID → Mac can establish trust via GATT challenge–response in <10s
* Background/lock stops iPhone participation and trust expires via TTL
* Trust expiry triggers cleanup reliably every time
* Logs show clear events: `challenge.send`, `proof.ok`, `trust.granted`, `trust.revoked`

---

## 12) Why this pivot is the right move

Because it is the smallest change that makes the project:

* technically feasible under iOS constraints
* more secure (challenge–response)
* shippable with predictable UX
* aligned with real “burst” workflows

This is not a compromise; it’s the first version that can be made reliable.

---

