# Owned measurement app integration

Starting checkout `codex/local-validation`, `8d2886d`, in the local-validation
worktree. The preceding turn made verified progress: real physical Watch scoring,
reviewed application ownership and stop/restart fixes, 598 passing app-model tests
and a signed iPhone test build. No old test process or lab remains running.

The active goal still requires production progressive streaming and a complete
paired three-output pass. The pending Watch unlock question does not prevent
local implementation. No device test was restarted while that question remained
unresolved.

## Current implementation scope

Implement an explicit `SCOREBUG_TEST_OWNED_MEASUREMENT=1` route that connects Core's
measurement token to actual native probe operation handles, final-stage candidate
measurement, guarded application, joined cleanup and retry settlement. A thin
native wrapper avoids adopting the legacy fixture's global revocation and fixed
two-campaign scheduler. Session remains the single owner; the new wrapper routes
samples and supplies concrete publisher capabilities. Default callers retain
their existing behavior until full media qualification permits enablement.

Keep receiver/configuration/cost evidence, fresh recovery holds, source and
delivery watermarks, bounded allocation and actual cleanup requirements intact.
Do not substitute compatibility `acknowledge(nil)` for transferred measurement
failure settlement. Downward actions must remain available during cleanup.

## Native recovery experiment preflight

Fresh report: `artifacts/qa/owned-recovery-preflight-20260925.json`.
Installed available iOS/watchOS runtimes include 26.2 and 27.0; use 26.2 for the
existing qualified route. No runtime downloads or unrelated simulator deletions.

The prepared `prepared-native-capacity750-GM019e/input.mov` remains present:
330.010917 seconds overall, 1920×1080 H.264 at 30 fps plus PCM audio, 328,008,618
bytes. SHA-256 remains
`1b941060e76921c1dec03c8f9459baf5679aaf1b479fc0abb166b70575cf0a19`, matching
the earlier complete source qualification. Available storage is about 291 GB.
This verifies resource availability and identity, not a new decode or recovery run.

The prior `native-app-uG39s5` retains 2,356 cadence rows / 9,089,096 bytes and
325 delivery rows / 21,732,386 bytes. A longer run must retain the complete history
within the existing 3,072/512 row and 16/32 MiB limits. The new four-phase qualifier
must be distinct from the existing three-phase capacity and five-phase decoder
fault contracts; complete raw history cannot be sliced into artificial sessions.

## Host contract and source preparation

The separate `capacity750k-retry` selector defines a 750 kbps limit at 90 seconds,
restoration at 150 seconds and a 270-second hold. Selection requires the exact
owned-measurement flag, token-budget evidence and complete staged file route.
`owned240` uses format version 10 with exactly four native phases and three
receipts. Existing historical phase/version contracts remain unchanged.

Specification review found that the old three-phase qualifier could accept the
new profile name using a historical fixture. The preserved red regression uses
`measured-capacity-YnfAvU.json.gz`. The historical qualifier now explicitly rejects
that profile, and the runner rejects owned selection before allocating resources
until the new complete-history qualifier is wired. This is an intentional
incomplete-route guard, not a successful recovery run.

Verification logs under `artifacts/qa/`:

- `owned-recovery-contract-red-20260925.log`: initial contract regressions.
- `owned-recovery-contract-final-20260925.log`: 440 affected tests pass.
- `owned-recovery-historical-rejection-red-20260925.log`: preserved review regression.
- `owned-recovery-historical-rejection-green-20260925.log`: 106 tests pass.
- `owned-recovery-contract-tools-reviewed-20260925.log`: all 4,773 scripts tests
  pass after the review fix (`pnpm test:tools`, joined exit 0).

The specification reviewer approved the nine-file host slice and independently
passed 165 tests. Quality review also approved the final slice and independently passed 165 tests.
The host contract is committed as `91724e3`. Swift integration is still in progress;
its evolving source has not completed review or a new full native experiment.

The old 330-second fixture cannot satisfy the existing `holdSeconds + 90` input
guard for a 270-second experiment. Prepared and fully qualified a separate
390-second, 11,700-frame input without altering that guard:
`artifacts/qa/prepared-native-owned-recovery-hHjv1n/input.mov`.
SHA-256: `c1d0642bb102ca27733f39ece227c77135699e89f9ad29a67ddec34d5d2af814`.
The preparation folder retains full decode, per-frame identity, audio continuity,
commands, original-source hashes and verification. All four media subprocesses
joined with exit 0, and all five original source hashes remained unchanged.
Preparation log: `artifacts/qa/prepare-native-owned-recovery-20260925.log`.
This is input qualification only; the owned native recovery run remains open.

