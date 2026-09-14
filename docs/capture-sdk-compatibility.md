# Capture and SRT SDK compatibility

The isolated [probes](../tools/media-sdk-probe/README.md) now include macOS dual
recording/SRT execution and full executable linking for ARM64 iOS Simulator and
an unsigned generic iPhone destination with iOS 17 deployment.
It uses a [locally patched source subset](sdk-startup-patch.md) of HaishinKit **2.2.5**, revision `dc880cb540b8feeb98f64e8b7dcfaaf320b6b2bd`,
and Logboard **2.6.0**. The original camera scaffold remains unchanged and unqualified.

The pinned package declares iOS 15+/macOS 12+ and includes libsrt 1.5.4 for both
platforms. No camera session or physical device has been exercised. The
[dual-output fixture](native-dual-output.md) validates actual Mac encoding and SRT.
[Package source](https://github.com/HaishinKit/HaishinKit.swift/blob/2.2.5/Package.swift).

## API findings that affect the implementation

`SRTConnection` and `SRTStream` are actors. The adapter must retain both, because
the stream's connection reference is weak. Settings are changed through asynchronous
`setVideoSettings` / `setAudioSettings` methods, not property assignment. Those
methods throw in this version. Connection opening throws; stream publish and both
close methods do not. Publish can return without starting when disconnected, so
its return alone is not readiness evidence. Set expected video/audio media before
publishing when samples will arrive afterward.

The `CMSampleBuffer` append overload handles **video only**. Passing raw audio to
it silently omits audio. PCM requires an owned `AVAudioPCMBuffer` and `AVAudioTime`,
then the separate `append(_:when:)` overload. The probe compiles a source-format
preserving copy with `CMSampleBufferCopyPCMDataIntoAudioBufferList` and carries the
sample's presentation timestamp into the audio time. The Mac fixture now validates
source-frame identities, decoded audio coverage, and A/V alignment through this path.
[SRT stream source](https://github.com/HaishinKit/HaishinKit.swift/blob/2.2.5/SRTHaishinKit/Sources/SRT/SRTStream.swift).

Changing video bitrate uses the current settings and their setter. Source inspection
shows bitrate alone can update an existing compression session. The fixture measures
the received video rate dropping from approximately 6.13 Mbps to 1.96 Mbps while
the independently encoded archive retains every source frame. This establishes a
manual bitrate change, not an adaptive quality policy.

The connection's performance data includes cumulative sent bytes, packet drops,
loss/retransmission, RTT, bandwidth estimate, and send-buffer size/time. These are
transport measurements. Capture drops, mailbox drops, encoded fresh frames, and
archive failures require separate counters.

The SDK supports a bounded newest-video buffer, but this does not bound tasks
created before SDK ingress. The app needs retained capture delegates, bounded
publisher mailboxes with one consumer each, and separately serialized archive
ownership. `@preconcurrency import` is not proof of safe sample ownership.

Further source inspection finds default unbounded `AsyncStream` queues in both
`TSWriter.output` and the socket's outgoing data path. A bounded app mailbox alone
does not establish a bound for the whole publishing pipeline. Short stalled-receiver
tests pass with bounded app queues, finite socket deadlines, and RSS observations.
Sustained congestion, recovery, and SDK buffer behavior still need qualification
before production acceptance.
[TS writer source](https://github.com/HaishinKit/HaishinKit.swift/blob/2.2.5/SRTHaishinKit/Sources/TS/TSWriter.swift),
[socket source](https://github.com/HaishinKit/HaishinKit.swift/blob/2.2.5/SRTHaishinKit/Sources/SRT/SRTSocket.swift).

The SDK URI passes socket options directly to libsrt: `latency=120` is milliseconds.
FFmpeg's corresponding URI option uses microseconds (`latency=120000`). The fixture
also supplies finite connection, send, and peer-idle timeouts through SDK-supported
option names; FFmpeg does not accept all the same names.

Full executable linking exposed two gaps missed by library compilation: the consumer
must link `libc++`, and the resolved libsrt archive's advertised x86_64 simulator
slice lacks SRT function symbols. The package now declares the C++ runtime; this
Mac's ARM64 simulator and the ARM64 iPhone executable link successfully. Intel
simulator linking remains unsupported with this resolved binary.

## Recording correction and integration work

The camera scaffold requests raw NV12 video. Its writer currently treats that as
compressed H.264 pass-through with nil output settings. The replacement must
configure H.264 and AAC encoding for raw video/PCM, check each start/append/finish
result, and preserve a shared timestamp origin. It must isolate recording from
publishing, including offline operation and publisher bitrate changes.
[Apple's writer input contract](<https://developer.apple.com/documentation/avfoundation/avassetwriterinput/init(mediatype:outputsettings:)>).

The [native archive fixture](native-archive.md) now exercises valid H.264/AAC
encoding, fragment completion/recovery, and full-decode MP4 export on macOS.
It runs independently of the SDK and is also used by the dual-output fixture.

The synthetic simultaneous archive/SRT experiment has passing normal, unavailable,
and suspended local receiver runs, but repeated validation exposed variable initial
audio loss in the SDK's TS writer. It discards packets until both formats are known
and rebases each track independently. A failing run lost five additional initial
AAC packets and exceeded the unchanged audio-coverage budget; decoded PCM comparison
confirms the loss occurs at startup. See the [diagnosis](native-dual-output.md).
The maintained local SDK patch now passes all five real-media scenarios, including
a nonzero source clock, with every first video frame retained and the original
100 ms coverage/synchronization limits unchanged. Its 35 vendor tests, three PCM
clock tests, and full ARM64 Simulator/iPhone executable links pass.
Next are sustained load/reconnection tests and the actual camera lifecycle. iOS runtime media behavior,
hardware camera interruptions, and physical-phone simultaneous encoding remain
unverified.
