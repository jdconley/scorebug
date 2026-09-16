# Native transport pressure windows

`PublishingSessionSnapshot.transportStatistics` now carries an optional rolling
`window` and a `freshWindow(at:maximumAge:)` accessor. The existing session health
loop feeds the tracker. Camera callbacks, archive settings, and live quality settings
are unchanged.

A window spans actual SRT collection timestamps. It uses the oldest retained sample
within five seconds of the latest collection and requires at least one second of
coverage. Any adjacent collection gap longer than two seconds resets that coverage.
A fixed 64-sample ring bounds storage and computation. Rapid sampling can therefore
leave less than one second retained, in which case no window is produced.

Cumulative sent bytes, retransmitted bytes and sender packet drops are subtracted
exactly before any floating-point use. Sent bytes include retransmission and transport
costs; their delta is not successful video delivery. Mean sender-buffer bytes,
sender-buffer milliseconds and RTT use each preceding sampled gauge held until the
next actual collection. Maxima include both endpoints. These are time-weighted
estimates from sampled values, not measurements of every instant between collections.
There is no extrapolation past the final collection and no interpolation of counters.

The tracker accepts only consistent samples from the same native publishing generation.
Cached or unavailable reads do not extend a window or its lifetime. Counter/clock
contradictions quarantine the tracker and clear window availability permanently for
that session. Closing retains historical scalar/window diagnostics while fresh access
returns nil. New sessions start empty. Freshness uses the actual final collection
uptime, with the existing default two-second age bound; caller time cannot renew it.

Weights and gauges are normalized before summation to keep finite extreme values
from overflowing intermediate products. UInt64 cumulative counters remain exact,
including values above JavaScript's safe-integer limit. The native fixture serializes
integer deltas as decimal strings; its independent Node checker reconstructs expected
endpoints, deltas, means and maxima from raw timestamped native collections.

These windows do not assert spare bandwidth, sustainable video capacity, low pressure
between collections, worker receipt, or an applied-profile revision. They are not yet
aligned with the worker's matched source-frame intervals. Automatic quality adjustment
still requires that alignment, explicit audio/mux/retransmission overhead accounting,
thermal/worker pressure, applied-setting boundaries, and resolution-transition tests.

See [the implementation plan](superpowers/plans/2026-09-15-transport-pressure-windows.md)
and [the impairment runbook](local-network-impairment.md) for validation commands.

The native impairment run `artifacts/qa/dual-output-voEU8h` provides 12 independently
verified windows per scenario. Peak mean sender buffering is approximately 2.0 ms
transparent, 19.5 ms recoverable, and 143.1 ms overloaded. The largest overload window
contains 2,669,096 retransmitted bytes. Every archive retains 420 frames, and both
transparent/recoverable streams retain 420 frames. Overload fails strict decoding;
its best-effort decoder emits 380 samples with unusable frame identities. These are
observations from this fixture, not universal pressure thresholds.

The Media suite passes 193 tests, Streaming passes 44, the tooling suite passes 706
(including 27 transport-evidence tests), and the combined unsigned iPhone/Watch Release
build succeeds. Streaming's initial cached build omitted the newly added Media file;
its generated source list confirmed that omission. Cleaning this worktree's package
build cache and rebuilding resolves discovery. No runtime code changed for that
build issue. Independent review approved and its suggested lease/horizon regressions
were added. Final source/evidence hashes are recorded in
`artifacts/qa/transport-window-final-verification.json`.

The original native scenario regression also passes at `dual-output-p6zHTH`: all
five local archives retain 420 frames and both normal streams retain 420 frames with
12 verified windows each. This includes absent/stalled receivers and the alternate
source clock origin, with all previous media and cleanup gates preserved.
