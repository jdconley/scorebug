# Bounded SRT capacity probe design

The previous simulator experiment proves that the packet-pair bandwidth gauge is unsuitable for upward admission in our local setup. The objective remains the highest sustainable A/V quality with independent reliable recording. We need direct evidence that additional traffic arrives before changing video geometry.

## Alternatives and decision

Using a conservative multiplier on the existing bandwidth gauge remains unsupported: the constrained interval's minimum estimate still exceeds the actual limit by an order of magnitude. Repeating a full resolution trial causes the already observed picture/audio damage. Use a bounded load ramp on the publishing transport, with receiver-delivered byte counts and fast sender pressure withdrawal, as the next experiment.

The first implementation is an isolated loopback laboratory using the installed native SRT library and the existing UDP impairment proxy. One SRT connection carries two labeled message classes: fixed baseline traffic and additional probe traffic. This is an actual SRT transport experiment, not encoded video. It establishes transport behavior before any Apple SDK, media muxer, archive or production policy integration. Installed SRT version and source/build hashes are retained; this library may differ from the iPhone SDK and GoSRT relay.

## Components and ownership

- `tools/capacity-probe/srt-probe.cpp`: a loopback-only sender or receiver with nonblocking bounded I/O, timestamped JSON observations, and a small stdin command protocol. Messages have a per-run identifier, stage, class and monotonic sequence. The receiver counts unique delivered messages and visible discontinuities, never proxy send attempts. Native sender gauges expose RTT, sender-buffer duration, retransmissions and drops. The packet-pair estimate is not used for decisions.
- `scripts/capacity-probe-policy.mjs`: a pure state machine. It increases extra traffic in small fixed steps only after sustained matching-stage delivery. It stops on stale/contradictory feedback, sequence loss, queue/RTT pressure, exhausted byte/time/stage limits, or cancellation. A successful result states only the delivered laboratory load, not available video capacity.
- `scripts/test-capacity-probe.mjs`: owns compilation, two native child processes, proxy, timers and cleanup. It runs a constrained attempt, withdraws the probe while maintaining baseline, and retries after an independently scheduled capacity recovery. The controller never receives the link's configured rate. The runner verifies the constraint and recovery afterward.

Native observations use their own monotonic clocks. A request/response timestamp bridge bounds each child's clock offset before policy evaluation; receipt time alone must not relabel stale samples as fresh. Receiver stages must match the currently commanded stage. A late report from an earlier stage cannot qualify a later load.

## Bounds and initial laboratory policy

Messages are 1316 bytes; the laboratory wire-cost accounting adds the 44-byte SRT/UDP/IPv4 headers. A message is one SRT packet with the default payload limit. Retransmissions and control overhead are not silently counted as useful delivered payload. Both classes share the same publishing connection and impairment queue. Baseline starts at 3.5 Mbps of this accounted load; additional traffic increases by 250 kbps, up to a total 6 Mbps in the first experiment. These are experiment settings, not production quality thresholds.

The native sender caps token accumulation at two messages per class, at most one send per class per loop, total configured rate at 12 Mbps, probe payload at 16 MiB, and lifetime at 90 seconds. Commands and observations have explicit length/count limits. Sender and receiver use nonblocking I/O and bounded connection setup. Any error, missing progress or deadline produces an explicit terminal result and owned cleanup.

The initial policy requires 1.5 seconds of current-stage receiver coverage and at least 97% of the offered accounted load, no missing/duplicate/reversed messages, fresh sender/receiver samples within 300 ms, RTT at most 50 ms and sender buffer at most 50 ms. Withdraw extra traffic immediately on pressure. Those deliberately local thresholds need qualification on physical networks before reuse. Initial and replacement stages have a bounded settling interval, with fast sender pressure checks continuing throughout.

## Verification and limitations

Unit tests must reject high packet-pair estimates as substitutes for delivered bytes, incomplete/old-stage coverage, stale/future observations, reversed counters, base starvation, excess delay/loss, budgets and cancellation. A successful step must retain baseline delivery as well as combined delivery.

Real-socket evidence must show refusal on the 4 Mbps constraint, withdrawal to baseline, and later qualification of the 6 Mbps offered load after independent recovery to 12 Mbps. Preserve both directional proxy timelines, native observations, decisions, exact settings and terminal cleanup. A refusal caused by sender underproduction is distinct from insufficient network capacity and cannot claim the path was measured.

This checkpoint does not satisfy picture identity, audio coverage, recording, phone/Watch, competing real flows or production readiness. The follow-on must carry valid padding or an equivalent probe on the actual publishing path, preserve the current encoded video and archive, account for measured candidate cost and overhead, and pass all existing native media gates before admission is integrated. Do not hard-code known impairment rates into the application or permanently suppress upgrades.
