# September 28 — current simulator vertical

Starting `72d2b80`, clean. Previous turn implemented bounded DTS interleaving and
passed focused SDK/short native crash media checks. This is the one integration
checkpoint warranted by that media change, not a repeat after each small edit.
No hardware, agents, full regression suite or soak.

## Execution

```
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
node scripts/test-native-created-simulators.mjs --host 192.168.1.130 \
 --source <checkout>/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov \
 --encoder software --watch separate
```

Artifact `native-created-simulators-m1tVpX`, lab`device-lab-HtphEm`, handle46466
joined exit1 solely for the cleanup race below. All three named native workflows
passed: iPhone14 camera, iPhone14 creator/scorer, Series7 41mm Watch. The phones
created/discovered/joined a match, recorded/published, scored/took over/undid. The
Watch took over, scored, undid, relaunched without a setup injection, restored its
pairing/score and ended the match. Both phones observed the Watch changes while
the camera published; the camera continued recording and exported natively.
Real direct HTTP, simulator-only setup offer; no WatchConnectivity/radio claim.
Eleven accepted scoring commands; scorer inventory confirms no local recording.

## Cleanup race and fix

Unpair asynchronously shut down the Watch after the cleanup snapshot but before
`simctl shutdown`. The command returned149 with `current state: Shutdown`; deletion
then completed. Current read-only inventory confirms all three owned UUIDs absent,
every app container preserved, and backend cleanup has no failures. Original
`result.json` remains false/unchanged. Independent acceptance records the exact
cleanup reconciliation and binds the fresh inventory and original error.

The runner now rechecks authoritative device state after a failed cleanup command.
It accepts only the same owned device already in the requested terminal state
(or absent), records a reconciliation, and retains genuine failures. It stops
mutating a device if ownership/state verification fails. Six focused Node checks
pass, including the observed unpair/shutdown race, still-booted/transitioning
rejection, delete-not-done and identity mismatch. No app workflow rerun.

## Independent saved-media results

Collection verifies110native segment metadata/payload hashes and the unchanged
prepared source. Existing full-media analyzer plus the Watch score/waveform checker
complete with26392 exit0. The adapted checker uses three existing baseline audio
anchors per file (start/middle/end), not an unnecessary periodic sweep.

- Clean archive:6495consecutive source frames0–6494,30fps, no frame or audio gaps.
- Both final outputs:6068identical consecutive source frames193–6260,30fps, no frame
  or audio gaps. All three H264/AAC MP4s fully decode.
- Audio waveform alignment passes all9sampled anchors. Track ends differ by
  10.666ms archive,46.769ms mock RTMP,47.436ms proxy recording.
- Both live recordings visibly show stable0–0,1–1,2–1,1–2 states. The archive has
  no matching scorebug glyph. API/UI evidence independently covers intermediate
  phone/Watch point and undo commands.
- Archive continues234frames/7.8seconds beyond the live output.

`vertical-acceptance.json` binds captured HEAD72d2b80, the original workflow report,
creation/scoring evidence, preserved inventory, cleanup reconciliation, all media,
collection/decoded/A/V reports and their producing verifiers. It explicitly says
the cleanup fix was not in the captured run. No output trimming or thresholds were
changed; no failed artifact was relabeled.

This supplies current full local functional integration with the new publisher.
Simulator congestion/UHD, abrupt-failure tails across other timing/load, hardware,
other backends/hosts and endurance remain separate open gates. Reuse this result
instead of another unchanged simulator run. No owned jobs remain; the three older
manual simulators and unrelated devices were untouched.
