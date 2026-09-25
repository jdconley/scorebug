# Measured delivery floor implementation plan

> Use `superpowers:executing-plans` task by task. The user has authorized autonomous implementation; keep existing strict benchmarks and failed evidence.

**Goal:** Add an explicitly selected laboratory delivery profile matching the user's minimum24fps requirement without weakening timing, ownership, admission or recovery gates.

**Architecture:** The host selects `floor24-v1` only for a complete staged measured file trial. Omission keeps `strict30-v1`. After raw delivery reconstruction, the successful-trial gate requires every row classified, no late/missing/uncertain rows and no below24fps rows. Original strict30 `healthyRows` and diagnostics remain intact. This is an audited one-/two-second window floor, not an instantaneous display cadence guarantee or a new24fps encoder recipe.

**Tech stack:** Node/assert and existing native harness/replay fixtures. No app/encoder/network changes.

## Scope and contracts

- `SCOREBUG_TEST_DELIVERY_PROFILE=floor24-v1` is host-only, exact spelling; configuration/results/qualification record the resolved profile. Reject malformed, partial, non-file, recovery/repeated and mixed-fault routes before resource creation. The native app receives no new switch.
- Pure successful-trial replay takes `deliveryProfile` with strict30 default. Invalid values fail. The selected gate runs after independent raw reconstruction; no caller-supplied result summaries enter whole-trial qualification.
- Preserve zero unknown/late/missing/uncertain gates, 1.5s deadlines,250ms sample freshness, source admission/probation≥29.7fps and≥10s contiguous coverage, all cost/probe/native ownership checks. Recovery-specific coverage remains unchanged.
- Historical strict30 failures remain failures. Any posthoc floor24 replay must be a separately named assessment with explicit profile/source provenance and the original failed result retained. The current one-unknown-row run must fail both profiles.

## Steps

- [x] Add behavior tests in `scripts/test/native-file-measured-options.test.mjs` for exact opt-in, defaults and rejection of partial/conflicting routes; observe failures.
- [x] Add `nativeDeliveryProfile` selection in `scripts/native-file-fixture.mjs` and early guard in file options. Wire resolved value through `scripts/test-native-app.mjs` before any resources, recording it in configuration/results and passing it only to successful-trial replay.
- [x] Add tests in `scripts/test/measured-native-trial.test.mjs` for default/explicit profiles and preserved full-trial gates. Add raw deadline boundary tests in `scripts/test/native-delivery-deadlines.test.mjs` for exactly24,below24,29/29.5 and all failure classifications; observe failures.
- [x] Extract/select the successful-trial delivery gate in `scripts/measured-native-trial.mjs`; leave independent reconstruction and recovery gates unchanged.
- [x] Run focused then full tooling tests. Request read-only review. Replay the prior complete157-window run and the current unknown-row run under both named profiles with new provenance artifacts.
- [x] Update this/main plan with verified results; commit. New live qualification must select a profile before launch. Sustained-pressure/capacity/outage, production wider ladder and physical devices remain separate gates.

## Verification checkpoint

Focused147 tests and full3,909 tooling tests pass (joined runner `delivery-floor-tools-full`). Behavioral red logs show missing profile selection/gate functions and result metadata; raw reconstructed24/48-frame boundaries pass,23/47 fail, and29/59 fail strict30 but pass floor24. Read-only review found no issues. No Swift/media/network/recovery code changed.

Posthoc comparison `artifacts/qa/delivery-profile-replay-gh4ozU/` preserves source copies, hashes and every raw artifact hash. `native-app-NCUMkX` passes complete floor24 replay with all157 rows free of late/missing/uncertain frames; strict30 still fails139/157 healthy rows. `native-app-YFObMQ` still fails both profiles because one row is unknown. Original failed artifacts remain unchanged; this comparison is not a fresh network run or production authorization.

The fresh native run with `floor24-v1` selected before launch passes; the separately outstanding sustained-pressure/capacity/outage work is next.

## Fresh native qualification

`native-app-G0kJLr` / `delivery-floor-freeze-psy3xtu4` joined with exit0. Configuration and results explicitly record `floor24-v1` and `recovery-budget-v1`. The installed iOS26.2 simulator ran the prepared real match source (SDR1080p30), static bidirectional30ms delay/every500th-datagram loss,400ms SRT peer latency and1.5s delivery budget. The UI workflow passed in169.382s; both exported MP4s fully decoded.

- All154 audited one-/two-second windows classify successfully, with zero unknown/late/missing/uncertain/below24 windows. All154 also meet the unchanged strict30 diagnostic in this particular run. No claim of a performance change from the host benchmark switch.
- The real candidate measured121 frames, then native publication applied240p→360p and policy confirmation passed. Production upgrades remain disabled.
- Clean1080p archive:3,865 consecutive source IDs0–3864. Saved360p worker output:3,412 consecutive IDs238–3649. Source loss0 in each; archive continues7.167s beyond live.
- All27 phase audio anchors pass for each output. Live absolute audio/video lag≤65.451ms and lag spread≤0.667ms; archive lag is effectively zero. These are measured local-fixture results, not guarantees for other devices/hosts.
- Actual format6 export255,792bytes, no overflow. All1,223 frozen source/input hashes unchanged after join. Temporary simulator and relay container cleaned up; originals untouched.

`checkpoint-summary.json` and `results.json` retain the outcome. Historical failures remain unchanged. This clears the static impaired-link measured-trial gate only. Sustained congestion/export, causal capacity drop/outage recovery, broader resolution ladder, production integration, physical camera/pairedWatch and remoteGPU/cloud remain unqualified.
