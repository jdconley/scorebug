# Reliable native start intent

**Goal:** An enabled native Start streaming action survives background control
polling without overlapping control mutations or affecting the local archive.

**Evidence:** `artifacts/qa/start-intent-red.log` reproduces the existing UI path:
a gated worker-status poll disables `canStart`; a delivered async start action
returns while the poll owns control, leaving zero publisher starts. This proves a
model/UI race, not the precise cause of the earlier `native-app-4Ved1t` UI failure.

**Design:** Keep one synchronous UI request, scoped to the recording ID and tap
identity. A routine poll does not disable the start control. If a poll owns control,
show starting/waiting and retain that request; otherwise reserve the existing start
operation synchronously before launching its task. Poll completion releases control
before launching the retained request. Duplicate taps cannot enqueue duplicates.
Stop and recording changes discard queued intent. A failed control poll or unresolved
command/storage state ends queued intent with visible failure, requiring deliberate
retry. Setup editing is unavailable while a request is queued. Existing imperative
`startStreaming()` remains an awaited, immediate attempt for internal callers/tests;
the view uses the explicit synchronous `requestStartStreaming()` entry point.

Alternatives considered: accepting concurrent control mutations breaks command
serialization; changing only the async guard still allows button disablement and
task-scheduling races. No timers, automatic repeated retries or unbounded queue.

User authorization to continue the approved reliability work covers this bounded
fix. No protocol, network capability or quality policy changes are required.

## Implementation and verification

- [x] Reproduce the dropped action with a gated poll and real model.
- [x] Extract synchronous start reservation; wire the view to scoped queued intent.
- [x] Test immediate reservation, poll overlap, duplicates, stop, recording
      replacement (including reused ID/new tap), poll failure and unresolved state.
- [x] Run focused/full FilmModel tests and iPhone/Watch build.
- [x] Run the full owned native streaming fixture with existing archive, frame,
      audio, overlay, publication and cleanup gates unchanged.
- [x] Review cancellation/control ordering and document evidence.
- [x] Commit the verified fix.

## Results

The original gated-poll test fails three behavioral assertions with terminal exit
65; the replacement synchronous UI entry passes. The final FilmModel suite passes
107 tests, including ten new start-intent tests, terminal exit 0. The combined
unsigned iPhone/embedded Watch Release build passes. Independent read-only review
found no blocking issue; its unbounded-test-wait note is fixed. Additional tests
cover immediate Stop before the reserved task runs, storage failure/no automatic
retry, and unresolved command discovery during polling.

The full native workflow passes on iPhone 14/iOS 17.5 in
`artifacts/qa/native-app-8uryKd`. The archive retains all 1,909 frames (0–1908,
63.633 seconds); live retains all 1,495 acquired frames (228–1722, 49.833 seconds).
Both are 30 fps with zero missing frames within the measured source intervals.
The 60 encoded frames before live acquisition remain explicitly accounted for,
and the encoded tail is complete. Both A/V files fully decode; the score changes
350 overlay pixels and local recording continues after live stop. Maximum A/V
marker offsets are 0.021 ms archive / 64.917 ms live; end separations are 2.667 ms /
14.347 ms. Worker, encoder and recorder all exit 0. Nine completed decoder windows
associate with the actual relay reader/source and signed native attempt. Exact
owned simulator/container absence is independently verified after terminal success.

No media or UI gate changed. This fixture uses low-complexity diagnostic video;
it does not establish high-motion capacity, automatic quality adaptation, physical
camera/radio reliability or the exact cause of the historical missed UI tap.
Commands, source/evidence hashes and limitations are retained in
`artifacts/qa/start-intent-final-verification.json`.
