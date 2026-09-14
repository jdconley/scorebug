# Native Watch app and companion setup

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
request ID, endpoint, and installation context. Only a bounded, typed setup offer
crosses to the Watch; installation authority, redeemed credentials, recovery keys,
and scoring commands do not. The Watch explicitly accepts an offered match and
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

Watch HTTP uses OS-selected networking. The production companion bridge exchanges
setup/identity context and handles activation and Watch switching. This implementation
is not evidence of reliable physical Wi-Fi, cellular, or paired-phone routing.

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

## Remaining qualification

- Exercise actual companion exchange with paired simulators and physical devices.
- Verify Watch A while its paired phone films, and Watch B through another phone.
- Test wrist suspension, cellular/Wi-Fi/paired-route changes, and dropped replies
  on physical hardware; simulator networking cannot establish those guarantees.
- Continue adaptive media telemetry, profile transitions, impairment and sustained
  recording/streaming qualification from the parent plan.
