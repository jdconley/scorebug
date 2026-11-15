# Decoder short-window measurement plan

Continue step 2 of the approved progressive-streaming design. The current five-
second report cannot prove one-second cadence or a no-new-frame stall. Add a
constant-space decoder observer using the existing framed PTS pipe. Retain the
latest complete one-second and two-second wall-clock windows independently and a
last-unique-PTS watchdog. Duplicate or reordered PTS cannot refresh that watchdog.
A new pipeline owns a new scope; missing first-frame evidence, invalid telemetry
and closed pipelines cannot report a live stall. Sample time advances windows even
without incoming data. Preserve the existing five-second reports unchanged.

These observations establish decoder arrival cadence only. Two-second counts are
not source loss or end-to-end lateness: that still requires expected source-frame
identity and a qualified latency mapping. This slice must not enable increases or
claim viewer delivery. Next carry short-window evidence through authenticated,
publication-scoped reports with transit age, then bind it into minimum-reset policy.

- [x] Write boundary, duplicate/reorder, stall, idle/closed, invalid-clock,
      malformed-pipe, sparse-poll and bounded-storage tests; observe failure.
- [x] Implement the observer and attach it to the actual pipeline's decoded pipe,
      expose a sampled snapshot and include terminal proof for diagnostics.
- [x] Verify pipeline ownership on normal, error and pre-spawn failure paths.
      Run all worker tests and typechecks.
- [x] Exercise actual FFmpeg decoder arrivals with a paced source, a source pause,
      resumed flow and joined shutdown. Preserve source hashes, raw snapshots,
      terminal evidence and independent cadence/watchdog reconciliation.
- [x] Update the main plan with exact results, remaining authenticated reporting,
      expected-source/lateness and policy integration gates; commit.

## Verified outcome

`DecoderCadenceTelemetry` now receives the actual pipeline's bounded framed PTS
pipe alongside the unchanged five-second telemetry. It retains two active/latest
window pairs, a unique-PTS progress watermark and a per-pipeline UUID. Polling
closes complete windows and detects a one-second decoder-arrival stall without
requiring another frame. Duplicate/reordered PTS do not reset progress; invalid
clocks/pipe data invalidate evidence; unstarted and ended owners cannot report a
live stall. Snapshot callers cannot mutate retained evidence. It owns no media,
threads, timers or publication lifecycle.

All 360 worker tests, worker typechecking and 1,205 tooling tests pass. Two existing
pipeline tests required explicit expectations for the new terminal field and a
stable injectable clock (the old test advanced five seconds per observer call).
Existing five-second report semantics and production quality behavior are unchanged.

Actual FFmpeg run `decoder-cadence-native-Q8lxKX` uses a paced local UDP source,
pauses only its owned sender and resumes it. All 478 accepted decoder frames are
retained in the independent frame history and decoded output. The observer records
661 snapshots and 22 unique complete windows. Independent reconciliation checks
all window counts/PTS against separately collected decoder arrival timestamps,
reconciles watchdog ages within a 1 ms observer-clock tolerance, and rejects ten
damaged variants. The watchdog appears 977.84 ms after the pause command because
the last decoded frame preceded that command; its measured progress age is at
least 1,000 ms. Progress returns within 26.06 ms of resume. The file fully decodes;
source, encoder, guardian and timers join, with observed SIGTERM/255 encoder exit.

The initial run `decoder-cadence-native-lSBPNy` failed orderly-shutdown qualification:
an idle UDP input did not unblock on SIGTERM and the guardian joined a SIGKILL.
Preserve that failed run and its fixture source. The successful fixture adds the
FFmpeg UDP protocol's explicit three-second read timeout; no runtime acceptance
rule was relaxed. This finite UDP observer experiment is not SRT/network, archive,
physical-device or full progressive-streaming qualification.

The measured startup burst reaches 187 fresh PTS in one second. This explicitly
shows why arrival counts cannot prove source timeliness or recovery eligibility.
The new data is currently local to the worker handle/terminal diagnostics; it is
not yet carried through authenticated media status or consumed by the phone's
quality controller. Next add that scoped/fresh reporting path, expected-source and
lateness reconciliation, and the priority minimum-reset policy. Preserve the
separate receiver-wall-clock gate from the controlled profile-transition test.

Evidence and source hashes: `artifacts/qa/decoder-cadence-final-verification.json`.
Reproduce the real decoder fixture with:
`pnpm --filter @scorebug/home-daemon exec tsx ../../scripts/test-decoder-cadence.mjs`.
