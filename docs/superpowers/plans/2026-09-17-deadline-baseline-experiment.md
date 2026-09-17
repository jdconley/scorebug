# Deadline baseline and pause experiment

Continue the approved progressive-streaming plan from checkpoint `d137036`.
The previous actual run found conservative arrival-latency upper p99 of 1.201 s
among matched frames, with no proven healthy windows at a one-second deadline.

Use an explicit test-only `SCOREBUG_TEST_DELIVERY_DEADLINE_MS=1500` override.
Absent override preserves the original one-second experiment. Accept only exact
`1000` or `1500` in the existing cadence/controlled-pause fixture, through the
harness, Xcode scheme, UI test and native fixture. Keep the 250 ms freshness cap,
400 ms SRT peer latency, relative pacing, slice threading, fixed 240p30 upload,
1080p archive and owned two-second decoder pause unchanged. Production behavior
does not change. The verifier must require the independently specified budget;
changing a saved audit budget cannot silently reinterpret it.

- [x] Add failing native and Node budget-validation tests; implement exact fixture
  option propagation and independently requested verifier budget.
- [x] Run focused tests and generate/build the native project. Freeze runtime
  source hashes before a new actual simulator capture; preserve all prior evidence.
- [x] Require healthy source windows in each lane, fault observations and clean
  archive/media in the new run. Inspect unknowns and latency intervals. Associate
  fault windows with decoder progress evidence without mixing clock epochs or
  counting overlapping lanes twice.
- [x] Independent spec/quality review; full relevant tests and simulator/unsigned
  phone/Watch builds. Save evidence and commit the verified result or diagnosed
  limitation. Keep adaptation/recovery gated until their own qualifications pass.

## Result

Actual iPhone 14 / iOS 17.5 simulator run `native-app-AozzeP` passes the new
baseline/failure gates. Of 151 windows, 136 are independently classified and
15 are freshness-unknown. The one-second lane contains 87 healthy windows,
one below-24-FPS window and one additional 25-FPS window. The two-second lane
contains 44 healthy windows and one fully classified 12.5-FPS window with
35 missing frames out of 60 (58.33%). Two other windows contain uncertain
arrivals and do not establish health or a precise FPS. These lanes overlap;
their frame counts are not independent observations.

The owned decoder pause lasted 1.965 seconds. In the one-second lane, all 35
missing-at-measurement frames and nine conservatively late frames lie within
two source seconds after the last stalled decoder PTS. Native timestamps and
PTS establish this association without mixing the Node fault clock epoch.
After the fault, a continuous 31-second span proves healthy receiver delivery;
freshness-unknown windows break, rather than extend, healthy spans.

The independent archive fully decodes at 1920×1080 with 3,678 frames, 61/61 audio
markers and successful finalization. The live MP4 fully decodes with 3,289 frames,
54/54 audio markers, approximately 30 FPS and zero eventual source loss. Catch-up
does not repair the measured deadlines. Matched one-second-lane arrival upper
latency p99 is 1.195 seconds, consistent with the previous run; the larger budget
separates normal delivery from the injected disturbance.

All 372 Core, 274 native model and 1,317 tooling tests pass, alongside ARM64
simulator build-for-testing and unsigned combined iPhone/Watch Release builds.
Independent spec and quality reviews found no important gaps. All 303 frozen
evidence files from the previous checkpoint remain unchanged. Evidence:
`artifacts/qa/deadline-baseline-final-verification.json`.

This qualifies this simulator fixture's healthy/failing delivery measurement at
1.5 seconds. It does not qualify automatic adaptation, controller recovery,
candidate bandwidth/headroom, a production deadline, physical devices or remote
workers. Next bind the one-second floor and two-second loss failures to scoped
minimum-reset decisions, preserving reset precedence and avoiding double recovery
credit. Qualify actual reset writes and recovery separately.
