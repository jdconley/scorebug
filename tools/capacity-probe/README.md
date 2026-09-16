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
