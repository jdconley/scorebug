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

## Remaining qualification

- Complete watchOS 11 runtime coverage. The installed Xcode 26.2 download command
  reported 11.5 (ARM64 and universal) and 11.4 universal unavailable; the earlier and
  current-generation native runtime passes do not replace this missing check.
- Exercise actual companion exchange with paired simulators and physical devices.
- Verify Watch A while its paired phone films, and Watch B through another phone.
- Test wrist suspension, cellular/Wi-Fi/paired-route changes, and dropped replies
  on physical hardware; simulator networking cannot establish those guarantees.
- Continue adaptive media telemetry, profile transitions, impairment and sustained
  recording/streaming qualification from the parent plan.
