# Native Watch app and companion setup

Latest paired-simulator evidence: the [immediate-message diagnostic](superpowers/plans/2026-09-24-watch-immediate-probe.md)
also fails with WC7018 (companion app not installed), despite Watch reachability.
Notice-level logging now retains phone activation with its Watch app installed;
the Watch still reports its companion missing. Paired setup remains failed, and
this result does not justify an immediate-message fallback. Direct native scoring
evidence below does not establish actual paired setup or physical routes.

`ios/Project.yml` generates a watchOS 10 **ScorebugWatch** app and embeds it in the
native iPhone app. Its only project package dependency is ScorebugCore. The phone
has Film, Score, Watch, and Recordings tabs. There is no browser scorer.

## Setup and scoring

Open Scorebug on the paired Watch to advertise its own persisted device identity.
In the phone's Watch tab, choose an already saved Film or Score connection. The
phone discovers a saved Score connection even before that tab is opened after a
relaunch, without activating scoring or reconciling its outbox.

The phone persists a pairing request before issuance and the returned offer before
sending it through WatchConnectivity application context. Retries keep the original
request ID, endpoint, and installation context. Setup application context carries
only a bounded, typed offer and identity notices; it never carries installation
authority or recovery keys. The Watch explicitly accepts an offered match and
stores its own redeemed credential in device-only Keychain.

The Watch shows scores, team point buttons, set totals, explicit takeover, undo,
confirmed end-set/end-match controls, retry, and reconciliation. A durable outbox
precedes command submission. Success haptics and accepted scores follow authoritative
acknowledgment and a successful outbox clear. Uncertain scoring blocks setup changes.

Foreground wake restores and recovers pending work. Routine two-second polling
only fetches snapshots and keeps scoring controls usable. A user action reserves
one slot, cancels and joins any passive poll, then rechecks lifecycle, setup,
pending work, and current scorer before submission. Suspension invalidates and joins
owned work. The app does not request continuous background execution.

Configured Watch scoring now uses direct HTTP with OS-selected networking plus an
explicit paired-phone relay. The native app initially tries direct HTTP, retains a
successful route and uses receipt-first recovery after uncertain sends. A command
is never blindly resubmitted through a second route. Immediate recovery runs once;
the durable coordinator owns receipt lookup, retry eligibility and exact-command
retry. Current attempt budgets are two seconds direct, two seconds companion and
1.5 seconds for the phone's nested HTTP forwarding.

The relay carries only bounded snapshot, execute and receipt requests, authenticated
with the Watch's own score credential. The phone must match the complete scope to
its persisted pairing association before forwarding; it never substitutes its own
credential. One existing WCSession delegate handles setup and scoring at app scope,
independent of filming or the selected phone tab. Peer changes invalidate old work
before admitting new requests.

Initial setup now also has a paired-phone route. Its separate typed request carries
the saved pairing capability, redemption ID and recovery key. The phone matches the
capability against its persisted pending offer before forwarding, without substituting
installation authority or saving the returned Watch credential. A lost reply preserves
the same pending redemption for a later attempt, including recovery after capability
expiry. Only the Watch's successful Keychain commit and matching paired notice can
activate the phone's scoring association. See the
[bootstrap relay checkpoint](superpowers/plans/2026-09-15-watch-bootstrap-relay.md)
for current tests and remaining physical qualification.

The full injected setup/recovery/scoring workflow now passes, including Watch
storage before phone activation and one credential recovered after a lost reply.
The existing Series 7 41 mm / watchOS 10.5 native UI workflow also passes after
this wiring (`artifacts/qa/native-watch-4itqTX`), with all six expected server
outcomes and Keychain relaunch restoration. Initial setup is injected for that UI
run; it proves direct networking, not real companion transfer.

