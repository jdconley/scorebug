# Next session handoff

## Direction and checkout

Simulator-first; hardware/external hosts deferred. Batch related changes, focused
checks only, retain passing evidence. No agents, pushes, broadcasts or purchases.
Preserve footage, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. The [delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; [acceptance](../simulator-acceptance.md) owns retained results.

## Latest combined path and production optimization

Startingb2b492f. New debug-only `--fixed-uhd on` headless option (UHD/audit-off,
≤60s/no outage) exercises real archive/SRT/proxy/outputs while skipping adaptive
quality/probing; retains100ms control polling. KS4ILp/labytjSFH,35s, passes scoped
checks:0SDK/app queue drops,998consecutive4Kreceiver frames,34.3msmaxsubmission,
recording/publishing survive. No full media or adaptive qualification. First35s
source differs from the adaptive failure near256–271s; preserve that distinction.

Production health polling now checks scalar encoded-history presence instead of
copying4096records every100ms just to ask if any exist.11focused history tests and
incremental FilmModel build pass. Change postdates fixed capture; do not credit it
with that integration pass. Next verify adaptive4K or isolate content/warm-state
using the short diagnostic. See [session](2026-09-28-fixed-uhd-and-readiness.md).
All handles50640/3532/54367 joined0; no active jobs.

## Latest short encoder isolation

Starting81056a8: hardware selection confirmed. New opt-in15s SDK diagnostics show
single and triple concurrent4K encoders each produce450/450frames with0drops; a
verified1080→4K replacement also produces450/450. No raw-queue or recipe change.
Integrated app/proxy/archive/real transport workload remains the differentiator.
Do not repeat plain encoder-count, selection or replacement hypotheses. Next isolate
that combined workload. See [session](2026-09-28-encoder-load-isolation.md) and
artifacts/qa/encoder-selection-20260928/result.json. All three job handles joined;
no active jobs. Low-latency mode failed its diagnostic and remains rejected.

## Latest UHD boundary diagnosis

Starting edb4b94, added opt-in scalar SDK-queue/native-submission diagnostics to
headless UHD; incremental FilmModel build passes. headless-native-nm6xCH, labPRuCD0,
exec82440 joined0 and cleanup[]. No active jobs. See
[session](2026-09-28-uhd-boundaries.md) and boundary-analysis.json.

4Ktrial256s, rollback271s:147captured/145encoded/received. App ingress eviction and
rejection remain0. SDK raw-input evictions rise0→2→4→7 during UHD/fallback; native
submission maximum grows from<5ms before UHD to90.8ms. Drop boundary is now proven
in the SDK raw queue; host contention vs intrinsic native throughput remains open.
No queue/threshold changes. Do not repeat unchanged full climb; isolate native
encoder load with a short focused path. Full archive decoding was not rerun.
Audit retention/terminal behavior was reconciled from current code and six retained
passing checks; that plan TODO is complete without another suite.

## Latest checkpoint

Starting4076db2, fixed two actual bugs: a missing worker processing report consumed
its decoded window before a later poll could complete it; the UHD receiver tracker
still rejected locally accepted bytes beyond the legacy16MiB budget. Missing reports
now wait only within the original capture deadline. Tracker and snapshot share the
existing v4 64MiB/legacy16MiB limit. Identity/loss/queue/deadline checks remain intact.
Five focused model checks and57receiver checks pass. See
[session evidence](2026-09-28-missing-processing-race.md).

Native headless gZctuL, lab6bwmkE:420-second checkpoint joins successfully, cleanup[].
360/720/1080 confirm;4K is actually admitted at24Mbps and received as3840×2160.
It resets during probation after148captured versus146encoded/received frames;
reason missingCapacity,trialRollback. Transport/thermal/worker allnominal. Actual
receiver4K run444frames, maximum PTSgap6000/90000; lower-profile runs initially
have exact3000steps. This is genuine observed media loss, not the former receiver
quarantine. Recording/publishing stay active; recovery returns through360to720.
Do not repeat unchanged or weaken probation just to pass. UHD sustained qualification
remains open; short successful admission is not full UHD acceptance.

Native RecordingLibrary export passes using the retained archive,212segment hashes
verified. Full-file offline decode was deliberately stopped (exit143) after receiver geometry
already proved real gaps. No decoded-media qualification is claimed. Export-only XCTest helper enables reuse
without another live capture. Headless progress now prints elapsed time and reset
causes. These harness additions postdate this capture; its producing patch is saved.

## Current reconnect checkpoint and next work

Native SRT reconnect is implemented and verified; see
[session evidence](2026-09-28-fault-coverage-and-reconnect-gap.md). Failed native
publisher/append gets bounded2/4/8/16/30s retry for the same tap/game/generation,
joined teardown and successful fresh control. It cannot issue another Start after
remote/explicit stop or ownership change. UI says reconnecting and retains Stop.
Nine distinct focused model tests (including six cancellation variants), an
additional control assertion rerun, and incremental arm64 simulator build pass.

headless-native-omoEsi, labQ0T9a3: actual relay SRT kick at15s, new publisher at17s,
same recording and generation1, native recording/publishing survive to71s, cleanup[].
Native export and full archive/four-output decode pass their scoped checks:
2137consecutive clean archive frames, no within-session video/audio gaps, identical
live source IDs across both outputs, all A/V ends within31ms.137missing live frames
between sessions (4.567s) remain explicit. Exactly one Start and final Stop inSQLite.
Static score; changing-score acceptance is retained separately. All jobs joined.

A prolonged25s relay suspension now also passes: headless-native-WH3nME, labSRRETF.
Failed retries back off before successful recovery at48s; same recording/generation,
one Start/final Stop.47segment hashes and native export pass;2733consecutive clean
archive frames. Both destinations fully decode before/after recovery, with no
within-session video/audio gaps. Live gap35.5667s; interrupted output audio tail108ms.
See [session evidence](2026-09-28-prolonged-relay-outage.md). All jobs joined.

Publisher-only25s packet blackhole also passes: headless-native-K87zVV, lab6iMbvh.
517forward/664reverse actual drops, zero sends during fault, same recording/generation
across retries, publishing resumes42s.2731consecutive clean archive frames; both
outputs decode with within-session continuity. Live gap29.3333s, all A/Vends≤42ms.
Capture51384 and native export/media66766 joined0; cleanup[]. See
[session evidence](2026-09-28-publisher-blackhole.md). No active jobs.

1. No more equivalent reconnect captures. Intermittent packet loss and whole-client
   network loss remain distinct from publisher-hop blackout. New outage fixture
   supports reconnect ports with isolated reply routing; congestion fixture unchanged.
2. Keep4K performance diagnosis separate: actual444UHD frames reached receiver then
   probation found pre-receiver loss. Latest boundary measurements locate SDK raw-input
   evictions during slow native submissions; host contention remains unproven. Do not enlarge queues or weaken thresholds.
3. Severe-collapse loss, abrupt crash tails and sustained profiles remain open;
   hardware/radio/external hosts deferred. Retained fault coverage is audited in
   local-fault-coverage.md; runtime control beyond optional audit limits already passes.

Headless fault command: `node scripts/test-headless-streaming.mjs --host <LAN> --source <1080fixture> --duration 70 --quality 1080 --timing-audit off --disconnect-after 15`.
Media verifier: artifacts/qa/fault-coverage-20260928/verify-reconnect-media.py (bound
to omoEsi). Artifacts include producing source patch and input/output hashes. UI
changes postdate capture and passed model controls plus simulator compilation.

## Reuse, don't repeat

-1080 complete native/media acceptance: ordinary-native-PpPozK.
- Two-phone create/join/scoring, separate41mm Watch takeover/relaunch/end, offline
  uncertain commands and takeover/stale recovery pass. Simulator Watch setup fixture
  and direct HTTP do not qualify WatchConnectivity.
- Short4K recording/export/playback/relaunch: recording-quality-20260928-media.
- Native archive storage/queue/source faults, source restart, API/worker hard-crash
  recovery, relay generations and Mac service outputs retain passing checks.
- Direct simulator4K SDK diagnostic reproduces encoder unresolvedInputLimit in2.697s.
  Low-latency mode cannot create an encoder. Keep the simulator limit explicit;
  do not enlarge queues, switch modes or rerun full simulator4K unchanged.
- Hosted native CI not run; no authorized push. Physical pairing/radio routes and
  external deployment remain separate gates.

## Environment and commands

Scope `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`.
FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; last LAN192.168.1.130.
4K600s source `artifacts/qa/uhd-app-20260928/input.mov`, SHA256
be959258221b1427697d911daae4e54f99721fa69a82ae0c66f7b39922970d1a.
1080 source `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`.

Headless: `node scripts/test-headless-streaming.mjs --host <LAN> --source <absolute.mov> --duration 420 --quality 2160 --timing-audit off`.
The optional audit cap stays2048; audit-off runs retain production checks but are
not complete delivery-audit/UI qualification. Prefer short focused diagnostics.

Export retained native archive: `python3 artifacts/qa/missing-processing-20260928/export-retained.py <headless-artifact>`.
Uses existing FilmModel derived data and one opt-in XCTest; never concatenates files.
Do not print generated config/setup/ordinary-environment JSON containing credentials.
