# September 28 — bounded publisher DTS interleaving

Starting `3c7ce11`, clean. Previous turn made progress: crash-surviving numeric
packet-tail evidence and a live boundary reproduction. No owned jobs carried over.
Hardware remains deferred; no agents, full UI suite, soaks or external broadcast.

## Cause and design

TSWriter emitted each compressed packet immediately in codec callback order after
startup. The new focused tests reproduce audio running ahead of available video,
video running ahead of available audio, and reversed global decode order.
[FFmpeg's muxing documentation](https://ffmpeg.org/doxygen/trunk/group__lavf__encoding.html)
describes buffering/interleaving by decode timestamp as the standard alternative
to direct callback-order writes. This informed the implementation, not its result.

Dual-track TS output now holds the leading track until both have observed the
relevant unwrapped90kHz decode ticks. Source PTS/DTS, composition offsets, transport
clock and codecs remain unchanged. Limits:256compressed PES,8MiB aggregate and
2seconds track lead/queued span. Count/byte/time/backward-DTS failures are explicit;
clean finish drains all accepted packets, clear/abort retires queued data and track
clocks. Single-track output stays immediate. Bounds documentation now includes the
additional8MiB maximum (102MiB summed logical queue ceilings, not process RSS).
Candidate cost measurement uses the identical writer, with no admission credit
from the new queue.

## Focused checks and fixture adjustments

Two baseline regressions failed on immediate emission and reversed decode order
(`/tmp/scorebug-interleave-red.log`, copied into the capture artifact).
The first batch caught fixtures assuming callback-order immediate delivery and
candidate count fixtures feeding seconds of one track before its counterpart.
Payload/counter fixtures now call clean finish before final assertions; candidate
count fixtures advance both tracks while preserving all original count/byte bounds.
The startup test now explicitly requires its video packet rather than skipping its
checks when absent. No accepted-payload, timestamp, overflow or count assertion
was weakened.

Final57SDK tests in TSWriterStartupTests/CandidateTransportMeasurementTests pass,
including finite interleave limits, reverse DTS, clear, single-track/pump behavior
and clean drain. Handle3293 exit0,0.974s test execution, incremental build reused.
No unrelated XCTest/UI tests were run.

## One live comparison and complete saved media

Capture90068 exit0: `headless-native-a1rmZ9`, lab`device-lab-6UUHJ5`.
Same70s prepared1080 fixture, software proxy, workerSIGKILL15s and
`--packet-timing on` as the preceding diagnostic. Normal policy remains at its
startup profile for this short crash lane; this is not ladder qualification.
Native archive export reused the just-built bundle; export/media55916 exit0.

- Clean archive:2123consecutive frames0–2122,37verified segments, gap-free audio.
- Both live outputs:62–443 then962–2102, identical sequences;518missing live frames
  during the17.267s worker outage. No internal frame-identity or audio timestamp gaps.
- All five saved MP4s fully decode. Interrupted outputs have59.159ms extra audio;
  recovered≤16.889ms, archive16ms. Archive continues20frames beyond final live video.
- Exactly one Start/Stop broadcast, automatic worker recovery; cleanup[].

`interleave-acceptance.json` binds diagnostics, producing source, media, native
manifest verification and cleanup; `producing-interleave.patch` retains the actual
production delta. No source edits occurred during capture/export. No full-match,
physical, simulator-collapse, other-backend or general abrupt-tail bound claim.

Important refinement of the preceding diagnosis: the interrupted FFmpeg demux
observations still end with71.978ms extra audio, while its mux observations end
with50.658ms. These per-track concurrent logs are not an ordered wire capture and
cannot prove that the publisher sent audio first or that the entire lead originated
upstream. The preceding report's50.655ms should be read as the observed demux-track
boundary, not proof of physical arrival order. Current unit evidence proves local
DTS emission order; the saved media establishes this run's result. The59ms versus
prior84–107ms comparison is not an isolated causal guarantee across kill timing/load.
The recovered diagnostic report retains one malformed row and remains explicitly
invalid; its saved media passes independently.

## Provenance and next work

The existing saved vendor patch already failed reverse-apply against HEAD's
SRTStream before this change. Refreshed only SRTStream/TSWriter hunks against exact
pinned upstream revisiondc880cb540b8feeb98f64e8b7dcfaaf320b6b2bd, verifying each
original SHA-256 before generating the diff. All162original hashes and exact
patch reverse/forward round trip now pass. Context-only blank patch lines were
normalized to the existing format; `git diff --check` passes.

Keep the interleaver and its focused/short-media evidence. Do not rerun this crash
unchanged. Remaining simulator/backend limits and the general abrupt-tail gate
stay open. If the tail needs further investigation, inspect FFmpeg's per-track
shutdown/decoder queues or collect an ordered transport observation; do not treat
independently logged demux rows as wire order. All jobs are joined.
