# Native encoder property diagnosis

The qualified payload probe at `0bc1d4a` measures 5.576 Mbps for both dynamic-low
and fresh-low despite accepted 1.5 Mbps properties. Before changing production
configuration, identify the actual simulator encoder and its rate-control support.

Extend only the isolated probe with a bounded allowlist of native session property
snapshots immediately after bootstrap and after all paced frames complete. Record
the supported-property query status, each property's presence/type/read-write
metadata, property-copy status, and bounded scalar value. Query EncoderID,
UsingHardwareAcceleratedVideoEncoder, AverageBitRate, DataRateLimits, RealTime,
ExpectedFrameRate, ProfileLevel, AllowFrameReordering, Quality, MaxAllowedFrameQP,
MinAllowedFrameQP, ConstantBitRate, MaxFrameDelayCount and MaxKeyFrameIntervalDuration.
Unsupported or unavailable properties remain explicit; do not invent defaults.
Bind both snapshots to the verified encoder-session UUID and collection interval;
verify the same native session object survives throughout the measured run. Collect
the final snapshot after completing frames and before invalidating the session.
Preserve Boolean versus numeric values. Unexpected optional readbacks remain in
the raw artifact even when they prevent qualification.

Version 2 of the scalar report requires both snapshots and validates their fixed
shape, exact keys, bounded values and expected accepted bitrate/data-limit settings.
Profile, frame-rate and other optional properties remain recorded diagnostics.
Version 1 remains replayable for retained evidence. Preserve all existing source
identity, configuration, payload and pacing checks. Querying is outside the paced
interval so it cannot alter the measured submission cadence. Do not add media
retention, network activity or native property writes.

Run red/green verifier tests, the existing isolated iOS 17.5 probe, and tooling
regressions. Then select a bounded fresh-session comparison from observed support,
such as moving ExpectedFrameRate before encoder preparation or using low-latency
rate control. Each comparison must use the same source pixels, cadence and output
measurement; unsupported native configurations are failures/unsupported results,
never a throughput pass. Production adaptation, network recovery, physical devices,
resolution transitions and other hosts remain open.

Apple's [live-streaming guidance](https://developer.apple.com/documentation/VideoToolbox/encoding-video-for-live-streaming)
and the installed Xcode 26.2 SDK headers describe rate control and expected frame
rate. The code currently writes ExpectedFrameRate after PrepareToEncodeFrames.
That ordering is a hypothesis to test, not an established cause. ConstantBitRate
is not a default remedy: the SDK describes incompatible average/data-limit
properties and a specialized CDN use case.

## Property result and controlled preparation comparison

The qualified version-2 run `encoder-payload-RTsoZI` reproduces all 2402 frames and
the prior payload totals. Both sessions report EncoderID `anon-1`, ExpectedFrameRate
30, RealTime true, H264 High AutoLevel, reordering false and a two-second keyframe
interval. AverageBitRate and DataRateLimits read back as requested before/after the
run. Hardware-acceleration status, ConstantBitRate, Quality, min/max frame QP and
MaxFrameDelayCount report -12900 (unsupported). Supported-property dictionaries
provide no type/read-write metadata for the supported entries; these remain null.
Do not infer hardware versus software from the anonymous ID or unavailable flag.

Compare two fresh 1.5 Mbps sessions with the same 600-frame input: the maintained
production factory's post-prepare ExpectedFrameRate write and a test-only factory
that moves only that write before PrepareToEncodeFrames. The latter duplicates
the small native creation sequence intentionally and uses the same native codec,
encoder specification, options, attributes, callbacks, bootstrap and verified
rate path. No vendor or production source changes. Check native status for each
early-factory step; retain errors and raw evidence.

Use a separate XCTest method and exact selected test in the owned runner via
`--preparation`. Version 3 identifies this fixed experiment and its two ordered
preparation modes. Reuse all frame/session/timing/payload/native-snapshot checks;
report actual settled bytes and early/late ratio without demanding a reduction.
Version 1/2 evidence remains replayable. This isolates ordering as a hypothesis;
passing data integrity does not qualify bandwidth recovery or physical devices.

The preparation comparison `encoder-preparation-vvQ9g2` qualifies all 1202 frames.
Both fresh sessions report the same encoder ID and native property values and
produce exactly the same settled window byte totals (5.576 Mbps mean). Moving the
frame-rate write earlier does not fix this simulator workload. Preserve the test
as a reproducible negative result; make no production ordering change from it.

## Fresh resolution comparison

Next compare fresh 1920x1080 and 1280x720 encoders, both requesting 1.5 Mbps, using
the same 1920x1080 source pixels and 30 fps cadence. Change only the encoder output
size using the maintained VideoCodecSettings path. Keep the normal preparation,
scaling mode, rate properties and all receipt/pacing checks. Observe each compressed
sample's actual H.264 format dimensions, not merely configured size. Version 4
pins these two resolutions and checks every output frame; report their settled
payload ratio without presupposing success. Select this test alone with
`--resolution`; preserve the earlier exact tests and evidence replay.

This assesses a necessary candidate for bandwidth fallback while clean local
recording can retain its independent profile. It does not implement live resolution
switching, qualify decoded visual quality, prove network recovery or enable
production adaptation. Dynamic encoder recreation, downstream reconfiguration,
archive isolation and physical-camera behavior need separate integration gates.

The qualified resolution run `encoder-resolution-hXxUHg` retains all 1202 frames
at the requested dimensions and paced 30 fps. At a requested 1.5 Mbps, settled
1080p payload is 5.576 Mbps while 720p is 7.614 Mbps (1.366 times higher). This
structured workload therefore does not support assuming that this resolution
reduction will fit the 4 Mbps uplink. Do not promote it as a bandwidth fix. The
same source contains block boundaries whose relation to the coding grid changes
when scaled; that is a possible explanation to investigate, not a measured cause.

Before changing production policy or adding more rate-control guesses, repeat the
exact version-2 native-properties/payload probe on the installed iOS 26.2 simulator.
Keep iOS 17.5 evidence intact. Runtime agreement/disagreement helps scope the
problem but still cannot establish physical iPhone encoder behavior.

The iOS 26.2 repeat `encoder-payload-emLklD` qualifies all 2402 frames and reproduces
the iOS 17.5 phase byte totals exactly: 6.020, 5.576, 5.576 and 5.576 Mbps. Its
allowlisted supported-property/readback results also match iOS 17.5, including
anonymous EncoderID and unavailable hardware status. This rules out an issue
isolated to the older simulator runtime; it does not establish equivalence with a
physical encoder or prove the common simulator encoder's implementation.

All 897 tooling tests pass. The four native diagnostic runs in this checkpoint
qualify 7208 compressed frames in total. Previous version-1 evidence independently
replays under the updated verifier. Production/Watch code and vendor encoder code
remain unchanged, so this checkpoint does not claim fresh physical-device, release,
recording soak or network-recovery qualification. Evidence and source hashes are
recorded in `artifacts/qa/encoder-properties-final-verification.json`.

Next prioritize retaining/finalizing local recording and bounded worker evidence
when a live qualification fails, then physical encoder readiness and a bounded
further native configuration experiment if available. Any fallback policy must
use measured output/cadence and validated profiles, not assume a smaller requested
bitrate or resolution reduced the actual payload. The failed recovery remains an
open integration gate; these diagnostic passes are evidence integrity only.
