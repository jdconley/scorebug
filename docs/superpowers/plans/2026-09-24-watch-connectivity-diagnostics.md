# Watch companion diagnostics implementation plan

> Execute inline with `superpowers:executing-plans`; the owner's autonomous-work
> authorization covers this bounded diagnostic and local simulator verification.

**Goal:** distinguish activation/companion discovery, local context publication,
and actual peer receipt during the failing paired Watch setup.

**Design:** keep behavior unchanged. Add an opt-in DEBUG-only unified-log observer
at existing native boundaries. A Foundation helper formats only closed event/kind
names, integer sequence/state/error code and boolean flags. It emits at most 128
rows and one explicit overflow marker per adapter lifetime, with a lock protecting
concurrent callbacks. No payload bytes, credentials, endpoints, identifiers, error
messages/domains or free-form caller text enter the helper. Snapshot paired/app
installation/reachability only after activation; absent values stay unknown.

Unified logging is preferable to a new file export/UI control for this diagnostic:
the existing owned-simulator harness already collects logs. Full context logging is
unnecessary and can disclose credentials. The observer adds no retries, background
work, transfer methods or state transitions. Acceptance is local, never proof of
delivery. Missing log rows are not proof of a missing callback; retained sequence
and overflow markers make partial evidence visible.

Apple's [WCSession documentation](https://developer.apple.com/documentation/watchconnectivity/wcsession)
and [context delegate documentation](<https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session(_:didreceiveapplicationcontext:)>)
separate activation, local publication and counterpart delivery.

## Tasks

- [x] Add `ios/Sources/WatchSupport/WatchConnectivityDiagnostic.swift` and focused
      `ios/WatchModelTests/WatchConnectivityDiagnosticTests.swift`. Tests require opt-in,
      closed payload-free fields, nil/false distinction, 128-row cap plus one overflow,
      and unique bounded sequence numbers under concurrent callbacks. Include the
      helper in `ios/WatchModels.yml`; run isolated Watch model tests red then green.
- [x] Instrument `WatchSetupConnectivity.swift`: activation request/completion,
      local publish attempt/accept/reject (including activation-time replay), received
      context callback, decoded notice/envelope, and peer lifecycle callbacks. Use
      subsystem `live.scorebug.connectivity`, category `diagnostic`. Only construct
      snapshots when DEBUG environment `SCOREBUG_WATCH_CONNECTIVITY_DIAGNOSTICS=1`.
- [x] Enable the flag explicitly in the two actual-companion UI tests. Extend
      `scripts/test-paired-watch.mjs` failure log predicate to collect this subsystem
      alongside the existing filtered Apple state logs. Keep secret redaction and
      byte/time limits; no injected setup fallback.
- [x] Review, run Watch models and tooling, then one fresh paired iOS/watchOS26.2
      simulator case with the existing owned-process wrapper. Inspect the original
      outcome and diagnostic logs; don't rerun an unchanged failing case. Verify
      cleanup and unchanged source hashes. Build unsigned Release and verify the
      diagnostic opt-in key is absent from the phone and embedded Watch binaries.
- [x] Update this plan and parent status with the actual failure boundary and
      next action. Retain prior ACX43 and missing-companion failures as failed.

## Verification and new failure boundary

Independent review approved the implementation after moving peer invalidation
before diagnostic work and capturing callback epochs before logging. This keeps
logging latency from delaying revocation or attaching an old callback to a newer
peer. The helper's four tests first fail against the empty implementation, then
all **58 Watch model/gate/diagnostic tests pass**. All **3,481 tooling tests pass**.
The fresh paired run builds both native apps successfully. The combined unsigned
Release phone/Watch build passes, with the diagnostic opt-in key and subsystem
absent from both Release executable files.

`artifacts/qa/paired-watch-gKwDrj` remains a **failed paired qualification**:

- Watch activation completes in state 2 (activated), without an activation error.
  Its companion-installed flag is false. Reachability later becomes true while
  companion-installed stays false.
- The captured Watch prefix shows repeated `publishAttempt` / `publishRejected`
  for the setup notice, each rejection reporting WC error **7018**. The installed
  SDK names this `WCErrorCodeCompanionAppNotInstalled`. Thus these calls fail local
  publication; this evidence does not describe an accepted context lost in transit.
- The trace has unique contiguous sequence numbers 1–129. Row 129 is the declared
  overflow marker; the final attempt's outcome and later activity are outside the
  captured prefix. The system log also retains ACX43 / “App database is out of sync”.
- No application diagnostic rows are retained from the phone. Its filtered system
  log does report paired/app-installed state, but this does not establish which
  application callbacks ran. Do not infer their absence or symmetric state.
- Watch UI fails waiting for the offered setup after 183.591 seconds. The phone
  remains waiting for a usable setup button and is stopped by owned cleanup.
  The isolated API has zero Watch pairings, scoring commands or media commands.
  No paired scoring or completed-recording pass is claimed.
- Both owned simulators are deleted. All **1,176 source hashes** remain unchanged
  through verification. `diagnostic-assessment.json` retains the bounded original
  diagnostic rows, counts, source comparison and Release binary fingerprints.
  Joined commands are `repeated-live-checkpoint-watch-diagnostic-*-exit.json`.

The foreground retry fix is exercised: the Watch repeatedly attempts its current
notice. The new evidence places those failures before local context acceptance.
A useful next experiment is a bounded, explicitly enabled, payload-free immediate
message round trip after this rejection, testing whether reported reachability
corresponds to a usable paired message route. A successful round trip would justify
considering an immediate setup-notice path; it would not qualify context delivery
or authorize weakening setup authentication. Also investigate retention of phone
application diagnostics before treating the two-sided trace as complete. Do not
repeat the unchanged paired case or claim a framework/database repair.

## OS 27 follow-up

The scoped Xcode 27.0/27A266a case on frozen `c1fb1c7` uses iPhone 14/iOS 27.0
and Ultra 2/watchOS 27.0. Both builds succeed, but the full paired workflow still
fails before setup. The retained Watch trace contains two activation requests,
63 notice attempts and 63 local not-ready rejections at activation 0, followed by
the overflow marker. No activation completion or immediate probe occurs in that
prefix. Later callbacks are unknown. The phone trace contains activation state 2
with paired/installed true. ACX43 occurs in the Watch system log; WC7018 is not
observed in this run. Preserve that distinction from the activated 26.2 failure.

Watch XCTest exits 65 after 184.075 seconds waiting for the offered setup. The
phone test is stopped by owned cleanup. SQLite confirms zero Watch pairings,
scoring commands and media commands. Both owned simulators are deleted, the API
port is bindable, owned test processes are gone, and all 1,179 tracked source hashes
match. The outer wrapper is joined with exit 1. Detailed evidence is retained in
`artifacts/qa/paired-watch-FzV6gI/diagnostic-assessment.json`.

The separate OS27 direct native Watch scoring/relaunch UI passes with injected
setup and real Keychain/URLSession. It does not qualify companion transport.
The direct-launch 26.2 diagnostic also stayed at activation 0; explicit activation
of a fresh simulator pair reported already active before launch. Template/plist
inspection found no concrete companion-key mismatch. Do not flip registration
keys or repeat the same failed workflow without a specific new hypothesis.
Physical phone and Watch currently report unavailable from scoped Xcode27 device
queries, so actual companion, Wi-Fi and cellular acceptance remains open.
