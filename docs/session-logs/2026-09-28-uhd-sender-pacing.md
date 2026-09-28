# UHD sender pacing — September 28

## Cause and change

An opt-in eight-second diagnostic exercises the real SDK timer, transport consumer
and socket path with an injected sender accepting every write. This isolates sender
scheduling from network delivery. Before the fix, requested/accepted Mbps were
9.192/8.284, 12/10.694, 36.192/23.069 and 48/25.143. The single-message token bucket
lost capacity to timer jitter even without network constraints.

Explicit UHD publications now allow four accounted messages of token capacity
(5,440 wire bytes), with at most four nonblocking submissions per idle opportunity.
Each submission separately rechecks pending media, token balance, lease, revocation,
transport health and cumulative bytes. The standard single-message budget, v4 wire
format, 48 Mbps ceiling, 64 MiB campaign cap and receiver admission rules remain.

## Verification

Evidence: `artifacts/qa/uhd-pacing-20260928/`.

- `regression-before.log`: bounded catch-up regression fails on the old sender.
- `after.log`: 75 affected probe/stage/pump tests pass in 9.613 seconds.
- Same diagnostic after the fix: requested/accepted Mbps 9.192/9.180,
  12/11.946, 36.192/36.138 and 48/47.998 (99.5–100%). These are local
  acceptance measurements, not network capacity or full-media qualification.
- Maintained SDK patch reverses to all 162 original source hashes and reapplies
  byte-exactly for all 38 patched source sections.

## Simulator checkpoint

`ordinary-native-aK6INv`, lab `device-lab-9PaWFc`, exec80522 joined1 with
cleanup failures empty. Full simulator build passes. Native policy confirms360,
720 and1080; actual receiver decodes1649/3144/1353/3373 frames at240/360/720/1080,
all with maximum PTS delta3000 and no invalid geometry. No2160 input was reached.
The UHD candidate fails with `inputRejected / unresolvedInputLimit`; bounded
candidate admission retains at most16 unresolved inputs. Do not increase that bound
without identifying the cause. An earlier attempt also timed out waiting for source
evidence; inspect saved samples rather than treating all retries as encoder failures.

Native stop, archive continuation and export-ready pass, validating the UHD terminal
allowance fix from the preceding session. Collection verifies166 segment hashes and
preserves the actual native export plus both live MP4s. This is not full offline media
acceptance; that expensive check is deferred until the complete climb succeeds.
Phase attachment: `attachments/696089D9-28C5-424D-921F-536CDE13EC0A.json`.

## Short encoder follow-up

`candidate-diagnostic.log`: opt-in real-footage SDK test compares normal and
low-latency24Mbps4K encoding on macOS. Normal mode accepts/outputs90frames,
first/maximum completion delay83ms. Low-latency mode fails `rawQueueFailure`
after6accepted/1output, with375ms initial completion. The diagnostic completes
in3.512seconds; its successful test exit means the diagnostic ran, not that both
recipes passed. Keep the production encoder recipe unchanged. The isolated macOS
result does not reproduce the full simulator failure.

Apple describes its low-latency mode in [WWDC21](https://developer.apple.com/videos/play/wwdc2021/10158/);
that documentation motivated comparison, not an assumption that the mode works here.
Next isolate the same candidate under simulator encoding/load. The SDK package has
Xcode schemes `HaishinKit`, `HaishinKit-Package`, `SRTHaishinKit`, and test target
`HaishinKitPatchTests`; only scheme discovery ran, no simulator diagnostic yet.
The opt-in input is `SCOREBUG_CANDIDATE_SOURCE` (absolute fixture path). Sender
throughput diagnosis uses `SCOREBUG_PROBE_TIMING_DIAGNOSTIC=1`. Both skip by default.

All jobs joined. Hardware stays deferred; retained phone/Watch/scoring evidence
is reused. No further full simulator rerun until a short causal check warrants it.
