# September 25 checkpoint: Guarded PublishingSession rejection and joined timers

**Imported history, not a reconstructed whole session.** Extracted during plan cleanup from [guarded admission](../superpowers/plans/2026-09-25-owned-application-admission.md#publishingsession-checkpoint) at `b65ca7fe1d58be9ac27e88a63c67867d428f1b10`. Original session boundaries/times are unknown. Implementation commit: `b65ca7f`. Results below describe that checkpoint, not a new verification run. Repository-relative artifact paths are rooted at the checkout; ignored artifacts may exist only in the original workspace.

## Recorded commands and results

- `artifacts/qa/repeated-live-checkpoint-guarded-session-film-model-full-20260925-exit.json`: `["xcodebuild", "-project", "ios/Scorebug.xcodeproj", "-scheme", "ScorebugFilmModelTests", "-destination", "platform=macOS", "-derivedDataPath", "ios/DerivedData/FilmModel", "test", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]`; exit `0`, joined `True`.
- `artifacts/qa/repeated-live-checkpoint-guarded-session-media-full-02-20260925-exit.json`: `["swift", "test", "--package-path", "ios/Packages/ScorebugMedia"]`; exit `0`, joined `True`.
- `artifacts/qa/repeated-live-checkpoint-guarded-session-media-full-20260925-exit.json`: `["swift", "test", "--package-path", "ios/Packages/ScorebugMedia"]`; exit `1`, joined `True`.
- `artifacts/qa/repeated-live-checkpoint-guarded-session-profile-baseline-20260925-exit.json`: `["swift", "test", "--package-path", "artifacts/qa/guarded-session-baseline-055b0b5/ios/Packages/ScorebugMedia", "--filter", "PublishingProfileUpdateTests"]`; exit `0`, joined `True`.
- `artifacts/qa/repeated-live-checkpoint-guarded-session-profile-ordering-20260925-exit.json`: `["swift", "test", "--package-path", "ios/Packages/ScorebugMedia", "--filter", "PublishingProfileUpdateTests"]`; exit `0`, joined `True`.
- `artifacts/qa/repeated-live-checkpoint-guarded-session-streaming-full-20260925-exit.json`: `["swift", "test", "--package-path", "ios/Packages/ScorebugStreaming"]`; exit `0`, joined `True`.

## Decisions, verification, failures and next work (imported)

Explicit guarded Session overloads now carry the expected receipt through the
shared mutation slot. Only a typed rejection from the direct guarded publisher
call can resolve the request without shutdown. Resolution is atomic with the
request identity and deadline check; the external waiter joins its exact timer
before releasing the slot. Deadline, cancellation or stop that already won keep
their terminal outcome. Expiry after safe resolution cannot turn a held timer
join into a new timeout.

Successful receipts are checked against the explicit expected generation,
encoder, configuration identity and source/time ordering even without previous
Session history. Malformed successful results remain uncertain and terminal.
Legacy calls retain their terminal error behavior. A replacement selector does
not prove that the caller owns a partially applied upgrade; the app must enforce
that broader application contract separately.

The 13 new guarded tests and existing capability/bitrate/profile tests pass
(**35 focused** before the additional profile-ordering regression). The final
full suites pass **271 Media tests** (205 XCTest and 66 Swift Testing) and
**245 Streaming tests**. The macOS native app model suite also passes all
**583 tests** after rebuilding against the current packages. Every final job
joined with exit 0. Root review checked the catch boundary, exact timer
ownership and shutdown dependencies. After the account reset, independent
specification and quality reviews approved the exact manifest-bound source/test
files with no findings. The owned app route still requires its separate integration
and end-to-end qualification.

The first full Media run found an existing test's uncontrolled race between the
health monitor and post-profile health validation. Both stop paths preserve the
first terminal outcome; that assertion assumed mutation validation always won.
The fixture now holds the monitor after its initial healthy read for the strict
mutation-validation assertions, and a separate test forces the monitor to win
while verifying the outstanding write is joined. Production failure precedence
and the strict expected outcomes were not relaxed. The original failure log is
preserved. All **8 profile tests** also pass against unchanged Media sources from
`055b0b5` with only the deterministic test fixture applied, confirming the existing
first-terminal-result contract. That isolated source copy and fixture hash are in
`artifacts/qa/guarded-session-baseline-055b0b5/fixture-provenance.json`; its joined
result is `repeated-live-checkpoint-guarded-session-profile-baseline-20260925`.
The original nondeterministic failure itself was not forced against that baseline.

Evidence:
`artifacts/qa/guarded-session-{red-03,red-04,focused-final-01}.log`,
`artifacts/qa/repeated-live-checkpoint-guarded-session-profile-ordering-20260925{.log,-exit.json}`,
`artifacts/qa/repeated-live-checkpoint-guarded-session-media-full-20260925{.log,-exit.json}` (failure),
`artifacts/qa/repeated-live-checkpoint-guarded-session-media-full-02-20260925{.log,-exit.json}` (pass), and
`artifacts/qa/repeated-live-checkpoint-guarded-session-streaming-full-20260925{.log,-exit.json}`, and
`artifacts/qa/repeated-live-checkpoint-guarded-session-film-model-full-20260925{.log,-exit.json}`.
The changed source/test hashes and final exit records are recorded in
`artifacts/qa/guarded-session-verification-manifest-20260925.json`.

## Current handoff

Both independent reviews approve this checkpoint. Later checkpoint counts supersede earlier counts; full app integration and fresh automatic post-restoration qualification remain open. Current immediate priority is the authorized physical vertical in [NEXT](NEXT.md).
