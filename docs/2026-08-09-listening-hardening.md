# Listening hardening brief — 2026-08-09

> Saved verbatim from the originating request so the standard outlives the session.

Use the Workflow tool for this. I am explicitly requesting multi-agent orchestration, and explicitly asking for a larger fan-out than your default size guideline. This is a deliberate, budgeted hardening pass on ratbat, not a quick fix.

FIRST ACTION: save this brief verbatim to docs/2026-08-09-listening-hardening.md so the standard outlives the session. Then begin.

## The reference defect — read this before scoping anything

Ratbat was "running" for days while https://radio.jonasjohansson.se returned HTTP 530 / Cloudflare error 1033. The app was genuinely serving localhost:18000 the whole time. Its bundled cloudflared had died at an unknown moment; nothing noticed, nothing restarted it, and nothing recorded what killed it. A deploy verifier had checked localhost and reported success.

Note what was DISPROVEN while diagnosing it, so you don't rebuild a fix on a dead theory: the app DOES respawn cloudflared on relaunch (verified, within 5 seconds). So "install.sh orphans the tunnel and the app never brings it back" is WRONG. The tunnel came up at deploy time and died later, for reasons nobody can currently reconstruct, because no evidence was kept.

That is three distinct failures, and I want all three classes hunted:
  1. A load-bearing process can die with nothing watching.
  2. Nothing recovers it.
  3. Verification ran from inside the box, so the outage was invisible from where a listener stands.

Do not "fix the tunnel". Fix the class. The absence of evidence is itself a defect in scope — if this recurs, I want to be able to find out why.

## Goal A — the only goal this run

As long as Ratbat.app is running on mac-mini, https://radio.jonasjohansson.se serves audio.

That must hold, and self-heal, across: app relaunch; ./install.sh deploy; Mac sleep/wake; network drop and return; cloudflared crash or silent exit; station switch; exhausted or empty playlist. For each one: either prove it already recovers, with evidence, or make it recover. Recovery must be observable after the fact — I want to be able to learn that it happened and why.

OUT OF SCOPE this run, do not drift into them: owner actions (like / next / history / more-like-this) and the new settings (how much new music, tracks vs mix sets). They are the next two passes. If you find bugs there, write them down and hand them back; do not fix them.

## Rules of evidence — these are the point of the exercise

- VERIFY FROM OUTSIDE. A check that runs on mac-mini and hits localhost proves nothing about goal A. Prove listening by fetching the public URL and confirming real audio bytes flow. Report the actual status code, content-type and byte count you observed.
- THE SUITE IS NOT THE DEFINITION OF CORRECT. 244 tests passed while the radio was dark. Nothing covers the publish step or any recovery path. Find that uncovered ground and cover it.
- NEVER REPORT A SUMMARY AS EVIDENCE. That is exactly how the last deploy passed while nobody could listen. Quote real command output.
- A recovery path you did not actually exercise is not verified. Kill the process for real and watch what happens.

## Orchestration

Phase 1 — inventory, wide and cheap, run these agents on `fable`: one per surface — broadcast + tunnel lifecycle; deploy and supervision (install.sh, LaunchAgents, what watches what); the HTTP server and its routes; sleep/wake and network-change handling; existing test coverage of all of the above. Each returns what exists, what is tested, and what is merely assumed. If `fable` is not an accepted model override in your build, say so plainly in your report and fall back to inheriting the session model — do not silently substitute.

Phase 2 — finders with DISTINCT lenses, not redundant copies: silent-death (what else can exit unnoticed), inside-vs-outside (green locally, broken remotely), recovery (what never comes back), observability (what leaves no trace when it fails), deploy-time (what install.sh disturbs and does not restore).

Phase 3 — every finding faces independent skeptics on `opus`, prompted to REFUTE it, defaulting to refuted when uncertain. Majority kills it. I would rather lose a real bug than act on a confident fiction.

Phase 4 — fix survivors TDD, failing test first, in worktree isolation so parallel fixes do not collide. Then re-verify from outside.

Phase 5 — completeness critic: which surface went unexamined, which claim unverified, which recovery path never actually exercised? That list is the next round. Loop find -> verify until two consecutive rounds surface nothing new.

## Guardrails

- Keep the existing tests green. If one must change, justify it in the PR body.
- One PR per coherent slice, not one giant branch.
- STOP BEFORE MERGING OR DEPLOYING. Open the PRs, report, and wait for me. A deploy restarts the radio and that is user-facing — it is my call, not yours. This is the one hard stop in this brief.
- Do not touch the slapp cloudflared process or its config. It is a different service that happens to share the machine.

## Report back

What was actually wrong, class by class. What you changed and what you deliberately did not. The verified outside-in evidence, with real numbers. And what you did NOT do — silent truncation reads as completeness, and I will trust the report less, not more, if it sounds complete without saying where it stopped.
