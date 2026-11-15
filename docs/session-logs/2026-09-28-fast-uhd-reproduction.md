# Faster UHD reproduction — September 28

Starting92d2369, `codex/local-validation`. Previous turn made progress by ruling
out content-only failure and updating authoritative evidence. This session adds
DEBUG-only diagnostic paths; normal app/release ladder, timings, queues and encoder
recipe remain unchanged. No hardware, agents, push or broad suite.

## Changes and verification

- Headless `--fixed-uhd on --fixed-uhd-transition on`: start1080, after5s verify
  current6Mbps configuration, replace with UHD through guarded native admission,
  then verify24Mbps against the replacement receipt. Keeps local archive and real
  SRT/proxy/both outputs. Requires fixed mode, UHD, audit-off,≤60s, no outage.
- `--direct-uhd on`: diagnostic ladder240→2160, with normal adaptive admission,
  delivery, freshness, timing and pressure checks. Requires UHD/audit-off,≤120s,
  no fixed mode/outage. This skips middle rungs and is never full ladder acceptance.
- Boundary observations now retain the existing cached native hardware-selection
  result per encoder. Missing evidence is explicitly unavailable.
- Runner checks explicit mode/transition completion; the native test asserts UHD
  replacement dimensions. JavaScript syntax and diff checks pass. Both incremental
  FilmModel builds and targeted native test executions pass their lifecycle scope.

## Results

`headless-native-19R4qp`,35s on the250–300s remux, exec11000 joined0, cleanup empty:
verified1080→UHD replacement;91actual1080frames then908consecutiveUHD frames,
all PTS deltas3000/90000.0SDK/app drops,0native errors,36.0ms max submission.
Both observed encoder sessions select hardware. No full media decode/export.

`headless-native-MuMtrg`,90s on a private215–345s remux, exec63939 joined0,
cleanup empty: direct adaptive UHD trial26s, first SDK raw drop37s, rollback41s;
second trial71s, rollback86s.15SDK drops by end, app drops0, actual hardware selected.
Receiver UHD runs440and426frames, each maximum delta6000/90000. First rollback
reports missingCapacity/unknownPressure/trialRollback, so do not equate its policy
reason with the previous full-ladder sourceLoss decision. Boundary loss does
reproduce without long runtime or earlier intermediate profile transitions.

Read-only `sample 43055 3 10` starts85s after xctest launch, exec16512 joined0.
Native submission stacks frequently wait for a synchronous VideoToolbox XPC reply;
source-history copying appears once in222samples. This is a sampled call-path
observation, not proof of the service's root cause. First loss precedes profiling
by about48s.389ms max submission occurs around profiling/rollback and must not be
treated as an undisturbed timing measurement; pre-profile max was53.6ms.

Each artifact has `isolation-analysis.json`, source HEAD/patch, hashed diagnostics
and worker geometry; direct run also retains `native-stack.txt`. Producing patches
were saved before execution and differ: direct mode was added after transition run.
Recording/publishing survive both. Runner exit0 is not adaptive quality acceptance.

## Next

Use the≤60s direct-UHD path for further isolation; no unchanged300s climb needed.
Short combined guarded replacement passes while adaptive probing/observation path
reproduces loss. Investigate that difference and native service waits. Candidate
encoder terminal path explicitly drains, stops and clears the codec; no leak or
software fallback has been demonstrated. Do not guess another queue/timing fix.
No broad suites or redundant archive decode. All three jobs joined; no active jobs.
