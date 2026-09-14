# Native recording and SRT compatibility experiment

The Mac fixture feeds the same immutable NV12/PCM samples to two consumers:
the shared segmented archive and the locally patched HaishinKit 2.2.5 SRT publisher. It exercises
actual AVFoundation encoders, an actual local SRT connection, and decoded outputs.
The [native app](native-film-app.md) uses the same archive/capture lifecycle and
production SRT adapter, with separate [native workflow qualification](native-streaming-qualification.md).

## Boundaries and ownership

`ScorebugMedia.BoundedMailbox` provides synchronous admission and one asynchronous
consumer without allocating a task for each captured sample. Item and byte limits
apply to queued buffers; each consumer can additionally retain one delivered sample.
Invalid or oversized offers cannot evict valid queued work.

The shared `RecordingSession` owns the archive queue and its single consumer.
The fixture now drives it through the same [capture-source owner](native-capture-source.md)
as the iPhone adapter, including explicit source-clock startup and callback quiescence.
It preserves accepted work and rejects overflow explicitly. The
fixture treats any archive rejection as failure. The live queue discards its oldest
queued samples when full. Neither network setup nor publisher failure cancels the
archive consumer. Capturing does not wait for publisher work or archive snapshots.
Owned PCM copies cross the SDK boundary; neither consumer mutates source samples.

Archive encoding stays at 1080p/30, H.264 12 Mbps and AAC 48 kHz/128 kbps. Live video
starts at 6 Mbps and changes to 2 Mbps after five source seconds. The archive's
profile never changes in response to that setting.

The SDK video input queue is set to four frames. Compressed output, transport-stream
output, and startup payloads now have explicit [SDK queue bounds](sdk-publishing-bounds.md);
socket sends apply direct bounded backpressure. Native encoder, driver, and OS
allocations are outside those logical payload limits. Longer congestion and recovery
tests remain required.

## Repeatable checks

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:dual-output
```

This generates a 14-second, 1080p/30 source with visible frame identities and
frequency-coded audio pulses. Each run owns its native processes and loopback UDP
port and preserves evidence under `artifacts/qa/dual-output-*`.

Five scenarios run: offline recording without a publisher, normal local receivers
with zero-origin and 123.25-second source clocks, a receiver suspended after six
seconds, and no receiver available. Every archive must retain all 420 source frames
and export successfully. Normal streaming must meet the fresh-frame cadence gate,
retain source frame zero, keep final-frame gaps within one second, and demonstrate an encoded bitrate
decrease measured from received packets. Receiver failure must be reported separately
while the archive finishes.

Both decoded tracks must span the same timeline within 100 ms, allowing bounded AAC
padding. Audio continuity and identified pulses check internal gaps and A/V alignment.
This prevents a truncated audio track from passing through good synchronization over
only its surviving portion. The same coverage assertion also runs in the archive
crash harness and worker soak analysis.
The worker's collector joins an already-running stream, so it explicitly allows
up to 2.1 seconds of extra audio before the first decoded keyframe. That allowance
does not relax the 100 ms limits for missing audio at either end of the video.

Queue statistics must stay within the 24 MiB archive and 12 MiB live queued-byte
limits. Process RSS is sampled every half second and must remain below 512 MiB.
The source producer must stay within 250 ms of its real-time schedule. These are
explicit experiment limits, not physical-phone performance claims.

## Evidence and remaining work

The initial full Mac run retained all 420 archive frames in every scenario. The
normal SRT output contained 419 fresh frames (source IDs 1–419) at 30 fps, with a
maximum measured A/V offset of 34.69 ms. Encoded video rate decreased from about
6.13 Mbps to 1.96 Mbps. Peak RSS stayed below 96 MiB across the three short runs.

Repeated runs exposed an SDK startup defect. In `dual-output-SLQYfb`, the clean
archive still retained all 420 video frames and complete audio, but SRT audio
ended 121.3 ms before video and correctly failed the unchanged 100 ms coverage
gate. All 672,000 input PCM samples were submitted, with no live-mailbox drops.
Compared with passing `dual-output-QeX2sO`, five initial AAC packets were lost.
After decoder warmup, the failed clip's PCM exactly matches the passing clip's
suffix through the final sample. Every identified audio marker shifts by the
same 106.7 ms. This identifies startup loss and timestamp rebasing, rather than
additional loss at shutdown.

The pinned SDK's TS writer discards media until both encoded formats are known,
then establishes separate first-packet timestamp origins for audio and video.
Encoder startup ordering therefore changes audio loss and synchronization.
The [maintained local correction](sdk-startup-patch.md) now bounds startup buffering,
preserves a common timestamp origin, registers subscriptions before publishing, and
accepts the first video frame at timestamp zero. The PCM adapter also preserves
host and sample clocks independently of the source timestamp timescale.

The corrected five-case run (`dual-output-nHltS0`) passed every existing coverage
and synchronization gate. Both normal streams retained all 420 fresh frames
(IDs 0–419), with maximum measured A/V offsets of 65.38 ms and no frame loss.
Their encoded rate fell from about 6.1 to 2.0 Mbps. Every archive retained all
420 frames and full audio, including the nonzero-clock case with no blank clock
lead-in. Peak process RSS across all cases stayed below 95 MiB. These are
14-second Mac fixture results, not sustained or physical-device qualification.

Native mailbox tests cover count/byte limits, actual object retention, cancellation,
finish/drain, concurrent waiter rejection, and producer/cancellation races. The
Thread Sanitizer runner crashed before running tests, so there is no sanitizer
validation claim.

The SDK's full iPhone executable link requires an explicit C++ runtime dependency.
The resolved Intel simulator archive is missing SRT symbols despite advertising an
x86_64 slice; ARM64 simulator linking is tested for this Mac. Library compilation
alone had not exposed either issue.

The final production-stop run (`dual-output-6FUFL0`) passes all five scenarios with
no extra probe sleep after input ends. All archives retain 420 frames and 672,000
PCM samples; both normal live outputs retain frames 0–419 at 30 fresh fps. Their
encoded rates fall from approximately 6.1 to 2.0 Mbps. Peak RSS is 97.5 MiB and
maximum source scheduling lag is 11.2 ms, within the unchanged 250 ms gate.
An earlier run (`dual-output-vhcdqH`) preserved every archive frame but failed that
scheduling gate at 271.8 ms while other build work was active. The isolated rerun
passed; this does not establish tolerance of arbitrary host contention.

Still required: sustained dual encoding, network loss/jitter/bandwidth shaping,
reconnection, adaptive quality, and physical iPhone qualification. Production
publisher orchestration and capture-role registration are integrated.
Offline Simulator app workflows have a separate
[native app validation runner](native-film-app.md). Native Watch scoring
remains a separate planned milestone.
