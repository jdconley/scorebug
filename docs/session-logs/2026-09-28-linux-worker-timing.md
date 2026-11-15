# September 28 — portable worker encoder timing

Startingfc74498, clean. Previous goal turn provided fresh crash evidence; no
lab/test jobs active. This turn fixes a portable-worker capability gap.

## Finding and change

Bookworm worker image starts and encodes, but its installed FFmpeg5.1.9 reports
encoder statistics unavailable. This omits processing evidence needed by native
measured adaptation. The existing image check did not exercise timing.

Changed only worker base from node:22-bookworm-slim to node:22-trixie-slim.
Debian's [Trixie package](https://packages.debian.org/trixie/ffmpeg) and official
[Node image tags](https://github.com/docker-library/official-images/blob/master/library/node)
were checked. Actual built image reports FFmpeg7.1.5 and Linuxarm64.
Control-plane/relay images and production encoder/adaptation settings unchanged.

Extended existing CI-used test-worker-container.mjs: require encoder-statistics
probe success, enable timing on compiled production pipeline, require completed
frames/no pending or invalid timing, verify output progress, and fully decode
both FLV stream-format output and overlaid MP4. Failure diagnostics are retained
in private700directory/600file instead of being discarded behind a generic error.

## Targeted verification

Artifacts: `artifacts/qa/linux-worker-20260928`. Built baseline tag
`scorebug/home-daemon:qa-bookworm-fc74498`,24248 joined0. Enhanced check failed;
independent compiled capability probe returned available:false/reason:unsupported.

Built changed tag `scorebug/home-daemon:qa-timing-trixie`,7457 joined0. Initial
media check failed output-progress assertion. Private diagnostic qhrqLQ and one
focused compiled-pipeline probe showed60completed frames/valid timing, valid
outputs, but only final progress outTimeUs0. Finite unpaced input completed before
first periodic progress; it was not a missing timing or invalid encoding result.
Two diagnostic-program extraction attempts failed before starting a container;
the corrected extraction produced diagnostic-output.log.

Paced only the test file input with an ffmpeg -re wrapper; retained the progress
assertion and production settings. Final command:
`node scripts/test-worker-container.mjs scorebug/home-daemon:qa-timing-trixie`
passes,50899 joined0, check-paced.log. Startup, compiled720p dual-format pipeline,
actual valid encoder timing, full A/V decode, graceful exit0 and owned-container
cleanup pass. Docker ps confirms no containers remain. Both new image tags remain
for reproducibility; image IDs/versions/build logs/check logs and source hashes
are bound in acceptance.json. No simulator, hardware, full suite or long soak.

Scope is two-second Linuxarm64 local Docker media/capability qualification;
no real SRT/RTMP networking, full native adaptive ladder, sustained/Linux-host,
amd64 or NVIDIA claim. Next portable integration can reuse the working image.
