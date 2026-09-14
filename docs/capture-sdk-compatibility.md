# Capture and SRT SDK compatibility

The isolated [compile probe](../tools/media-sdk-probe/README.md) passed on macOS,
iOS Simulator, and an unsigned generic iPhone destination with iOS 17 deployment.
It pins HaishinKit **2.2.5**, revision `dc880cb540b8feeb98f64e8b7dcfaaf320b6b2bd`,
and Logboard **2.6.0**. The original camera scaffold remains unchanged and unqualified.

The pinned package declares iOS 15+/macOS 12+ and includes libsrt 1.5.4 for both
platforms. These are package/build findings; no camera session, active encoder,
SRT connection, or physical device was exercised by this probe.
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
sample's presentation timestamp into the audio time. Runtime sample integrity and
cross-actor buffer ownership still need fixture tests.
[SRT stream source](https://github.com/HaishinKit/HaishinKit.swift/blob/2.2.5/SRTHaishinKit/Sources/SRT/SRTStream.swift).

Changing video bitrate uses the current settings and their setter. Source inspection
shows bitrate alone can update an existing compression session; the probe verifies
the call signature but does not establish live adaptation behavior.

The connection's performance data includes cumulative sent bytes, packet drops,
loss/retransmission, RTT, bandwidth estimate, and send-buffer size/time. These are
transport measurements. Capture drops, mailbox drops, encoded fresh frames, and
archive failures require separate counters.

The SDK supports a bounded newest-video buffer, but this does not bound tasks
created before SDK ingress. The app needs retained capture delegates, bounded
publisher mailboxes with one consumer each, and separately serialized archive
ownership. `@preconcurrency import` is not proof of safe sample ownership.

## Recording correction and next experiment

The camera scaffold requests raw NV12 video. Its writer currently treats that as
compressed H.264 pass-through with nil output settings. The replacement must
configure H.264 and AAC encoding for raw video/PCM, check each start/append/finish
result, and preserve a shared timestamp origin. It must isolate recording from
publishing, including offline operation and publisher bitrate changes.
[Apple's writer input contract](<https://developer.apple.com/documentation/avfoundation/avassetwriterinput/init(mediatype:outputsettings:)>).

The next slice is a synthetic NV12/PCM source feeding both a separately encoded
archive and an SRT adapter with these verified signatures. Fully decode both outputs,
measure synchronization, change publisher bitrate while recording continues, and
exercise shutdown/failure paths. Then add segment completion/recovery and actual
camera lifecycle. Buffer pressure, active bitrate changes, crash recovery, iOS runtime
behavior, and simultaneous encoding performance remain unverified.
