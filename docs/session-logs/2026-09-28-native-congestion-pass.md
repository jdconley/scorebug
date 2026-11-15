# Native congestion pass — September 28

Starting7eef49d. Previous turn completed combined API/SRT outage coverage. No active
jobs carried over. Simulator-first, no agents/hardware/broad suites. Production
capture, adaptation, codec settings and timing remain unchanged.

## Evidence-led choice

Retained simulator failures show high transient backlog and late repair feedback.
Earlier investigations already rejected larger network buffers, low-delay simulator
encoder properties, preliminary bitrate writes and pacing candidates. Do not repeat
those experiments. The observed burst cannot be assigned solely to old encoder
drain: earlier replacement breakdown attributes most simulator delay to first output
from the new encoder (about430ms versus27–30ms on Mac). This supports a distinct
native comparison, not a proved cause or a new production tuning change.

Read Apple's VideoToolbox documentation while checking delay options:
https://developer.apple.com/videos/play/wwdc2021/10158/ . Existing local unsupported
simulator results take precedence over assuming a documented option will work.

Added `--congestion-seconds` to the headless native runner. It waits for logged actual
confirmed720p, uses the existing750kbps impairment fixture for25s, and restores in
finally. It never supplies app health/admission evidence or changes production
quality policy. Runtime status success remains distinct from saved-media acceptance.
Post-run assertions require minimum reset, confirmed upward recovery and unchanged
publisher lifecycle. Their same conditions are checked by retained-data analysis.

## Execution and result

Initial headless-native-bi8j3p/3887 joined1: runner read workflow.log before its
asynchronous creation. No congestion applied; cleanup[]. Fixed only ENOENT retry.

headless-native-44b0fy/device-lab-7Kaldn: capture44417 joined0, export/media4256 joined0,
cleanup[]. Source binding records producing revision plus harness file hashes;
final runner additionally asserts the already-observed lifecycle. Scoped Xcode26.2:

`node scripts/test-headless-streaming.mjs --host 192.168.1.130
--source <checkout>/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov
--duration 330 --quality 1080 --timing-audit off --worker-encoder software
--congestion-seconds 25`.

Normal progression:360trial56s/confirmed76s,720trial136s/confirmed155s, minimum156s
following constraint,360trial230s/confirmed251s,720trial306s/confirmed326s.
Fault lasts25.022s. Same recording, publisher and generation1; one Start/Stop.
331s through finalization, recording/publishing remain active. Forward queue peaks
at28,968bytes/45packets; zero overflow, injected, oversize or cleanup drops.
All87,808forward and23,213reverse packets forwarded; pending0, fixture errors[].

Native library export reused the current bundle:167segment metadata/payload hashes
verified. Archive9,926 consecutive frames0–9925. Both final MP4s have9,844consecutive
source frames62–9905. All three fully decode, zero frame identity errors, zero audio
timestamp gaps; maximum video gap34ms, A/V ends≤35ms. Every complete rolling5second
window has30freshfps, including the entire constraint. No phase exclusions.
Archive continues20frames past live. Static overlay pipeline used; visible changing
score and Watch/UI qualification reuse their separate retained results.

`congestion-analysis.json` binds media/source/fixture/verifier/cleanup hashes and
actual state sequence. `congestion-media/result.json` contains all-file metrics.
Analysis/verifier: artifacts/qa/native-congestion-20260928. Syntax/format/diff checks
pass. No extra capture, native rebuild or decode after the completed result.

## Scope and next action

This qualifies one current nativeMac/software-proxy configuration against the real
congestion fixture. It does not turn prior simulator failures into passes or isolate
encoder/platform/backend/version differences as the cause. Simulator congestion,
UHD limits, colocatedVideoToolbox behavior and sustained profiles remain tracked.
Next complete intermittent packet-loss integration, then interrupted output tails
and sustained backend qualification. Do not repeat this native congestion capture
without relevant changes. All handles terminal; no active jobs.