The user confirmed that new automation sessions can request the phone passcode.
Announce device testing before it starts and let the owner enter the passcode on
the phone. The pending Watch-readiness question remains separate from that fact.

## Next steps

Finish host quality review, commit the bounded contract, then finish and review
the actual Session/native lease integration. Build the separate whole-history
lifecycle, witness and policy replay before removing the runner guard. Run the
four-phase experiment with all three output files and complete media checks.

## Whole-history indexing and integration review

Added a separate bounded event index for the new owned measurement audit. It
retains original global event indices and all failed same-revision attempts,
requires immutable registration ownership and actual cleanup joins before
settlement/reuse, and allows only the final stopped owner to discard policy
without inventing a failure settlement. It deliberately returns false for native
probe, retry-policy and media qualification. Individual snapshots, costs, health,
application receipts and complete media still require the forthcoming replay.
The declared artifact limit is 8 MiB; harness preparse enforcement is not yet wired.

Red/green/final logs: `artifacts/qa/owned-history-index-{red,green,final}-20260925.log`.
Final focused tests: 35 pass, joined exit 0. Independent specification and quality
reviews approve this limited indexing scope. Quality review also exercised exact
16-owner/4096-event boundaries and invalid terminal suffixes. No old native
qualification gate was relaxed.

Preliminary app integration review identified and reported three concrete gaps:
stale downward requests revoking newer measurements before admission, strong
reader callbacks retaining stopped sessions, and advisory readiness expiry being
routed to fatal publishing shutdown. The implementer is adding deterministic
regressions and fixes before formal independent app reviews. Native three-stage,
joined cleanup and same-revision restart integration tests have initial passing
evidence; app implementation is not yet a reviewed or full-media checkpoint.

The native audit also needs raw pressure observations for independent candidate
cost replay, rather than a success boolean. Preserve actual pressure baseline,
renewal observations and final measurement pressure. The complete owned qualifier
must reuse candidate A/V/frame/resource arithmetic without manufacturing a legacy
single-campaign envelope or rewriting profile/source histories.

## Native stage replay checkpoint

Committed `74eadc4`: whole-history native probe replay over the original owned
audit. It checks captured configuration/publication, stage/campaign identities,
actual continuation terminals, cumulative/paced native acceptance, recovery
preflight observations, lease bounds and call-result timing. Failed allocations,
late returned handles and rejected renewals remain in the same history. A failed
renewal may have changed the actual native lease; the replay joins its terminal
snapshot to its original request/error interval. It never changes that failure
into a successful renewal or fabricates a legacy campaign envelope.

Specification review reproduced two clock gaps: a terminal snapshot could imply
a renewal after the error returned, and an unchanged deadline could bypass the
successful-renewal interval check. Quality review reproduced an impossible burst
that passed total-since-start accounting, and candidate binding after retirement
was requested. All four have deterministic red regressions and reviewed fixes.
The final native-plus-index suite passes **74 tests**, joined exit 0. Both reviews
approve this native-only checkpoint; it grants no receiver capacity, candidate,
retry policy, application or media qualification by itself.

Evidence under `artifacts/qa/`: `owned-native-probes-final-20260925.log`; preserved
red logs include `owned-native-probes-rejection-clock-red-20260925.log`,
`owned-native-probes-unchanged-lease-red-20260925.log` and
`owned-native-probes-quality-red-final-20260925.log`. Earlier initial, terminal,
renewal, failed-renewal and context logs remain. The existing 4,773-test full tools
pass predates the index/native-probe modules; do not present it as a new full-suite
count for these changes.

## App checkpoint and remaining review blocker

The implementer committed `c76b3b6`. Inspected and retained its original test logs
from `/tmp` in `artifacts/qa/c76b3b6-scorebug-owned-*.log`; hashes and source paths
are in `c76b3b6-imported-verification-logs.json`. These are preserved existing runs,
not reruns. They show 612 FilmModel tests, 491 Core tests, 245 Streaming tests, an
arm64 simulator build and a separately strengthened Driver-led same-revision
native retry test passing. The application test uses the actual owned SRT bridge
and SDK probe with a deterministic typed candidate result; it is not proof of
real candidate encoding, capacity recovery or complete media.

