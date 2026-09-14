# Native recording and SRT compatibility experiment

The Mac fixture feeds the same immutable NV12/PCM samples to two consumers:
the shared segmented archive and HaishinKit 2.2.5 SRT publishing. It exercises
actual AVFoundation encoders, an actual local SRT connection, and decoded outputs.
The prototype camera app is not integrated yet.

## Boundaries and ownership

`ScorebugMedia.BoundedMailbox` provides synchronous admission and one asynchronous
consumer without allocating a task for each captured sample. Item and byte limits
apply to queued buffers; each consumer can additionally retain one delivered sample.
Invalid or oversized offers cannot evict valid queued work.

The shared `RecordingSession` owns the archive queue and its single consumer.
It preserves accepted work and rejects overflow explicitly. The
fixture treats any archive rejection as failure. The live queue discards its oldest
queued samples when full. Neither network setup nor publisher failure cancels the
archive consumer. Capturing does not wait for publisher work or archive snapshots.
Owned PCM copies cross the SDK boundary; neither consumer mutates source samples.

Archive encoding stays at 1080p/30, H.264 12 Mbps and AAC 48 kHz/128 kbps. Live video
starts at 6 Mbps and changes to 2 Mbps after five source seconds. The archive's
profile never changes in response to that setting.

The SDK video input queue is set to four frames. Its internal transport-stream and
socket output queues do not expose hard size limits. The probe sets finite socket
deadlines and observes whole-process memory, but these short tests do not prove
every SDK allocation is bounded. Longer congestion and recovery tests remain required.

## Repeatable checks

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:dual-output
```

This generates a 14-second, 1080p/30 source with visible frame identities and
frequency-coded audio pulses. Each run owns its native processes and loopback UDP
port and preserves evidence under `artifacts/qa/dual-output-*`.

Four scenarios run: offline recording without a publisher, a normal local receiver,
that receiver suspended after six seconds, and no receiver available. Every archive must retain all 420 source frames
and export successfully. Normal streaming must meet the fresh-frame cadence gate,
keep startup/final-frame gaps within one second, and demonstrate an encoded bitrate
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
Earlier successful runs do not establish reliable startup. A verified upstream
fix or maintained patch with bounded startup buffering and a common timestamp
origin is required before production publishing integration. Do not relax the
coverage or sync gates to accommodate this defect.

Native mailbox tests cover count/byte limits, actual object retention, cancellation,
finish/drain, concurrent waiter rejection, and producer/cancellation races. The
Thread Sanitizer runner crashed before running tests, so there is no sanitizer
validation claim.

The SDK's full iPhone executable link requires an explicit C++ runtime dependency.
The resolved Intel simulator archive is missing SRT symbols despite advertising an
x86_64 slice; ARM64 simulator linking is tested for this Mac. Library compilation
alone had not exposed either issue.

Still required: sustained dual encoding, network loss/jitter/bandwidth shaping,
SDK startup correction, reconnection, bounded production capture and publisher orchestration, the camera UI,
Simulator app workflows, and physical iPhone qualification. Native Watch scoring
remains a separate planned milestone.
