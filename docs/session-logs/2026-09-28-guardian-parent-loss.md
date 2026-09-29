# September 28 — guardian survives parent loss without breaking encoder writes

Starting `codex/local-validation`, `77721ed`, clean. Previous goal turn made
progress by changing the iteration policy/docs. No running jobs carried over.
This session changes production pipe ownership and uses only targeted checks.

## Confirmed defect and fix

FFmpeg inherited the worker's progress, decoded telemetry and encoder timing write
ends through the guardian. Worker SIGKILL removed their readers. Existing tests
only established eventual encoder termination, not successful final writes.
Three new real-process cases, one per encoder descriptor 1/3/4, all reproduced
`EPIPE` during the TERM handler before the fix.

The guardian now owns these readers, forwards with normal stream backpressure
while the worker lives, and discards telemetry after parent disconnect. It still
sends TERM and retains the configured KILL deadline. Completion joins forwarding;
a 250 ms post-exit drain bounds inherited descriptors or a stalled parent. Raw
stderr stays private and the actual encoder exit status remains authoritative.
No media timestamps, encoder defaults, archive or adaptive policy changed.

## Verification

- Red: `pnpm --filter @scorebug/home-daemon exec vitest run
  test/pipeline-process.test.ts -t 'keeps encoder descriptor'`: three failures,
  each actual `EPIPE` rather than expected final write.
- Green: same package, `vitest run test/pipeline-process.test.ts
  test/pipeline-terminal-failure.test.ts`:45passed in15seconds, process97296 exit0.
- Worker typecheck initially caught a missing `Promise<void>` JSDoc annotation;
  corrected, `pnpm --filter @scorebug/home-daemon typecheck` passed,80947 joined0.
- Changed source/tests formatted; `git diff --check` passed.

Short representative1080 file comparison uses production FFmpeg arguments with
realtime input, software output, encoder timing, and actual worker SIGKILL at
roughly180output frames. Baseline is the guardian from77721ed; new is the working
source. Script/artifacts: `artifacts/qa/guardian-drain-20260928/compare.mjs` and
`run-kQF0u8/result.json`. Command: `node --import
./apps/home-daemon/node_modules/tsx/dist/loader.mjs
artifacts/qa/guardian-drain-20260928/compare.mjs`.87112 joined0.

Both before/after MP4s fully decode, both guardians exit. Baseline198video frames,
1.758ms audio tail; new197frames,11.848ms tail. Kill triggers differ by one progress
frame (183/182); this is not a frame-loss comparison. Both tails are short, so
this file-input experiment does not reproduce or prove the cause of the retained
live107ms/508–548ms tails. The demonstrated improvement is successful final writes
after worker death, not a claimed A/V improvement or general live bound.

No simulator/hardware/full suite/soak run. No Downloads changes. No jobs active.
Next isolate the live input/output timeline at crash using retained data where
possible; do not repeat unchanged file comparisons or alter timing heuristically.
