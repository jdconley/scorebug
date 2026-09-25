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
