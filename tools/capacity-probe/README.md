# Bounded local SRT load probe

Run from the repository root with Node, a C++17 compiler, `pkg-config` and SRT development libraries installed:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:capacity-probe
```

The explicit developer directory uses the already licensed Xcode installation on this validation machine. Other POSIX hosts use their configured compiler; omit that environment setting there. No installation, external server or broadcast is performed by the runner. All network endpoints bind to loopback, and ports are assigned for the owned run.

One native SRT connection carries fixed baseline messages and separately identified additional messages. The harness independently changes the proxy from 4 to 12 Mbps after 12 seconds. The policy never reads the impairment rate. It warms a measured 3.5 Mbps baseline, ramps extra load in 250 kbps steps, withdraws on pressure, and attempts recovery with a fresh policy. It qualifies only the observed offered load, up to 6 Mbps here. This is not an estimate of maximum path capacity or usable video capacity.

Each rate step needs fresh sender/receiver observations, continuous sampled coverage and 1.5 seconds of matching-stage delivered baseline and probe traffic. Loss/duplicate counters are cumulative across stage changes. Fresh attempts can retain historical counters explicitly without ignoring new failures. Frame cadence, encoded payload, audio and recording are not part of these synthetic messages.

Probe rates require a native 300 ms lease, renewed every 100 ms only while the controller continues observing valid feedback. Native expiry or the 16 MiB probe-payload bound removes extra traffic while preserving baseline. The final experiment deliberately withholds lease renewals and verifies that probe messages stop while baseline messages continue. Commands, rate, lifetime, pipe output, parsing and per-loop work are bounded. Native stdout/stderr are nonblocking; failed diagnostic output terminates explicitly. The parent owns process groups, handles every pipe error, stops and joins both children, closes the proxy and retains terminal evidence on success or failure.

Artifacts under `artifacts/qa/capacity-probe-*` include source snapshots/hashes, compiler output, actual SRT header/runtime version agreement, initial/final bounded clock bridges, native samples, policy decisions, both proxy timelines and cleanup status. Receiver totals must match all accepted baseline/probe messages after drain with no missing or duplicated identities.

The result is an installed-libsrt transport experiment. It does not qualify iPhone SDK behavior, GoSRT relay behavior, native A/V, an independent archive, competing flows, real networks or production adaptation. The next integration must preserve the actual current video profile and archive, then pass all existing media gates before approving upgrades.

## Real MPEG-TS media and disposable padding

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:mpegts-probe
```

This separate finite experiment also requires FFmpeg with H.264/AAC support. It generates a 12-second 720p30 recording with a documented 3.5 Mbps constant MPEG-TS mux rate. Original packets and seven-packet null messages share one serialized SRT socket. Media is prioritized; the probe has no catch-up burst, a 2 Mbps rate ceiling, a 300 ms native lease, local pressure withdrawal and bounded memory/lifetime. Only one attempt is allowed per owned connection. Its run-specific SRT stream ID scopes the loopback fixture; it is not production authentication.

The receiver captures bytes before demux. The complete accepted stream must equal the delivered stream byte for byte. Removing null packets must recover every original non-null source packet, and decoding both tracks must produce identical frame hashes and timestamps. Source null packets are counted separately from additional padding. The independent qualifier checks actual processed renewals/deadlines, pressure statistics, acceptance-completion time, withdrawal counters and subsequent media continuation. It does not infer probe delivery from total null traffic or a bandwidth gauge.

The reviewed `mpegts-probe-TZgGv9` run passes baseline, deliberate lease expiry and a 4 Mbps constrained path. Every run preserves **360 video pictures and 564 decoded audio frames**. Lease expiry stops **250,040 padding bytes**, with 2,958,556 further original source bytes delivered. Under constraint, **153,972 padding bytes** precede withdrawal at **58.657 ms RTT / 47 ms send buffer**; all 3,625,768 remaining source bytes arrive. All six native owners exit zero and are joined. Full tooling tests pass **1085/1085**, including 24 new proof/cleanup tests and causal review regressions; the C++ unit assertions pass with warnings treated as errors.

Maximum forward residence under constraint is **214.722 ms**, despite exact eventual delivery. Offline decode equivalence is not a live cadence or freshness qualification. This does not qualify the Swift publisher, GoSRT relay, camera/archive concurrency, competing traffic or capacity admission. Next integrate the primitive with the native serialized transport consumer and attempt-bound pre-demux relay accounting, then rerun the native picture/cadence/A/V/archive gates. Production quality adaptation remains disabled.
