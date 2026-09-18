# Repeated native campaigns implementation plan

> **For agentic workers:** Use subagent-driven-development: one bounded probe-owner implementer, parent candidate/capture integration, then independent spec and quality reviews. Parent runs heavy verification sequentially.

**Goal:** Run fresh native probe and candidate measurements after fallback recovery, with separate evidence for every campaign, before qualifying two complete native recovery cycles.

**Architecture:** Add an explicit DEBUG repeated route alongside the existing single-campaign route. The probe owner uses v3 from its first begin and restarts only from a joined terminal owner after current policy readiness returns for the same target at a newer applied revision. The candidate owner allocates fresh checked attempts and revocable authority for each campaign and joins the previous attempt before reuse of the campaign slot. Capture supplies current readiness to both owners. Production upgrades remain disabled.

**Tech stack:** Swift actors, existing SRT v3 begin/restart APIs, native candidate owner, FilmModel tests, versioned JSON and independent JavaScript replay.

## Decisions

Use explicit campaign identity and joined ownership instead of reopening retired objects. Do not make repeated work an unconditional timer. Retain the existing one-campaign path as a regression baseline. The repeated lab route first exercises the same 240p-to-360p target twice, separated by actual fallback and Core recovery; it does not interpret a higher-profile readiness request as permission to reuse a 360p measurement.

## Tasks

- [x] Native probe owner: add an explicit repeated mode with a one-install context provider. After the existing startup delay, wait for readiness before beginning v3 campaign 1. Run the existing bounded staged traffic; retain terminal evidence after cancellation/profile replacement. Join cancellation and final snapshot before restarting campaign n+1. A restart requires the original target, same source scope/generation, a strictly newer applied revision, and fresh readiness before and after the native restart. A changed/absent post-restart context cancels the returned exact owner before returning. Cap the lab at two campaigns, retain separate bounded events and context records, export formatVersion 3. Never reinterpret this as production admission or receiver capacity.
- [x] Candidate owner: in the explicit repeated route, create a fresh NativeCandidateAttempt and CandidateAuthority per probe campaign, reset only per-campaign diagnostic state after joined retirement, and retain closed campaign exports separately under a new envelope version. Wait for a newer campaign rather than reuse the previous stage/id. Forward the current readiness provider to the probe owner. Stop closes scheduling synchronously and joins all native work before export.
- [x] Capture admission: use the actual applied revision rather than the current revision-0 lab restriction. Revalidate the supplied applied receipt and revision across asynchronous reads; stale earlier-campaign data cannot authorize a later change. Keep final policy admission/probation unchanged.
- [x] Add failing-first tests for two fresh campaigns, renewed budgets/identity, current recovery context, newer revision, cancellation during begin/restart/measurement, late callbacks, exact terminal joins, immutable previous exports, and changed scopes/targets/generation.
- [x] Independent spec then code-quality review; Core/FilmModel regressions and unsigned iPhone/Watch build.
- [ ] Add explicit harness options and independent versioned replay for multiple campaigns, preserving raw single-campaign artifacts. Until that verifier exists, the harness must reject the repeated route rather than report a single-cycle pass for it.
- [ ] Run a fresh native fixture with two controlled faults and two complete upgrade/fallback/recovery cycles; decode local/live A/V and preserve all evidence. Then continue physical devices and portable proxy hosts.

## Verification commands

```sh
swift test --package-path ios/Packages/ScorebugCore
xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination platform=macOS -derivedDataPath ios/DerivedData -parallel-testing-enabled NO test CODE_SIGNING_ALLOWED=NO
xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination generic/platform=iOS -derivedDataPath ios/DerivedData build CODE_SIGNING_ALLOWED=NO
pnpm test:tools
```

Use licensed Xcode 26.2 and unique `artifacts/qa/repeated-native-campaign-*` logs. Keep runtime sources unchanged during native runs. The user's autonomous implementation instruction covers these local changes/tests; no deployment or device-license action is required.

## Native scheduling checkpoint

The explicit DEBUG repeated route now runs at most two fresh native campaigns.
Probe restart follows joined cancellation and requires current readiness at a
newer applied revision, the same source clock, and the original 360p target. A
brief 540p readiness opportunity after confirmation is ignored while waiting for
fallback recovery. Each campaign retains its own bounded, immutable evidence.

Candidate measurement uses a fresh checked attempt and revocable authority per
campaign. Retirement must join before allocating the next attempt. Epoch checks
prevent delayed append, probe and health reads from affecting the next attempt.
Capture admission binds the actual current revision and v3 campaign, retaining
all existing policy, receipt and freshness validation.

Failing-first regressions reproduced the revision-0 restriction, intermediate
profile readiness exit, changed source-clock acceptance, delayed health-read
revocation of the next candidate, and mutation of an already completed probe's
status when stopping during recovery. The final FilmModel run passed 438 tests;
Core passed 458, tools passed 2,304, and the unsigned iPhone/Watch Release build
passed. Shared synthetic recovery fixtures now advance source timestamps beyond
the applied receipt boundary; production freshness thresholds are unchanged.

Evidence uses `artifacts/qa/repeated-native-campaign-*`. The previous full native
baseline remains `native-app-ceM4Yc`: one verified upgrade, controlled fallback,
and healthy recovery with independently decoded local/live A/V. No full native
run of the new repeated route has been performed yet. The JavaScript harness
explicitly rejects repeated mode and its new proof envelope until independent
multi-cycle replay and two controlled faults are implemented. Production automatic
upgrades remain disabled; physical-device and remote-host qualification remain
pending. This is a native scheduling checkpoint, not repeated-ramp qualification.

Independent specification and code-quality reviews approved this checkpoint with
no remaining actionable findings.
