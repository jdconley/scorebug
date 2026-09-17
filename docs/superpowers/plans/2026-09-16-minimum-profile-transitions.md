# Minimum profile transitions implementation plan

Continue the approved progressive-streaming design with one controlled experiment:
240p → 540p → 240p. This qualifies encoder replacement and saved media continuity;
automatic adaptation and receiver wall-clock continuity remain separate gates.

Use explicit `SCOREBUG_TEST_PROFILE_TRANSITIONS=low240`, preserving `1` as the
existing 1080p → 540p → 1080p mode. An immutable Swift sequence supplies both the
publisher's initial profile and the driver's destinations. Keep the existing
20/40-second waits, 90–600-second hold, exclusive full-pipeline prerequisites,
independent archive and fixed 1080p worker canvas. Export version 6 raw frame
proof with `sequence: low240`. The caller must independently request this sequence
when qualifying evidence; old formats and wrong dimensions must fail that gate.

- [x] Add failing admission and version-6 qualification tests, including wrong
      sequence, raw-frame omission, old version and incorrect format rejection.
- [x] Implement immutable sequence, publisher/driver wiring, UITest propagation
      and caller-bound qualification. Preserve legacy output exactly.
- [x] Test minimum driver shutdown/export and mode validation. Run tooling and
      model suites, simulator build and unsigned combined phone/Watch Release.
- [x] Freeze runtime source inventory and run the actual 90-second minimum
      transition fixture. Verify native format/session receipts, complete source
      frame identities, audio markers, archive completion and full decodes.
- [x] Replay old transition evidence, independently audit new evidence and reject
      damaged variants. Preserve any failed runs; never loosen continuity gates
      to obtain a pass. Record results and commit this bounded checkpoint.

Run tooling with `pnpm test:tools`; model tests with Xcode 26.2:
`xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination platform=macOS test`.
Run `node scripts/test-native-app.mjs --streaming` with publication, processing,
direct RTMP recorder and blocks16 enabled, `PROFILE_TRANSITIONS=low240`, hold 90,
and the qualified slice decoder / 400ms peer latency / relative pacing options.
Keep fixed-profile, quality, probe and uplink impairment flags unset.

## Verified outcome

`native-app-MLneuc` passes the actual iOS 17.5 / iPhone 14 simulator experiment.
Native format evidence establishes 426×240 → 960×540 → 426×240 across three
separate encoder sessions, with 601 / 1,214 / 1,538 compressed frames. All 3,353
native source frames are consecutive. After the allowed 35-frame acquisition,
all 3,318 live frames (192–3,509) arrive and decode. The independent 1080p archive
retains 3,725 consecutive frames. All 61 archive and 55 expected live audio markers
match, and both complete-file decodes are clean. Source cadence is 30 fps in each
phase; this does not measure receiver wall-clock cadence during replacement.

Both replacements pause compressed output for approximately 414 ms. The native
completion gaps are 417/413 ms. These are still an explicit qualification gap for
smooth automatic adaptation; complete saved frames do not prove uninterrupted
real-time delivery. The existing production startup and automatic controller are
unchanged. Next implement and test the planned short delivery windows/watchdog,
minimum-reset priority and conservative recovery before another automatic trial.

All 1,205 tooling and 233 capture-model tests pass. The actual simulator workflow
builds and tests the app; the unsigned combined iPhone/Watch Release build passes.
The two retained controlled-transition runs replay with exactly unchanged results
and reject under the new minimum-sequence expectation. Independent verification
accepts the unchanged run and rejects 18 damaged variants.

The independent verifier initially assumed every encoder exits with code zero.
The actual worker stopped FFmpeg with an observed SIGTERM after source shutdown,
which returns 255; the existing lifecycle contract already allows this case.
The independent audit now reconciles the raw ordered stop/terminal/exit events,
telemetry EOF, saved final frame and successful recorder/wrapper exits. No runtime
qualification gate was changed to accept this run. All parent processes joined.

Runtime and evidence hashes are frozen in
`artifacts/qa/minimum-transition-final-verification.json`.
