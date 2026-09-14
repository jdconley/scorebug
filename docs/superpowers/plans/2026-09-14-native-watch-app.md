# Native Watch app and companion setup

Implement the approved Watch UI milestone using the committed pairing foundation.
Use the subagent-driven workflow with independent specification and quality reviews.

## Boundaries

- A native watchOS 10 application depends only on ScorebugCore and Apple UI/network
  frameworks. It has no camera/media package dependency. Its own Keychain setup and
  private scoring outbox survive termination. Direct URLSession uses available
  OS-selected networking; custom companion command relaying is a later qualification.
- The full iPhone app gains a Watch setup tab. The user chooses its saved Film or
  Score server connection, then explicitly sends setup to its active paired Watch.
  Fetch the current active match and persist a UUID issuance request in Keychain
  before calling the existing pairing endpoint. Retries reuse that request and
  original endpoint/installation context. No camera or broadcast role is needed.
- WatchConnectivity carries bounded typed setup/identity data only. Application
  context contains one encoded envelope, capped at 8 KiB. A Watch notice identifies
  its own device UUID, phase, and optional match/pairing IDs. A phone envelope contains
  version, endpoint, and short-lived pairing offer. Never transfer installation
  authority, the redeemed Watch credential, recovery key, or scoring commands.
- Activation reads the latest received context. The phone reactivates after Watch
  switching and invalidates its displayed peer identity. Each delivered setup is
  checked against the Watch-local identity. Transfer success is labeled sent;
  readiness requires the Watch's paired notice after its credential has been saved.

## Watch lifecycle and scoring

Restore setup, advertise identity, and reconcile pending redemption/commands on
wake. Suspend cancels owned requests, joins them, and guards late results before
another action or configuration switch. Poll snapshots only while active. The native
model is the single configuration/outbox owner required by the Core coordinators.
An incoming setup for a different paired match requires explicit replacement; a
pending scoring action blocks that replacement. Keep at most one offered setup.

Show team scores, set and match state, explicit takeover, undo, end-set confirmation,
guarded end-match, pending/rejected/accepted states, retry, and reconciliation.
Success haptics require a newly acknowledged authoritative outcome. No optimistic
point display or browser scorer. Keep primary controls usable on Series 7 41 mm,
Ultra 2, and SE-sized displays.

## Work and verification

1. Shared bounded companion contracts and native Keychain/WatchConnectivity adapters.
   Validate version, size, identity, and allowed fields; ignore unrelated messages.
2. Watch model/UI with injected network/storage/haptics and deterministic lifecycle
   tests. Cover pending/lost reply, suspension, stale response, takeover, tied set,
   new-match offer, save failure, and haptics only after confirmed results.
3. Native phone issuance model/tab, saved connection providers, and tests for
   lost issuance response, storage failure, peer switch, stale delivery, and no
   mutation of Film/Score/broadcast ownership.
4. XcodeGen watchOS target and owned simulator harness. Build watchOS 10/26 and iOS
   17/Release. Run real API/direct Watch HTTP UI workflows and inspect small/large
   Watch screenshots. Distinguish injected setup from actual companion exchange.
5. Extend paired phone recording/scoring workflows once the isolated Watch app
   works. Record simulator route limitations explicitly; physical pairing, cellular,
   wrist suspension, and long recording remain separate gates.

Expected native files: `ios/Sources/ScorebugWatch/`,
`ios/Sources/Scorebug/Companion/`, shared adapter sources under
`ios/Sources/WatchSupport/`, `ios/WatchModelTests/`, `ios/WatchUITests/`, and
`ios/Project.yml`. Preserve existing Film/Score UI identifiers and workflows.

## Implementation evidence

Native source and the direct-HTTP simulator milestone are implemented and independently
reviewed. See [native Watch app](../../native-watch-app.md) for per-runtime artifacts,
model test totals, and exact limitations. Series 7 41 mm/watchOS 10.5, Ultra 2/watchOS
26.2, and SE 40 mm/watchOS 10.0 pass the native UI workflow including real Keychain
relaunch recovery. Companion setup is implemented but actual paired exchange and
simultaneous paired-phone recording remain the next qualification step. watchOS 11
runtime coverage remains open after the installed Xcode download catalog rejected
the requested 11.5/11.4 variants.
