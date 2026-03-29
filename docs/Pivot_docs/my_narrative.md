What SymbiAuth is
One sentence: SymbiAuth is a security product that ties dangerous Mac actions to your physical presence, verified by your iPhone.

What it does for the user
The user defines a list of sensitive things they do on their Mac (SSH into production, run a trading bot, deploy code, sign transactions). These are their Trusted Actions.

Each action can optionally need secrets (API keys, tokens, passwords) that are stored in macOS Keychain — not in .env files, not pasted from a password manager.

The daily workflow:

User walks up to Mac → opens SymbiAuth on iPhone → Face ID → phone says "Session active"
Mac menubar lights up → "Trusted Actions" become clickable
User clicks an action → Mac pulls secrets from Keychain, injects them as env vars, runs the command
User walks away / locks phone / ends session → Mac automatically kills the sensitive processes (if configured as continuous) and the secrets evaporate — they were never on disk
What changed with the refinements
The concept didn't change. What got sharper:

Before	After
kill_on_revoke: true/false	trust_policy: "continuous" / "start_only"
One size fits all	Clear distinction: "must trust stay active?" vs "just needed to start?"
No guard against double-click	single_instance: true prevents launching two copies
Silent failures	last_error shows user why something didn't work
No audit trail	Every run/cleanup is logged with who/what/when
No config validation	Bad configs are caught and skipped, not silently broken
The product promise is identical:

"Your Mac can only do dangerous things when your phone says it's ok. When your phone says stop, your Mac obeys."

The two trust policies make the product smarter
This is the biggest conceptual addition. Before, it was just "kill or don't kill." Now there's a clear product language:

continuous = "I need trust to be active the entire time this is running" → SSH sessions, signers, anything with live privileged access. Trust ends → process dies.

start_only = "I needed my phone to prove I'm the one starting this, but once it's running, it's fine" → Trading bot, batch job, background process. Trust ends → process keeps going.

This matches how real users think about their tools:

"I want SSH to die when I walk away" → continuous
"I want to prove it's me starting the bot, but it should keep trading overnight" → start_only
Who uses it (Phase 7a target)
The primary demo narrative is security-conscious professionals who regularly:

SSH into production servers
Run bots that need API keys
Use signing tools or deploy scripts
Want automatic cleanup when they leave
This isn't a consumer product. It's for people who already know their workflow is dangerous and want a hardware-backed kill switch.

Is it still "launchers"?
Internally, yes — launcher.rs, LauncherManager, etc. User-facing, the term is "Trusted Actions." That's what appears in the menubar. "Launcher" is plumbing. The user sees:

Trusted Actions
  ● SSH Production         ▶
    Run Freqtrade           ▶
    Start Signer            ▶
They don't need to know it's called a launcher. They just know: "When my phone trusts this Mac, I can do these things. When trust ends, the dangerous ones stop."



Do we handle the revokation edge cases? (i.e. what happens if the user revokes trust while the process is running? OR how long does user must keep the phone unlocked with app in foreground?)

Yes, the plan handles this. There are actually two layers working together here, and I think the confusion is because they haven't been explained together clearly.

Layer 1: Trust Mode (how long does trust last after phone goes away?)
This is the existing system from 

trust.rs
 — it's already built and working:

Mode	What happens when phone locks / goes out of range
Strict	Trust revokes immediately when BLE signal is lost
BackgroundTTL	Trust stays active for a countdown timer (e.g., 5 min, 30 min) after signal is lost
Office	Trust stays active until the user is idle for X seconds — phone can be anywhere
So a user running a trading bot would use BackgroundTTL or Office mode — trust doesn't die the moment they lock their phone. The BLE signal can be lost, the phone can be locked, and trust keeps going for the configured duration.

Layer 2: Trust Policy (per launcher — what happens when trust does end?)
This is the new Phase 7a addition:

Policy	When trust finally ends...
continuous	Process is killed
start_only	Process keeps running
How they work together — your trading bot example
Scenario: User runs a trading bot that should run for hours

The user would configure:

yaml
- id: "bot-freqtrade"
  name: "Run Freqtrade"
  trust_policy: "start_only"    # ← bot keeps running after trust ends
Now the flow is:

User opens iPhone → Face ID → trust starts
Clicks "Run Freqtrade" → bot starts with API keys from Keychain
User locks phone, puts it in pocket
BLE signal is lost → but trust mode is BackgroundTTL or Office, so trust stays active
Eventually trust expires (timer runs out, or user leaves office)
Trust revokes → but bot has trust_policy: "start_only" → bot keeps running
The bot keeps trading because trust was only needed to prove it was you who started it. The dangerous moment was launch time (injecting API keys), not runtime.

Compare with SSH:

yaml
- id: "ssh-prod"
  name: "SSH Production"
  trust_policy: "continuous"    # ← must die when trust ends
Same flow: Face ID → trust → SSH session starts
User walks away → signal lost → BackgroundTTL countdown starts (e.g., 5 min)
5 minutes pass → trust revokes → SSH session is killed
Because an open SSH session to production is a live privileged channel — it should die when you're no longer verified as present.

The matrix
Trust mode	Trust policy	Phone locked + away for 30 min	Result
Strict	continuous	Trust dies immediately → process killed	❌ Bad for bots
BackgroundTTL (30m)	continuous	Trust dies after 30m → process killed	✅ Good for SSH
BackgroundTTL (30m)	start_only	Trust dies after 30m → process keeps running	✅ Good for bots
Office	continuous	Trust dies when idle → process killed	✅ Good for signers
Office	start_only	Trust dies when idle → process keeps running	✅ Good for bots
So the short answer: no user needs to keep their phone unlocked for hours. The trust mode controls how long trust survives after the phone goes away, and start_only ensures the bot keeps running even after trust eventually expires. Both layers are in the plan.