The routed native code compiles for iPhone and both Watch architectures. Core/model
tests cover deadlines, cancellation, lost replies and exact-command recovery; see
the [relay checkpoint](superpowers/plans/2026-09-15-native-watch-relay.md#routed-native-scoring-checkpoint)
for current counts and evidence. This is not evidence of reliable physical Wi-Fi,
cellular, background wake or paired-phone delivery.

## Repeatable local test

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer
pnpm test:native-watch
```

The script creates a dedicated Watch simulator, starts a real API with an isolated
SQLite database, and injects a loopback setup envelope into a Debug simulator build.
The Watch explicitly redeems it using URLSession and real simulator Keychain. The
UI then takes over, scores, undoes, checks tied-set rejection, scores again, terminates,
relaunches without injected setup, restores the score, and ends the match. The script
checks authoritative command order/outcomes and retains screenshots/results under
`artifacts/qa/native-watch-*`. Only owned devices and processes are removed.

The first normal-polling Series 7 41 mm/watchOS 10.5 run passed at
`artifacts/qa/native-watch-EAmAxh`. Its SQLite receipts show exactly six commands:
takeover, point, undo, rejected tied end-set, point, and end-match. Final revision is
5 and score is 0–1. Screenshots of scoring and Keychain relaunch restoration were
inspected. The initial setup was injected; this is not a companion-transfer test.

The same workflow also passed on Ultra 2/watchOS 26.2 at
`artifacts/qa/native-watch-FI57Kh` and SE 40 mm/watchOS 10.0 at
`artifacts/qa/native-watch-cTLRUw`. Both runs checked all six command receipts and
outcomes; scoring/restoration screenshots were inspected on both sizes.

Series 7 41 mm/watchOS 11.5 also passed at `artifacts/qa/native-watch-LAbbIq`,
including all six command receipts, Keychain relaunch recovery, and inspected
scoring/restoration screenshots. Xcode 26.2 installed this runtime using its build
number, without an architecture flag:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  xcodebuild -downloadPlatform watchOS -buildVersion 22T572
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  SCOREBUG_WATCH_RUNTIME=11.5 pnpm test:native-watch
```

The earlier marketing-version download attempts failed. An initial test invocation
also selected the machine's default Xcode and failed destination discovery before
testing; the passing invocation explicitly scoped Xcode 26.2.

Final model checks pass: Watch 27, Core 110, phone setup 9, native phone scoring 19,
and filming/control 37. The combined unsigned Release phone/Watch build passes;
the Watch binary includes arm64 and arm64_32 and excludes the simulator setup key.
Evidence includes `watch-endpoint-canonical-{green,core-green}.log`,
`phone-watch-scope-green.log`, `watch-connection-discovery-green.log`,
`watch-film-regression.log`, and `watch-release-final.log` under `artifacts/qa/`.
Specification and quality reviews approved the final source after regression fixes.

Model coverage includes failed saves, dropped responses, peer changes, suspension,
late replies, endpoint scope, receipt recovery, explicit first acceptance, haptic
ordering, and one-action reservation during passive polling. Independent reviews
cover both specification and code quality; final review fixes are recorded with
their red/green evidence in `artifacts/qa/`.

## Real companion and recording probe

`pnpm test:paired-watch` creates its own paired iPhone 14/iOS 17.5 and Series 7
41 mm/watchOS 10.5 simulators. It builds both apps, preinstalls them sequentially,
then runs concurrent native UI tests against an isolated API. The phone starts a
local archive before companion setup. The Watch must advertise its real identity,
receive and accept the phone's offer, take over, score, undo, score again, and end
the match. The phone must keep recording afterward and export a clean file.

A pass requires the actual WatchConnectivity handshake, five exact accepted Watch
command receipts, no broadcast commands, and full A/V decode of the exported
1080p archive. Every fixture barcode must be contiguous and cadence at least 24 fps.
The probe never injects Watch setup as a fallback. Failure logs include bounded,
redacted system installation/activation state before owned devices are removed.

The initial run (`artifacts/qa/paired-watch-2A4VYL`) failed before setup transfer.
The preinstallation run (`artifacts/qa/paired-watch-5B7lNY`) also failed: phone
WatchConnectivity reported the Watch installed and reachable, but the Watch reported
its companion missing and ACX error 43, "App database is out of sync." No pairing
or scoring command reached the API. These runs do not qualify simultaneous Watch
scoring and recording. The build-time bundle identifiers matched on both sides.
The same probe on iPhone 15/iOS 26.2 and Ultra 2/watchOS 26.2
(`artifacts/qa/paired-watch-nIPx7o`) also failed before pairing; the Watch system
service again reported ACX error 43. Changing runtime generation did not resolve it.

A final installation-isolation experiment (`artifacts/qa/paired-watch-PY5rc9`)
preinstalled both apps and both UI test runners, then used Xcode's documented
`UseDestinationArtifacts` test configuration. Both destinations were rejected
before testing: Xcode requires a physical iOS device for that mode. The unusable
simulator option was removed; its source and generated configurations remain in
the experiment artifact. No production pairing changes were made from these
simulator failures. Physical companion exchange remains unqualified.

Use `SCOREBUG_IOS_RUNTIME`, `SCOREBUG_WATCH_RUNTIME`, `SCOREBUG_IOS_DEVICE_TYPE`, and
`SCOREBUG_WATCH_DEVICE_TYPE` to select another installed pair; the artifact records
the chosen configuration. Simulator evidence does not replace physical routing and
suspension tests. Apple's [WatchConnectivity sample](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity)
explicitly calls for a physical iPhone and Watch.

## September 24 recovery correction

The Watch now retries a failed setup-notice publication during foreground polling,
including before initial pairing. Locally accepted notices are deduplicated;
suspension or an in-flight operation suppresses poll retries. A failed newer notice
invalidates the previous cache so discarding an expired offer cannot leave that
failed pending context retained. Publication failure does not disable direct
scoring or change command haptics. Local context acceptance is not confirmation
that the phone received it.

The [retry implementation and evidence](superpowers/plans/2026-09-24-watch-notice-retry.md)
records 54 passing Watch model/gate tests, 502 filming/model tests, independent
review and the combined unsigned Release build (both Watch architectures).
Ultra 2/watchOS 26.2 passes native scoring and Keychain relaunch recovery at
`artifacts/qa/native-watch-8NXAx7`; screenshots were inspected. This standalone run
injects initial setup and then uses real HTTP and Keychain.

Fresh actual paired runs before (`paired-watch-wzOACx`) and after the correction
(`paired-watch-t9PB1Q`) both fail before setup. The Watch again reports ACX43 and a
missing companion; neither run creates a pairing or score command. Correct bundle
identifiers and embedding were verified. The retry correction does not resolve
the retained simulator failure. Both runs preserve their original failures and
remove their owned devices. Physical companion exchange remains unqualified.

## Remaining qualification

- Exercise actual companion exchange with paired simulators and physical devices.
- Repeat Watch A while its paired phone films, and Watch B through another phone,
  on real devices. The injected native-model test now covers those scoring roles
  during one finalized, decodable local A/V archive; it does not exercise WC radios.
- Test wrist suspension, cellular/Wi-Fi/paired-route changes, and dropped replies
  on physical hardware; simulator networking cannot establish those guarantees.
- Continue adaptive media telemetry, profile transitions, impairment and sustained
  recording/streaming qualification from the parent plan.
