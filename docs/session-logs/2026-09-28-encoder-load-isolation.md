# Short UHD encoder isolation — September 28

Starting81056a8, clean checkout. Previous turn localized actual4K loss to the SDK raw
queue during slow native submissions. This turn isolates hardware selection,
concurrent encoders and the verified1080→4K replacement without another full climb.

## Findings

The existing three-second candidate diagnostic confirms actual Mac hardware selection:
EncoderID ave.avc, UsingHardwareAcceleratedVideoEncoder=true;90/90normal outputs.
Its separate low-latency case still fails rawQueueFailure (6accepted/1output), despite
the diagnostic test itself exiting0. No low-latency recipe change is justified.

Source inspection found encoder-selection keys set as session properties, whereas
[Apple documents creation-time encoderSpecification](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablehardwareacceleratedvideoencoder).
The measured current hardware selection contradicts software fallback as the cause
of this failure. No speculative configuration fix was made.

New opt-in SRTUHDLoadDiagnostics uses the actual SDK and unchanged production4K
recipe/raw-queue bounds with fake accepting transport. One and three concurrent
encoders each receive the same450frames from source260–275s at30fps. Every encoder
submits/emits450frames with0raw drops/errors and actual hardware selection. Input
lateness stays below7ms; maximum native submission33.1ms(single),53.7ms(triple).
This rejects a simple short-term encoder-count capacity explanation, not whole-host
contention under the full app/FFmpeg/archive workload.

A second15s case uses the verified1080→4K replacement and follow-up24Mbps rate receipt.
450/450frames, no drops/errors; maxsubmission42.2ms, maxinputlateness15.4ms.
The once-per-second SDK counters remain0 throughout. Replacement by itself does not
reproduce the integrated slowdown.

## Evidence and next action

artifacts/qa/encoder-selection-20260928/result.json binds logs/results to hashes.
Initial candidate exec29028, isolated-load70479 and replacement59050 all joined0.
Tests compile incrementally in2.2s; native load cases take30.4s and15s. No full-media,
network, archive, Watch or hardware-device qualification claimed. No production
behavior changes. No active jobs.

The SDK load fixture enables only with SCOREBUG_UHD_LOAD_SOURCE and requires an
absolute SCOREBUG_UHD_LOAD_OUTPUT directory. SCOREBUG_UHD_LOAD_REPLACE=1 selects
the replacement case. The normal test suite skips it; it never sends network media.

Next isolate the actual combined workload/transport rather than repeating encoder
selection, plain multi-encoder or replacement checks. Keep the original integrated
loss result false and queue/quality limits unchanged. The normal1080vertical and
outage recovery evidence remain reusable.
