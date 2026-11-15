# Current simulator crash regression — September 28

Starting6221bdb. Prior turn made progress by gating local configurations and rejecting
a generic shortest-output change. This turn checks the remaining crash gate against
current code instead of treating historical failures as current evidence.

## Source and small comparisons

Confirmed the original100ms end-offset gate remains in native-tail-diagnosis; no
threshold change. Reviewed FFmpeg8.1.2 source: q and first SIGTERM both reach scheduler
shutdown. The deprecated muxer shortest flag was removed in2025; do not use stale
Doxygen/docs to add it to this runtime:
https://ffmpeg.org/pipermail/ffmpeg-cvslog/2025-March/147921.html

A production-buildFfmpegArgs single-input comparison corrected the scope of the
prior independent-input shortest failure. artifacts/qa/production-shortest-20260928/
run-yLuLS1:76video frames in each case, baseline+8.458ms, shortest−14.762ms. An
explicit slow-video-filter case run-EJ1PpG yields baseline89frames/−30.135ms and
shortest88frames/+3.198ms. Both SIGTERM exits255, no kill timeout. Neither reproduces
the actual bad tail or establishes a necessary production change. Therefore no
shortest flag, queue, timeout or stop-mode change. No more parameter comparisons.
The initial loader command exited before work; resolved package-local tsx loader.
run-n0FK7o is a failed fixture graph edit with no media, preserved separately.

## Current simulator result

Saved worker logs prove QOuplL and SvL3gk used software, despite the plan's old
VideoToolbox label. Corrected that attribution. SvL3gk predates DTS interleaving.

Ran exactly the existing server-crash lane (one iPhone14/iOS26.2 simulator, no Watch):

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 \
  --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov \
  --encoder software --lane server-crash
```

Capture65976 exit0; ordinary-native-Ha71gs, labdevice-lab-iMmJhG, producing code6221bdb.
Native UI observes API then worker outages, automatic restoration while recording/
publishing continue, subsequent stop, independent archive continuation and export.
Workflowpassed=true, cleanupFailures=[], mediaQualified remainsfalse as originally
reported. Only the owned test device69EAF4FB-9195-47BB-8B0D-23C0DA26B3FE was removed.

Targeted saved-media command49178 exit0:
`python3 artifacts/qa/production-shortest-20260928/check-crash-tails.py artifacts/qa/ordinary-native-Ha71gs`.
All three proxy and three mock MP4s fully decode, both A/V have actual decoded
frames, and ends differ43.046–59.826ms. Proxy/mock frame counts match167,580,606.
crash-tail-verification/results.json and evidence.json bind files, original workflow,
producing commit and verifier. No output is overwritten. This is one current
simulator/software configuration, not all timing/load/backends, waveform, source
identity or archive continuity qualification. Reuse prior archive/media evidence.

The specific old simulator crash failure is not reproduced on current code. This
is a regression pass, not proof of isolated causality or a general hard bound. Keep
historical failures and remaining qualification; do not rerun this scenario unchanged.
No production code changed. Full-suite, hardware, cloud and soaks were not run.

## Next

The simulator feature checkpoint and current crash check now pass. Asked once whether
phone/Watch are connected/unlocked for the next physical stage; answer pending when
this log was written. Do not poll devices or repeat the question before a reply.
If hardware remains deferred, keep its checks and actual other-host qualification
open. All command handles from this session are terminal.
