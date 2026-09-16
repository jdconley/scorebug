# Native transport statistics

The publishing session now has timestamped transport evidence for future capacity
and pressure qualification. It does not expose a usable-video-capacity estimate or
enable automatic quality changes.

The pinned SRT implementation collects counters periodically. Its cached getter
previously omitted when the collection happened. The SDK now samples system uptime
at entry to a successful native collection, so later age includes native-call time.
Repeated getters preserve that original time. Failed collection cannot commit
partially modified counters or timestamp old counters as new; failure and socket
stop clear availability. Collection frequency and transport operation are unchanged.

`PublishingTransportStatistics` preserves the native publishing generation, sample
uptime, socket elapsed milliseconds, cumulative sent/retransmitted bytes and sender
drops, RTT, estimated bandwidth, buffered sender bytes/time and available sender
bytes. Construction rejects invalid/negative/nonfinite statistics. Exact byte totals
remain UInt64. The
[SRT statistics reference](https://github.com/Haivision/srt/blob/v1.5.4/docs/API/statistics.md)
describes these as transport statistics: sent totals include retransmissions;
instantaneous estimates and sender buffering do not prove a higher video bitrate
is sustainable. Audio, muxing, control traffic and retransmission budget still need
explicit accounting and measured impairment qualification.

The adapter requires healthy current publishing before and after an awaited read,
with lifecycle/cancellation/generation checks after suspension. The existing session
health loop collects the optional descriptor, without capture-callback work or a
new per-frame task. A single retained historical sample bounds storage. Missing
readings preserve history; identical cached reads cannot renew freshness. Generation
changes, reversed sample/socket clocks, counter resets and contradictory equal-time
samples quarantine statistics for the rest of that publishing session. The last
consistent historical sample remains available with an explicit quarantine flag.

Freshness uses the original sample uptime and defaults to a two-second age bound.
It rejects future samples, invalid query clocks, closed sessions and quarantine.
Stopping closes the tracker synchronously before awaiting publisher shutdown; a
late getter cannot revive it. Each new publishing session starts with empty evidence.
This sample lifetime is separate from source-frame intervals and worker report ages.

The real Mac dual-output fixture exports exact decimal integer statistics and read
uptime. Its independent checker requires multiple actual collections, scoped native
generation, monotonic counters, bounded read age, no contradictory cached reads and
unavailable statistics after joined stop. The original frame, A/V, bitrate-change,
archive-isolation and cleanup checks remain mandatory. Synthetic local transport
traffic alone does not qualify venue bandwidth, physical radios, thermal behavior
or another host's encoder.

Implementation and final evidence are tracked in
[the plan](superpowers/plans/2026-09-15-native-transport-statistics.md).

Qualification passes 184 Media, 44 Streaming, 127 SDK, 123 native model and 661 tooling
tests, the combined unsigned iPhone/Watch Release build, and exact SDK patch provenance.
Final real-socket evidence is `artifacts/qa/dual-output-buQa9V`: all five archives
retain 420 frames, both normal live outputs retain 420 frames, and each normal run
provides 13 advancing native collections. Bitrate changes still produce approximately
6-to-2 Mbps output with unchanged frame and A/V gates. Independent review approved
after a reproduced and fixed post-read health race. The final manifest is
`artifacts/qa/transport-statistics-final-verification.json`.
