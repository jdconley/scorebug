# Adaptive UHD comparison — September 28

Starting commit4ce91ca, clean `codex/local-validation`. Simulator-first scope;
no hardware, agents, pushes or external broadcasts. Reused all retained scoring,
1080p and recovery acceptance. No production changes in this session.

## Evidence

- Adaptive headless native run, source `artifacts/qa/uhd-app-20260928/input.mov`,
  duration300, quality2160, timing-audit off. Artifact `headless-native-iOmUFd`,
  lab `device-lab-gOxeHq`; exec89445 joined0, cleanup empty. Source provenance
  recorded before run. Recording/publishing remain active through302s finalization.
  UHD trial261s, fallback270s: SDK raw-input drops29; app eviction/rejection0;
  native submission maximum87.1ms;223actualUHD receiver frames, maximum PTS delta
  9000/90000. Runner success means lifecycle completion, not quality acceptance.
- Read-only owned-xctest CPU/RSS sampler exec8816 joined0,121samples. Peak observed
  CPU57.9%, RSS189088KiB. These process averages cannot attribute native-call stalls
  or rule out contention in other processes/media hardware.
- Private FFmpeg stream-copy slice of source250–300s; original untouched. Keyframe
  seek/normalized timestamps cover the relevant content region, not an exact
  frame-aligned source start. Fixed-UHD headless35s run on that slice: artifact
  `headless-native-aWay18`, exec81373 joined0, cleanup empty.997consecutive3840×2160
  receiver frames, maximum delta3000/90000;0SDK/app queue drops,0native submit
  errors,36.4ms maximum submission. Recording/publishing survive. Producing clean
  HEAD was unchanged; provenance recorded after capture and explicitly says so.
- Reports: each capture's `comparison-analysis.json`, plus
  `artifacts/qa/uhd-readiness-20260928/comparison.json` with source slice and
  diagnostic/worker/provenance hashes. Private configs are not copied into logs.

Commands use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`
and `node scripts/test-headless-streaming.mjs --host 192.168.1.130 --source <absolute.mov>
--duration <300|35> --quality 2160 --timing-audit off`; fixed comparison adds
`--fixed-uhd on`. Both perform incremental builds and one targeted native test.

## Decision and next step

Readiness allocation removal is valid but did not resolve adaptive UHD loss.
Same-content fixed UHD passes the short queue/receiver check. Adaptive workload
and accumulated runtime remain differentiators; content complexity alone is not
supported as the explanation. Neither result qualifies sustained/full media.

Do not repeat another unchanged full climb, broad suite, archive export or decode.
Next make the remaining distinction cheaper: a short combined archive/SRT/proxy
1080→UHD replacement diagnostic, preserving the normal encoder recipe and bounded
queues, with actual encoder selection in scalar observations. The isolated SDK
replacement already passes; this would add the real combined workload. If it
passes, investigate adaptive observers/probing with profiling rather than another
speculative production optimization. Hardware remains deferred.

All three process handles joined. No active jobs. Documentation-only checkpoint;
no new code tests needed.
