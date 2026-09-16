# Compare native low-latency rate control

The completed failure-finalization checkpoint preserves local video, but live
recovery remains failed. Controlled native measurements locate the inadequate
rate reduction before transport. Both simulator runtimes reproduce it; preparation
ordering and 720p scaling have not provided a fix.

Use the existing maintained `isLowLatencyRateControlEnabled` encoder-specification
path in an isolated test. Compare two fresh 1080p H.264 sessions requesting 1.5 Mbps,
with identical blocks16 pixels, 30 fps pacing, 600 measured frames and 150 settling
frames. Change only that Boolean: false then true. Leave production/Watch behavior,
transport and archive code unchanged. Apple documents this encoder specification
for low-latency rate control; support and effectiveness must be measured, not assumed.

Version 5 identifies the fixed experiment and ordered requested modes. Preserve
session/configuration ownership, native snapshots, exact frame identity and payload
checks; validate actual 1920×1080 H.264 output dimensions for every frame. The mode
field records the requested encoder specification, not proof of internal behavior.
The false baseline supplies a nil specification (default selection), not a verified
native disabled state.
An unsupported creation/property result remains a failed diagnostic with retained
raw evidence. A valid comparison reports observed payload ratio without requiring
it to decrease and without claiming streaming recovery.

Add red/green verifier tests for the new protocol, including missing/wrong mode,
wrong dimensions, native failure and incomplete frame coverage. Add one exact XCTest
selector and `--low-latency` runner mode. Run the native comparison, full tooling
tests and retained evidence replay. If it lowers output sufficiently, integration
still needs complete local A/V, actual downstream output and scheduled recovery
gates before considering production use. If not, retain the negative result and
select the next action from the new evidence.

Reference: [Apple low-latency rate-control specification](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablelowlatencyratecontrol).

## First native result and failure preservation

The initial iOS 17.5 attempt `encoder-low-latency-zBzvvo` creates and measures the
default session but cannot create the session that requests low-latency control.
The native log reports `failedToCreate(status: -12908)`; the installed SDK names
this `kVTCouldNotFindVideoEncoderErr`. This does not establish support on a physical
iPhone. The attempt remains failed, with its complete raw attachment retained.

This exposed a diagnostic bug: a later snapshot ownership check replaced the
original codec failure with a generic missing-session error. Preserve the native
failure when final-snapshot collection also fails, and make the verifier report
it before checking snapshots that only successful sessions can supply. The new
regression fails before this change and passes afterward. Repeat the native request
to prove the retained error is the actual native status, not an inferred success.

The repeat `encoder-low-latency-LiWD2t` retains `codecFailed(status: -12908)` in
both the raw attachment and the verifier error. The mode is unavailable for this
simulator configuration; do not enable it or treat the request as a throughput pass.

## Bounded half-resolution comparison

Next measure a fresh 960×540 encoder against 1920×1080, both at 1.5 Mbps and 30 fps.
The earlier 720p comparison scales the 16-pixel source blocks to fractional coding
grid positions. Half resolution maps them to eight-pixel blocks and reduces pixel
count fourfold. This is a specific workload/scaling hypothesis, not an assertion
that bandwidth will decrease or a substitute for eventual camera footage tests.
Keep the original 1080p source and default encoder selection. Version 6 pins this
pair and checks every actual compressed output dimension. Retain all paced-source,
identity, native status and payload gates. It is a candidate fallback profile only;
local recording must retain its independent resolution when integrated later.

## Half-resolution result

`encoder-half-resolution-Y3ImPf` passes all 1202 compressed frame checks. The default
1080p session reproduces 5.576 Mbps; 960×540 produces 3.521 Mbps across its three
settled five-second windows (3.521, 3.523 and 3.517 Mbps), a ratio of 0.6314. Both
source submissions remain approximately 30 fps, every output frame has the expected
H.264 dimensions, and native rate/session checks pass. This is lower payload for
the same source, not proof that a 4 Mbps wire budget is sufficient: audio, muxing,
transport, retransmissions and bursts still matter. No decoded image-quality or
network recovery claim follows from this scalar probe.

All 904 tooling tests pass. Retained raw versions 1–4 and the fresh version-6 run
replay under the final verifier; both unsupported low-latency attempts remain
rejected. The latter repeat preserves the actual native failure instead of the
later missing-session error. Production, archive and Watch code remain unchanged.

Next qualify the reduced streaming profile through the complete native pipeline
with unchanged 1080p local recording, source/frame identity, A/V and receiver gates.
Measure actual wire load before selecting its safe bandwidth range. Dynamic profile
changes additionally require bounded encoder replacement, downstream format change,
receipt/source ownership and local-recording isolation tests; the current native
quality binding deliberately rejects cross-profile recommendations. Keep the
existing streaming failure and physical/Watch/remote-worker gaps open until those
gates pass.
