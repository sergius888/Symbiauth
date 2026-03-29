# SymbiAuth Security Notes

This repo is public and usable. It is not ready to be described as hardened security software.

## Read This First

SymbiAuth currently gives you:
- a real trust session on the phone
- a real chamber on macOS
- a real trusted shell
- a real CLI path for one-shot env injection

It does **not** give you a finished end-user security guarantee.

## What The Current Build Tries To Protect

- casual local access when trust is not active
- accidental secret exposure during normal desktop use
- leaving sensitive work open after the trusted window should be over
- running short sensitive terminal commands without leaving env vars in your normal shell

## What It Does Not Claim To Solve

- a fully compromised Mac
- nation-state style forensic guarantees
- perfect protection against local malware
- a formal split-key design where the phone holds the missing half of all desktop state

Some data is still stored on the Mac. Trust gating controls access through the product flow. That is not the same thing as saying the Mac becomes cryptographically empty without the phone.

## Trusted Shell Reality

The Trusted Shell is a chamber-owned shell host.

It is:
- real
- tied to trust state
- able to inject selected secrets into one shell session

It is not:
- Terminal.app
- iTerm integration
- a full terminal emulator
- a guarantee that commands you run cannot leak data through their own side effects

## Reporting A Vulnerability

Do not post active exploit details in a public issue.

If GitHub private security reporting is enabled on the repo, use that. If not, contact the maintainer privately first and keep the first report minimal and reproducible.

## Safe Public Framing

The honest public framing for this repo is:

`experimental local-first trust system for short-lived sensitive work`

Not:

`finished secure password manager`
