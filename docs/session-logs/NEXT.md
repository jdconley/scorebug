# Next session handoff

## Direction and checkout

Simulator-first; hardware/external hosts deferred. Batch related changes, focused
checks only, retain passing evidence. No agents, pushes, broadcasts or purchases.
Preserve footage, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. The [delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; [acceptance](../simulator-acceptance.md) owns retained results.

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

## Next work

Priority: implement the actual missing native SRT reconnect feature, not another
4K or generic fault rerun. See [current session design](2026-09-28-fault-coverage-and-reconnect-gap.md).
Current pollLocalHealth detaches a failed publisher, stops its owned broadcast and
requires manual Retry. Existing API/worker recovery is a different failure mode.

Reconnect only after joined teardown and fresh control, for the same capture tap,
match, selection and broadcast generation. Reuse the authorized running generation
and a fresh publishingAttemptId; do not auto-submit .start after remote stop/change.
Explicit Stop/capture end/replacement/auth/setup changes cancel retries. Back off
failures and start at minimum while local recording continues. Focused model gates,
then one native network-outage run. Hardware remains deferred.

19retained fault test passes and current sources are audited in local-fault-coverage.md;
runtime classification beyond diagnostic caps already passes. Real packet loss and
full disconnect/restoration, severe-collapse loss, native4K performance, abrupt audio
tails and sustained profiles remain open. All jobs terminal; no code changed this turn.

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
