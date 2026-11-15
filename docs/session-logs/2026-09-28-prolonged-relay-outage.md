# Prolonged relay outage — September 28

Starting6ac91c6, clean authoritative worktree. Previous goal turn made progress:
automatic native reconnection, Stop/ownership guards, actual SRT kick/rejoin and
continuous archive plus recovered outputs all verified. No prior jobs remained.

## Focused test design

Reuse the headless native workflow. Its existing UDP impairment proxy accepts only
one peer tuple; a reconnected client gets a new source port and would be rejected
by that fixture. Avoid changing established congestion evidence or conflating that
fixture rejection with a product failure.

Add an opt-in suspension of only the newly created, owned relay container for25s.
Docker state is checked paused and resumed; cleanup joins the operation and always
unpauses in finally. This makes SRT and relay management unresponsive while the
native app, archive, API and worker continue. It is a prolonged relay outage, not
an isolated packet blackhole or physical radio handoff. No production code changes.

Command: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-headless-streaming.mjs --host 192.168.1.130 --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov --duration 90 --quality 1080 --timing-audit off --disconnect-after 15 --relay-outage-seconds 25`.

The runner validates time bounds, retains native lifecycle/attempt identity and
checks one successful replacement on the same recording/generation. Producing source
patch/hash: headless-native-WH3nME/implementation.patch/json. Owned labSRRETF.

## Result

Passed. Capture69651 and export/media62709 both joined with exit0; owned cleanup
reports no failures and no test processes remain. Docker state confirms25.062s of
relay suspension. Native lifecycle: publishing0s, failed20s, starting22s, failed27s,
starting32s, failed39s, publishing48s. Recording and publishing remain active at91s;
all attempts retain one recording and broadcast generation1. SQLite has exactly one
Start and one final Stop. Automatic retries recover without user action.

Real RecordingLibrary export verifies47 segment hashes. The clean1920×1080 archive
contains2733 consecutive30fps source frames,0–2732, with no video identity loss or
audio timestamp gaps. Both destinations retain matching output sessions: source
frames62–447 before interruption and1515–2713 after recovery. All five files fully
decode, with no within-session video identity loss or audio timestamp gaps.

Live output loses1067 source frames between sessions: **35.5667seconds**, including
outage detection, failed retries and recovery. This is not gap-free streaming.
Interrupted outputs have about108ms audio overhang; recovered outputs end within14ms
and archive within35ms. Abrupt-failure tails remain a separate open item.

Reports: `headless-native-WH3nME/reconnect-media/result.json` and
`input-output-hashes.json`; fault timestamps in `device-lab-SRRETF/relay-outage.json`.
Export and verifier logs are in `relay-outage-20260928/`. Timing audit was disabled;
this qualifies scoped native reconnection/media, not simulator UI, changing scores,
physical radios or an isolated packet blackhole. Those scopes retain separate gates.
Formatting and syntax checks pass; no production changes, broad suite or hardware work.
