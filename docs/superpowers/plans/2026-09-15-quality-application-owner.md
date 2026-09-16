# Quality application owner implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline with behavioral
> red/green tests and bounded independent source review. Parent owns all execution.

**Goal:** Bind verified startup and owned native bitrate writes to the pure quality
policy without allowing stale advice, late acknowledgments or unsupported profile
changes to claim applied settings.

**Architecture:** Add an app-layer actor `PublishingQualitySession` that owns a
PublishingSession reference and one QualityController. It remains opt-in and is not
started by CaptureStreamingModel until aligned telemetry is qualified. Bootstrap
writes the caller-qualified initial bitrate after the encoder is available; only a
verified receipt constructs policy revision zero. Evaluation and deadline polling
produce advice; apply admits exactly the latest advice and blocks policy evaluation
while the native write suspends. Success acknowledges at current uptime, keeps the
receipt/configuration associated with the new revision, and clears pending advice.

**Tech stack:** Existing Swift actor ownership, ScorebugCore policy, ScorebugMedia
receipts/session, macOS Film model tests, combined unsigned iPhone/Watch build.

## Decisions and boundaries

A direct call from the capture model would scatter stale-advice and receipt checks
across reentrant UI code. Extending the pure policy with CoreMedia would couple Watch
code to native video. The app-layer actor keeps those concerns together without
introducing a package dependency or enabling unqualified automatic behavior.

The caller supplies a qualified profile ladder and initial settings; a bitrate
receipt verifies neither resolution nor capture support. Profile transitions are
rejected before native dispatch. Same-profile trial, rollback, increase and decrease
use the existing session deadline capped at two seconds. Unsupported transitions
remain an explicit future gate, not a silently substituted bitrate-only transition.

The actor admits one bootstrap/apply at a time. A terminal stop marks it closed
before awaiting session stop. Late continuations cannot initialize or advance policy.
Native mutation/cancellation/deadline ownership remains in PublishingSession. The
actor creates no background tasks. Dispatched errors or invalid receipts stop the
live attempt; invalid or superseded advice is rejected before dispatch. Historical
applied settings remain available after stop, explicitly marked closed.

Every receipt must match requested rate, native generation and known previous
configuration boundary, and be accepted within request and current uptime. Configuration
IDs must change. Same-session source boundaries cannot regress/disappear. A different
encoder session may reset its source boundary. An acknowledgment uses current time,
not receipt time, so queued telemetry cannot be relabeled as post-acknowledgment.

## Steps

- [ ] Create `ios/Sources/Scorebug/Capture/PublishingQualitySession.swift` API stub
  and `ios/FilmModelTests/PublishingQualitySessionTests.swift`. API: throwing init
  validates profiles/settings; `bootstrap() async throws`; `evaluate(Window)` and
  `checkTrialDeadline()` synchronously actor-isolated; `apply(Recommendation) async
  throws`; `stop() async`; immutable snapshot exposes optional settings/revision/
  receipt and closed/busy. Internal injected operations/uptime permit deterministic
  tests; production initializer uses PublishingSession directly.
- [ ] Behavioral red: bootstrap creates revision zero only after matching receipt;
  recommendation does not change applied state; success advances exactly once;
  stale/expired/foreign advice never writes; unsupported profile change never writes;
  concurrent apply/evaluate cannot change pending policy; late stop/cancellation or
  wrong generation/rate/time/configuration/boundary fails terminally; full trial to
  deadline rollback keeps native receipts associated with revisions. Integration test
  exercises production initializer with a real PublishingSession and fake publisher.
- [ ] Implement validation and actor transitions. After every await check closed and
  cancellation before acknowledgment. Keep pending advice consistent when evaluate
  throws or deadline polling returns no new recommendation. Use fail-closed shutdown
  for dispatched errors; never stop live for predispatch validation failures.
- [ ] Generate owned Xcode project; run focused red then full Film model tests and
  Core tests sequentially with Xcode 26.2. Run combined unsigned Release. Obtain
  bounded independent review; add regressions for findings before fixes.
- [ ] Document evidence and integration limitations, preserve source/test hashes and
  commit verified changes. Next integrate source/pressure alignment, then actual
  automatic trial/rollback native media qualification before enabling capture usage.

Commands (all from the isolated worktree):
`xcodegen generate --spec ios/Project.yml`;
`DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination 'platform=macOS' -only-testing:ScorebugFilmModelTests/PublishingQualitySessionTests test`;
repeat without `-only-testing` for complete model suite;
`DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path ios/Packages/ScorebugCore`;
`DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.
