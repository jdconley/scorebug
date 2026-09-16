# MPEG-TS padding probe implementation plan

> **For agentic workers:** Use superpowers:executing-plans for the already authorized continuation in the isolated local-validation worktree.

**Goal:** Qualify disposable padding on a real local MPEG-TS A/V SRT connection before adding it to the native publisher.

**Architecture:** A finite replay sender prioritizes original MPEG-TS packets and adds seven-packet null messages on the same socket. A native lease bounds extra traffic independently of the parent controller. The receiver records raw delivered transport bytes before demux. The runner compares complete accepted and received streams and decodes both tracks. This is a transport/media primitive; no upward admission or production behavior changes.

**Tech stack:** C++17, installed SRT, FFmpeg H.264/AAC fixture, Node owned processes and existing UDP impairment proxy.

## Design decisions and limits

- Use the same null packet shape as [FFmpeg's MPEG-TS muxer](https://www.ffmpeg.org/doxygen/7.1/mpegtsenc_8c_source.html): `47 1f ff 10`, followed by 184 `ff` bytes. Null packets do not carry a new elementary stream, timestamp, or score.
- Keep this first integration in a finite replay tool. The Swift publisher's serialized writer, GoSRT relay, slow receiver feedback and native archive must subsequently be qualified together. Do not treat this laboratory as that qualification.
- The pinned source fixture has a 3.5 Mbps constant mux rate; replay eligibility follows source byte position at that rate. Original media wins each iteration. A stalled loop never accumulates more than one padding message of tokens. Probe rate is accounted SRT/UDP/IPv4 traffic (1316 + 44 bytes), capped at 2 Mbps, with a 300 ms renewal lease, 16 MiB total padding bound and 60-second attempt limit.
- Native local pressure stops padding: stale (>100 ms) observations, RTT/send buffer above 50 ms, or new retransmission/drop counters relative to the start. Terminal withdrawal is sticky. Baseline media continues. One probe attempt per owned connection avoids inventing a receiver stage identity from null packets.
- Set and verify an SRT stream ID containing the random run identifier. Count all received TS packets and null packets, but never present total null packets as probe-only delivery: the source mux itself contains nulls. Save the complete accepted stream as the expected receiver bytes; compare byte for byte after drain. Remove null packets only for a separate source-versus-delivered elementary transport comparison.
- Bound source input to 16 MiB and expected/received memory to 32 MiB, command input to 4 KiB / 2048 commands, native lifetime to 30 seconds. Persist media only after sockets close. Parent joins exact owned process groups on success, cancellation, timeout and pipe failure. No external network or deployment.

## Execution

- [x] Create `tools/capacity-probe/mpegts-padding-test.cpp` for the packet shape, TS validation, lease expiry/late renewal, exhausted budget, stalled pacing, pressure/counter/freshness failures and sticky terminal state. Run the compiler/test and retain the causal failure before adding `mpegts-padding.h`.
- [x] Implement `tools/capacity-probe/mpegts-padding.h`: `nullMessage()`, `transportCounts(data,size)` and `PaddingLease(rate,now,retransmitted,dropped)` with `renew(now)`, `ready(now,stats)`, `accepted(now)`. Use monotonic, finite timestamps and checked counters. Run native unit assertions with warnings as errors.
- [x] Add `tools/capacity-probe/mpegts-probe.cpp` with `sender PORT RUN_ID SOURCE EXPECTED` and `receiver PORT RUN_ID OUTPUT`. Commands are `start`, `probe BPS`, `lease`, `stop`. Own one nonblocking SRT connection and serialize original/padding sends; accept only regular bounded input/output files. Retain 50 ms timestamped telemetry, source acceptance, null counts, pressure withdrawal reason and terminal cleanup.
- [x] Add `scripts/test-mpegts-probe.mjs` and `test:mpegts-probe`. Generate one 12-second 720p30 H.264/AAC source with 3.5 Mbps mux rate. Sequentially exercise baseline, renewed padding then withheld lease, and 4 Mbps constraint with 2 Mbps extra offered load. Capture unchanged runtime source hashes, versions, native rows, accepted/received bytes and complete proxy timelines. Decoder qualification requires both tracks, 360 video pictures, matching decoded A/V frame hashes and matching packet timestamps. Preserve initial failures as failures.
- [x] Run tooling tests and the complete maintained media experiment. Review the source and independently recalculate byte/null accounting, lease cessation/media continuation, decode equivalence and cleanup. Update the parent plan and tool README with actual results and explicit remaining native/relay/archive gates. Hash terminal evidence, then commit the checkpoint.

## Acceptance

All original non-null TS bytes must match the delivered stream, all accepted transport bytes must arrive exactly, and decoded audio/video must be identical across source and padded deliveries. The lease and pressure cases must withdraw padding while media continues, without resetting the source or changing its profile. No result from this plan enables adaptation or claims a usable video capacity.


## Reviewed result

Authoritative run: `artifacts/qa/mpegts-probe-TZgGv9`. Source snapshot hashes for all 11 runtime/test dependencies remain unchanged. Installed SRT headers and runtime both report 1.5.6. The source is 5,252,344 bytes containing 13,487 existing null packets. Each of the three scenarios delivers the entire accepted transport stream exactly; every original non-null TS byte is preserved. FFmpeg decodes 360 video pictures and 564 audio frames with identical hashes, timebases and timestamps in source and all deliveries.

- Baseline adds no padding.
- The lease case adds 250,040 bytes (190 seven-packet messages), then stops 0.40 ms after the last processed 300 ms lease deadline. The last successful send completion precedes expiry by 3.40 ms. A further 2,958,556 original source bytes arrive unchanged.
- The 4 Mbps case adds 153,972 bytes (117 messages), then withdraws on an actual 58.657 ms RTT and 47 ms send buffer, 0.705 seconds after probe start. The pressure observation is 0.19 ms old at withdrawal. All 3,625,768 remaining source bytes arrive. No additional padding is accepted after withdrawal.

Both directions in all three proxy runs reconcile over 124 bins each, with zero overflow/injected/oversize/close drops and no pending traffic or proxy errors. The constrained forward queue reaches 214.722 ms residence. This is exact eventual delivery, not a live cadence/freshness pass. All six native owners finish on requested stop, exit zero and are joined; all 11 build/generation/decode commands complete successfully.

All 1085 tooling tests pass, including 24 new evidence/cleanup tests; native packet/lease assertions compile with `-Wall -Wextra -Werror` and pass. Review found persistence-before-join and unverified-withdrawal-cause defects. Both were reproduced by causal regressions and fixed; targeted re-review reports no remaining blockers. A final parent review records last padding acceptance at send completion rather than call entry. The final rerun includes that correction. Earlier successful prototypes (`WWmgo0`, `8Zkvo2`) are retained separately and are not the authoritative final run.

Independent verification in `artifacts/qa/verify-mpegts-probe-evidence.py` rechecks the raw media, frame hashes, pressure cause, deadline history, counter monotonicity, source snapshots and proxy conservation without importing the runtime qualifier. Its result is saved inside the final run. Terminal source/evidence hashes accompany this checkpoint.

## Next integration

Keep production adaptation disabled. Port the bounded media-priority primitive into the Swift publisher's existing serialized transport consumer, with publish-generation ownership and finish/cancellation joining. Add authenticated attempt/connection-bound receiver accounting before GoSRT demux. Ordinary nulls cannot identify probe stages; choose and validate an explicit stage protocol or bounded cumulative counter intervals before using delivered padding to admit a candidate. Preserve source collection time and distinguish the fast local lease/pressure path from receiver feedback observed around 1.65 seconds old.

Then run native simultaneous archive/live media with competing traffic, delayed/lost feedback, abrupt capacity reduction and recovery. Require current-profile media freshness, unique pictures, cadence, A/V coverage and archive integrity, plus measured candidate encoder/audio/transport cost and transition margin. This replay does not change or requalify the native camera/archive, physical Watch/phone networking, remote hosts or long soaks.