FilmModel command: Xcode 26.2 `xcodebuild test -project ios/Scorebug.xcodeproj
-scheme ScorebugFilmModelTests -destination 'platform=macOS' -derivedDataPath
ios/DerivedData/FilmModel CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`.
The focused command adds
`-only-testing:ScorebugFilmModelTests/NativeOwnedCandidatePublisherTests/testActualOwnedSRTStagesJoinAndRetryOnSameRevisionAfterFreshHealth`.
The simulator build uses scheme Scorebug, `generic/platform=iOS Simulator`,
`ios/DerivedData/App`, `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO`.
Core/Streaming ran `swift test` in their respective package directories.

Independent app specification review found one blocking gap: Session released its
busy flag after a safe guarded rejection, but Driver.tick still awaited that
application and coalesced away subsequent health ticks while measurement cleanup
was held. The direct-Session regression could not detect this. The implementer is
adding a Driver-led test and a tracked cleanup/settlement continuation. A narrow
exact-token Core transition is authorized to record the already-proven no-effect
rejection before cleanup: withdraw only the matching active application, retain
the transferred token, and do not count failure, grant health or fabricate reset.
Actual failure settlement still requires joined cleanup. Review and all affected
verification must pass after this fix. Production enablement and the complete
four-phase experiment remain open.

## Driver rejection fix reviewed; native diagnostic started

Commit `a278c0c` resolves the Driver cleanup blocker. Specification re-review and
independent Swift quality review approve the integration. Verification: 614
FilmModel tests, 492 Core tests and arm64 simulator build passed. Existing run
logs were imported from `/tmp` with SHA256 provenance in
`artifacts/qa/a278c0c-imported-verification-logs.json`; these are not new reruns.

Root enabled the existing explicitly non-passing `--capacity-diagnostics` workflow
for exact owned mode and forwarded its flag through Xcode/UI launch. Normal owned
qualification remains rejected until whole-history replay exists. The audit index
accepts actual `applicationRejected` records before or after cleanup, without
granting policy or media qualification. 145 focused script tests pass after red
regressions. Diagnostic `native-app-6M1CiA` is running on iOS26.2 with the prepared
390-second source, a 270-second hold, 750 kbps restriction/restoration and proxy
recording. Its outcome is pending; success collecting raw artifacts will still
produce an intentional nonzero verdict.

## First real owned diagnostic result

`native-app-6M1CiA` completed its UI workflow (355s) and joined all resources; the
outer runner exited1 intentionally because diagnostics cannot qualify recovery.
`capacity-diagnostics.json` has no collection errors. Source stayed240p: six
measurement registrations, five completed121-frame candidate encodes, no applied
upgrade. All958 raw lifecycle events are closed, within bounds and retained.

Two integration defects explain the result. Owned native probes emit campaign-v3
packets, but the fixture selected staged-v2; all2960 worker responses lacked
receiver-probe evidence. Reviewed fix `2b31c95` selects campaign-v3 for the exact
owned retry route while preserving legacy tags. Each completed candidate also
arrived with source coverage2.86–3.03s old; the next report arrived3.61–3.96s later,
after its2s cost freshness expired. A real-duration source-aligned scheduling
regression/fix is underway; no freshness bound is being relaxed.

Full decoding succeeded for all three MP4s. Clean archive:1920x1080 H264/AAC,
9280frames/309.33s. Both overlaid outputs:640x360 H264/AAC,8822frames,~295.3s
including audio; maximum decoded video timestamp gap34ms, no gaps over100ms.
These are decode/timestamp results, not fresh-content identity or A/V-sync
qualification. Spot checks show visible volleyball footage, clean archive and
live HOME1–0 overlay. Evidence:`diagnostic-media-decode.json`,
`diagnostic-frame-summary.json`,per-output frame JSON,decode logs and sample JPGs.
Failure preservation marked incomplete only because duplicate`QA/input.mov`
exceeded its1GiB budget; the original prepared input and artifact-root`input.mov`
remain retained. Every recording and other QA file was copied.

After diagnostic/relay changes, full`pnpm test:tools` passes4852tests, joinedexit0
(`repeated-live-checkpoint-owned-diagnostic-tools-20260925`). Native-only replay
of the unmodified real958-event audit passes all six attempts after recognizing
actual`policyState` observations. This grants no receiver capacity,retry policy
or media qualification.
