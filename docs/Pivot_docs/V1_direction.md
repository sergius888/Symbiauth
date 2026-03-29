> ⚠️ **PARTIALLY SUPERSEDED** — The Mac state machine, trust modes, UDS protocol, and timing/policy
> sections in this doc are outdated. The canonical spec is
> `docs/Pivot_docs/v1_product_spec_states.md`.
>
> **Still valid here:** The iPhone state machine (IOS_IDLE / IOS_AUTHED_FOREGROUND / IOS_REVOKED),
> iPhone transitions (T1–T3), and iPhone log formats.

---

---

# SymbiAuth v1 State Machine (Foreground Session)

## Entities

* **iPhone app**: biometric gate + BLE peripheral (GATT server)
* **Mac app**: BLE central + trust timer + UI
* **Rust agent**: executes actions; receives `trust.granted/revoked`

---

## iPhone state machine

### States

1. **IOS_IDLE**

* Not advertising, not responding to GATT.
* `sessionAuthorized = false`

2. **IOS_AUTHED_FOREGROUND**

* App is foreground and Face ID succeeded
* BLE advertising ON, GATT service ON

3. **IOS_REVOKED**

* Session ended (user tapped End) or app left foreground (background/lock)
* BLE OFF, GATT OFF, `sessionAuthorized = false`

### Transitions

**T1: User taps "Start Session" (while app is active/foreground)**

* Face ID prompt
* On success → IOS_AUTHED_FOREGROUND (start BLE + GATT)

**T2: App becomes inactive/background**

* → IOS_REVOKED (stop BLE immediately)

**T3: User taps “End Session”**

* → IOS_REVOKED

### iPhone logs (print exactly these)

* `[ios] session.start faceid=prompt`
* `[ios] session.start faceid=ok`
* `[ios] session.start faceid=fail reason=<...>`
* `[ios] ble.peripheral.start service_uuid=<...>`
* `[ios] ble.peripheral.stop reason=<background|user_end>`
* `[ios] gatt.challenge.recv corr=<id> nonce=<hex16> ts=<ms>`
* `[ios] gatt.proof.send corr=<id> ttl=<s> hmac8=<first8hex>`
* `[ios] gatt.proof.skip reason=<not_authed|not_foreground>`

---

## Mac state machine (trust)

### States

1. **MAC_LOCKED**

* `trusted=false`
* UI: 🔒 Locked
* No resources mounted; no secret actions allowed

2. **MAC_SEEKING**

* Scanning for iPhone service UUID
* UI: “Searching…”

3. **MAC_CONNECTED**

* BLE connected, characteristics discovered, ready to challenge

4. **MAC_TRUSTED**

* Trusted state; may have `deadline` depending on mode and signal state
* UI: ✅ Trusted (shows countdown only if deadline is active)
* Rust agent informed via `trust.verify_response`

5. **MAC_REVOKING**

* Cleanup in progress
* UI: “Revoking…”

### Transitions

**M1: Start scan**

* LOCKED → SEEKING

**M2: iPhone discovered + connected**

* SEEKING → CONNECTED

**M3: Challenge-response success**

* CONNECTED → TRUSTED
  (set `trust_until = now + ttl`)

**M4: Trust expiry**

* TRUSTED → REVOKING → LOCKED

**M5: Signal lost (disconnect / no proof / link down)**

* If state is SEEKING/CONNECTED: stay SEEKING (scan again)
* If state is TRUSTED: apply mode:

  * **Strict:** → REVOKING → LOCKED immediately
  * **Background TTL:** start `deadline = now + ttl_secs`; UI shows "Signal lost — revoking in …"
  * **Office:** keep TRUSTED; UI shows "Signal lost — office mode (locks on idle/sleep)"; apply idle gate when signal is lost

**M6: Manual “End Session” on Mac**

* TRUSTED → REVOKING → LOCKED

**M7: Mac sleep/lid close**

* Any state → REVOKING → LOCKED

### Mac logs (print exactly these)

**Scan/Connect**

* `[mac] ble.scan.start service_uuid=<...>`
* `[mac] ble.scan.found rssi=<...> name=<...> id=<...>`
* `[mac] ble.conn.start id=<...>`
* `[mac] ble.conn.ok id=<...>`
* `[mac] ble.gatt.ready chars=challenge,proof`

**Challenge/Proof**

* `[mac] trust.challenge.send corr=<id> nonce=<hex16> ttl_req=<s>`
* `[mac] trust.proof.recv corr=<id> hmac8=<first8hex> phone_fp=<...>`
* `[mac] trust.proof.ok corr=<id> trust_until=<iso>`
* `[mac] trust.proof.fail reason=<bad_hmac|stale_ts|unknown_phone>`

**Trust lifecycle**

* `[mac] trust.granted until=<iso> ttl=<s>`
* `[mac] trust.tick remaining_ms=<...>`
* `[mac] trust.expired`
* `[mac] trust.revoke reason=<expired|manual|sleep>`
* `[mac] trust.revoked`

**UDS to agent**

* `[mac->agent] trust.granted ttl=<s> until=<iso>`
* `[mac->agent] trust.revoked reason=<...>`

---

## Timing/Policy defaults (v1)

* TTL options: user-configurable (defaults: 120 / 300 / 600 seconds)
* HMAC freshness: configurable (default: challenge ts within 30s)
* Mac countdown tick: every 1s (local UI timer, no UDS polling)
* Disconnect behavior: **depends on user-selected mode** (Strict/Background TTL/Office)





---

## “What should happen” checklist

✅ If iPhone app is foreground + Face ID done → Mac can reach TRUSTED
✅ If iPhone backgrounds/locks → BLE stops → Mac stops receiving proofs; trust expires naturally
✅ Manual End (either side) → resources cleaned + LOCKED
✅ Logs allow you to diagnose failure in <30 seconds.

---


