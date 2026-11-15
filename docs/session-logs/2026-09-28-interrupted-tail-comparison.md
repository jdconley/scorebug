# Interrupted output-tail comparison — September 28

Starting36c93c2; prior turn completed intermittent-loss/media coverage. No active
jobs carried over. No production media settings changed, no hardware/broad suites.

## Small decoder/backend comparison

Used production buildFfmpegArgs with representative1080source, realtime file input,
actual overlayMP4 and SIGTERM after at least180outputframes. Compared automatic/slice
input decoding for VideoToolbox/software output. Same flags apart from those choices;
all process and diagnostic pipes joined. This isolates proxy termination with a file
input, not liveSRT or workerIPC loss.

Initial attempt failed before spawning FFmpeg because a WriteStream had not opened
its descriptor. Fixed fixture by piping stderr and giving every attempt a fresh
run directory. The actual four-case process43499 joined0, run-krr5eu; no orphaned job.
(Initial tool command exit1 had no persistent process handle.)

A/V end differences: VideoToolbox automatic5.5ms/slice17.9ms; software automatic28.0ms/
slice7.1ms. Full ffprobe frame scans succeeded. All fourFFmpeg exits255 follow the
requested SIGTERM; none timed out/SIGKILL. The reported joinAfterSignalMs also includes
post-exit ffprobe time, so it is not a precise shutdown-latency measurement.
This does not reproduce the old508–548ms live tail. No decoder default change justified.
Script/args/logs/probes/results: artifacts/qa/interrupted-tail-20260928.

## Current live worker crash

Added `--worker-crash-after` to the existing headless harness. It reuses the lab's
owned SIGKILL/restart operation, excludes other fault modes, waits for native readiness,
and requires the same still-publishing native session. Production apps unchanged.

`headless-native-MAuIfq`, lab`device-lab-nRGPEh`: capture10982/export-media53068 joined0,
cleanup[]. Scoped Xcode26.2, software proxy, prepared1080fixture,70s, auditoff,
worker crash15s. Exact source/harness hashes retained. Worker truly killed; replacement
ready15.186s later. One native attempt/generation1, oneStart/finalStop; recording and
publishing remain active. The initial audio tail is107.0ms in mockRTMP and107.4ms in
proxyMP4. Recovered ends within36ms; cleanarchive25.3ms.

37archive segments verified;2,124consecutive frames0–2123 and gap-free audio. Both
outputs have source62–442 then962–2104. All five files fully decode, no within-session
frame identity/audio gaps. Livegap519missing sourceframes =17.3seconds. Archive
continues19frames past live. This is recovery, not seamless worker-crash streaming.

`worker-crash-analysis.json` binds files, source, verifier, restart and cleanup hashes;
`reconnect-media/result.json` has per-file results. The latter's media pass covers
continuity within segments; it does not impose an interrupted-tail threshold.

## Decision and next work

Leave automatic decoder threading and encoder settings unchanged. Current short
native crash behaves better than the retained simulator/VideoToolbox result, but
platform/backend/version differences are not isolated causally. No general bound
across timing/load established. Do not repeat the four file-input comparisons or
an unchanged full native crash run.

The startup-only TS mux buffering is not ongoing cross-track interleaving: audio and
compressed video emit on arrival. Live encoding can therefore put audio ahead of
video. This is a possible contributor, not a proved cause. Any future alignment
change must preserve timestamps, bounded buffering, graceful final audio and archive
independence; do not add a speculative queue merely to improve this tail.

Next prioritize sustained local1080/UHD qualification on the working software-proxy
path; reuse all UI/scoring/fault passes. Keep the remaining crash-tail/backend limits
explicit. All jobs terminal, no active processes from this work.
