# Native scoring recovery after an applied point loses its reply

Starting checkout: `codex/local-validation`, `402aa0e`, clean. Prior turn made verified progress. No hardware or unrelated media/Watch tests run.

## Change and design

Added a test-only loopback HTTP proxy around the actual local API. It forwards the first native award-point command, consumes the successful real server reply, then destroys the client response. It holds an explicit503outage until the UI test has terminated/relaunched the app and observed its restored pending action. Restoring the connection leaves all receipt lookup/reconciliation to the production native scorer. No production route, storage or command behavior changed.

The existing native scoring harness uses the same ScoringModel/NativeScoringView/Core code as Scorebug, normal Keychain credentials and JSON outbox. Its new lost-reply scenario checks disabled scoring while pending, persistence after process relaunch during outage, original receipt recovery to1–0, undo to0–0 and match end. The host independently checks the actual SQLite commands: exactly one award-point, one undo and one end, and a successful GET of the original command receipt.

`test-apple.mjs --ui-only` skips unrelated shared/model suites and unsigned physical-device builds while retaining the selected actual native test. `--lost-reply` keeps its database and fault/receipt evidence under an owned artifact directory. The test proxy restricts its target to127.0.0.1, bounds requests/time/audit history, never logs authorization headers, and stops owned connections.

## Verification and collection limitation

- Two focused proxy checks pass: actual HTTP reply destruction/blocked receipt/read recovery, and rejection of non-loopback targets. Initial missing-module failure preceded implementation.
- Native run `native-scoring-recovery-jpOJCg`: iPhone14/iOS26.2, one XCTest passed, zero failed/skipped,64seconds. Real API/SQLite proves exactly three intended commands, one applied point, and recovery through the original UUID receipt. Captured screenshots show pending state after relaunch and final completed workflow. No camera permission flow.
- **Original runner exit1 is preserved.** After the successful XCTest and database assertions, Xcode had shut down the simulator and `get_app_container` failed. The original cleanup deleted this test-owned simulator, so post-test app-data copy is unavailable. This does not negate the observed native relaunch or durable server receipts, but no copied-outbox artifact is claimed.
- Independent `native-acceptance.json` verifies the actual xcresult counts, saved fault audit and SQLite command rows; it explicitly separates the native/API pass from failed collection. The collector now boots the same owned simulator before accessing its container and preserves it on future collection failure. Syntax/diff checks pass; no full rerun merely for this collection correction. Complete runner collection after that correction remains unverified.
- All child processes joined; no live simulator/lab from this run. Source footage/recordings/other simulators untouched.

Command: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer SCOREBUG_IOS_DEVICE_TYPE=iPhone-14 node scripts/test-apple.mjs --lost-reply --ui-only`. Captured console: `artifacts/qa/native-scoring-lost-reply.log`; per-run database, fault audit, receipt evidence, acceptance summary and xcresult remain in the artifact directory above.

## Next

Native takeover while an unresolved command exists and stale-command handling remain separate integration cases. Then add missing full-app source-interruption and low-space/queue-pressure checks using existing factories/runners. Reuse the successful native lost-reply result; do not repeat full unrelated suites.
