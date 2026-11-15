# Publisher-only network outage — September 28

Starting0e7ee64. The preceding turn completed the prolonged relay outage checkpoint;
this turn targets the distinct publisher-only network blackhole/restoration gate.
No production behavior changes, hardware or broad suites.

## Design and focused verification

The existing congestion proxy deliberately owns a single client tuple. Keep its
rate queues/evidence unchanged. A separate opt-in outage fixture gives every
reconnected publisher source port its own backend UDP socket, so delayed replies
cannot leak into a replacement attempt. Bound routes to16, outstanding sends to64
and packets to2048bytes. Fixture errors fail the run and join owned socket cleanup.
No payload logging or host network changes. API, relay management and worker remain
reachable; only the publishing SRT hop loses packets in both directions.

Three real-socket checks pass: bidirectional blackout with isolated old/new replies,
endpoint validation before socket allocation, and fail-closed route-bound cleanup.
Initial behavior check failed against the unimplemented fixture. Socket checks finish
in under0.2s. Syntax and formatting pass. Existing congestion tests are unaffected.

Headless option `--publisher-blackhole-seconds 25` is mutually exclusive with relay
suspension, requires `--disconnect-after`, and reserves at least30s for restoration.
Runner lifecycle retains one recording/generation and verifies successful native
replacement. Lab shutdown stores counters/phases/errors in publisher-blackhole.json.

## Result

headless-native-K87zVV; lab6iMbvh. Capture51384 and export/media66766 joined0;
cleanup[].90s,1080source, fault at15s for25s, timing audit off. Source HEAD and
patch/file hashes saved beside the capture. Native export reuses the just-built
bundle, without another build or capture.

Actual fault duration25.002s. Forward517 and reverse664 packets dropped; neither
sent counter advances during the blackhole. After restoration both resume; two
backend routes, peak pending sends1, final pending0, no fixture errors.
Lifecycle: failed20s, starting22s/failed25s, starting30s/failed33s, publishing42s.
One recording and generation1 throughout, exactly one Start and one final Stop.
Recording/publishing still active at91s.

Native export verifies47segment hashes. Archive2731consecutive1080p30 frames0–2730,
no video identity loss or audio timestamp gaps. Both outputs have matching sessions:
source62–451 before loss and1332–2710 after recovery. All five files fully decode
with no within-session video identity loss or audio timestamp gaps. Interrupted
output A/Vends within42ms, recovered within26ms, archive16ms.

**Live gap:880missing source frames,29.3333seconds.** Includes the25s blackout and
recovery. This is scoped native publisher-hop outage recovery, not gap-free live
streaming, whole-device offline, intermittent loss or physical radio qualification.
Changing-score/Watch acceptance remains retained separately.

Reports: reconnect-media/result.json and input-output-hashes.json in the headless
artifact; publisher-blackhole.json in the lab. Logs/verifier in
artifacts/qa/publisher-blackhole-20260928. All processes joined; no hardware or broad
suite ran. Remaining performance/loss gates stay in the pure delivery plan.
