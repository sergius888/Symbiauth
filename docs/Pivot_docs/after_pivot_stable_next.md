Yep — all four matter. Here’s the **order that minimizes rework** and keeps you shipping.

## 1) Messy codebase / warnings

**When:** *after* the pivot vertical slice works end-to-end.
**Why:** warnings cleanup before the pivot is wasted motion; you’ll delete/replace chunks anyway.

**Rule:** only fix warnings that are *actively breaking you* during the pivot (compiler errors, racey behavior, obvious bugs). Everything else goes into a cleanup pass.

**Milestone to trigger cleanup:** “GATT challenge–response works + TTL revoke triggers cleanup reliably.”

---

## 2) Renaming (dreiglasser / armadillo / symbiauth)

**When:** *after* the pivot is stable but *before* you do any UI polish or public release.
**Why:** renaming touches bundle IDs, app groups, keychain access groups, entitlements, native messaging host IDs, launchctl labels, paths, etc. Doing it now will derail the pivot.

**What to do now:**

* Pick a “shipping name” for v1 (could still be Armadillo internally).
* In code, stop spreading names further: create constants like `APP_BRAND_NAME` and use those in new UI strings.

---

## 3) GitHub repo / trust / CI/CD

**When:** *two phases.*

### Phase A (now, 30 minutes max)

Do a **basic safety check** before coding more:

* Add/verify `.gitignore` for:

  * `~/.armadillo/`-style dirs
  * `*.der`, `*.pem`, `*.p12`, `*.key`
  * `server_identity.*`, `paired_devices/`, logs
* Run a local secrets scan (simple): `git grep -nE "(API_KEY|SECRET|BEGIN PRIVATE KEY|p12|aws_|binance|bybit)"`

That reduces risk while you keep moving.

### Phase B (after pivot works)

Create a **clean repo** (recommended) and move only what you want:

* keep history private in old repo
* new repo becomes the one you build on (still private until you’re ready)

**Public vs private:** keep it **private** until:

* naming is final
* secrets hygiene is solid
* you’ve decided what’s open-source vs proprietary

CI/CD: don’t overbuild. For v1, minimal is:

* Rust `cargo test`
* iOS/macOS build checks (even if unsigned)
  That’s it.

---

## 4) UI design (ugly now)

**When:** after the pivot works and naming is close to final.
**Why:** UI polish before the mechanics are stable is pure churn.

**What we do right after pivot success:** a “UX pass” that is mostly structure, not colors:

* landing screen flow
* session start/stop clarity
* visible status (“Trusted 4:32”)
* fewer confusing toggles

Then later: visual design.

---

# The plan in one line

**Pivot first → cleanup warnings → rename → repo hygiene/new repo → UI/UX polish.**

If you want, I’ll turn this into a tiny `docs/WORK_PLAN.md` with checkboxes so you can track it like a build roadmap.
