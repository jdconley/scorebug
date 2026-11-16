# Stream + Container Spike: Results

Status: measured 2026-11-16, 18:07–19:02 UTC. The spike code is on branch
`spike/stream-container` and is not merged. Everything it created has been torn
down.

Plan: `docs/superpowers/plans/2026-11-16-stream-container-spike.md`. Spec:
`docs/superpowers/specs/2026-11-16-hosted-cloudflare-design.md`, section
"Phase 0: spike before building".

## Verdict

**Proceed with option 2 at 1080p30 on `standard-4`, with Stream as intake.
Don't start the container early.**

- **Passes:** CPU, latency, feed drops and cold start all pass with room to
  spare.
- **Score lead (marginal fail):** the score runs 1.1–1.2 s ahead of the
  video, just over the 1 s bar. The spec's own remedy fixes it: the worker
  delays score changes by about 1.1 s.
- **Port work:** the main item is the worker's recovery after a feed drop.
  The broadcast always survives, but video takes 22–28 s to come back after
  the phone's feed returns. Tune it during the port. It doesn't block
  option 2.

| #   | Measure                        | Bar                            | Result                                                                          | Verdict                                        |
| --- | ------------------------------ | ------------------------------ | ------------------------------------------------------------------------------- | ---------------------------------------------- |
| 1   | CPU at 1080p30, 30 min         | < 80%, no drops                | 31% busy (max 33%); speed 1.00; one FFmpeg run for 30 min                       | Pass                                           |
| 2   | Glass-to-glass latency         | < 30 s                         | 21.2–21.5 s (YouTube "Normal latency"); 13 s after YouTube re-syncs             | Pass                                           |
| 3   | Score lead                     | within 1 s                     | 1.10–1.20 s (6 changes)                                                         | Marginal fail; fix by delaying the score 1.1 s |
| 4   | Feed drops 10 s / 60 s / 5 min | same broadcast and link resume | Same video ID, `is_live` throughout; viewer resumed without a reload every time | Pass                                           |
| 5   | Cold start                     | < 30 s                         | 16.5–16.8 s to fresh frames at YouTube's edge (worker output at 12.4 s)         | Pass                                           |
| 6   | Cost                           | record it                      | About $0.33 per streaming hour at list price (estimate; see below)              | Recorded                                       |

## Setup as run

- **Source:** FFmpeg 7.1 (Debian, libsrt) in Docker on JD's Mac. It sends a
  1080p30 `testsrc2` pattern, 6 Mbps H.264 with GOP 60, plus AAC, over SRT to
  a Stream live input with recording off. The UTC wall clock is burned into
  the top right to the millisecond.
- **Container:** one Cloudflare Container on `standard-4` (4 vCPU, 12 GiB),
  `durable_object` scheduling policy. It runs the unchanged
  `apps/home-daemon` image with `ENCODER=software` (x264 `veryfast`,
  `zerolatency`) and `VIDEO_PROFILE=1080p30`.
- **Fake control plane:** a Durable Object answers the worker at
  `http://api.internal/` through a single outbound intercept. It advances
  the score every 20 s.
- **Output:** RTMPS to an unlisted YouTube broadcast with auto-start on and
  auto-stop off.

## Deviations from the plan

- **SRT pull from Stream, not RTMPS.** The unchanged worker's
  `WorkerClient` rejects any `readUrl` that isn't `srt:`. So the container
  pulls Stream's `srtPlayback` URL (`srt://live.cloudflare.com:778`, with a
  passphrase and stream ID). This worked first time. **Recommendation:** keep
  SRT playback for the port. Then the worker needs no RTMPS input path and
  keeps its tested SRT reader. The spec says RTMPS and should change.
- **Burned clock.** The plan's `drawtext` mixed wall-clock seconds with PTS
  milliseconds, which don't line up. Frames were instead stamped with
  `setpts=RTCTIME` before `drawtext`, so the burned time is the real capture
  time to the millisecond. The clock moved to the top right because the
  scorebug covers the top left.
- **CPU from inside the container.** The dashboard wasn't reachable from
  the session. The Durable Object ran `ctx.container.exec()` to sample
  `/proc/stat` twice, 5 s apart, every 30 s. It also read the per-process
  ticks for `ffmpeg` and the worker's 1 s status reports (frame and
  `out_time`) for fps and speed.
- **Logs.** The container entrypoint is the Dockerfile's command wrapped as
  `tini -g -- sh -c 'node … | tee /tmp/worker.log'`, so logs could be read
  with `exec`. The worker code is unchanged.
- **Latency** was read from the real YouTube player in Chrome: a screenshot
  bracketed by `Date.now()` calls, plus the player's own `live_latency_secs`.
  YouTube's HLS edge was also polled with `yt-dlp`. The YouTube DVR wasn't
  needed: score lead came from a recording of YouTube's 1080p HLS, with
  frame-accurate change detection and tesseract to read the clock.
- **Tooling:** Wrangler 4.163.0, as a local dev dependency. The installed
  4.81 predates the `durable_object` policy. The first `wrangler deploy`
  reported a 404 while applying the container settings, and running it again
  succeeded.
- **720p30 wasn't run,** because 1080p30 passed measure 1.
- **Measure 6 uses list prices.** The billing pages update the next day.

## 1. CPU headroom at 1080p30

Samples every 30 s over 18:11:37–18:42:07 UTC (62 samples). Each sample is a
5 s `/proc/stat` window on the 4-vCPU VM.

| Window                    | Busy (user+sys+irq)   | Steal                 | FFmpeg cores | Output fps | Speed             |
| ------------------------- | --------------------- | --------------------- | ------------ | ---------- | ----------------- |
| Clean source, 18:11–18:24 | mean 31.0%, max 32.6% | mean 20.0%            | 1.27         | 29.5       | 1.00              |
| Whole 30 min              | mean 28.0%, max 32.6% | mean 18.3%, max 34.6% | 1.13         | 25.8       | 1.00 (0.987–1.13) |

- **Pass.** Busy CPU never went above 33%, and busy plus steal peaked at
  66%. The worker stayed on one FFmpeg attempt for the whole 30 minutes,
  always `producing_output`, with encode speed 1.00. Memory used was about
  0.8 GiB of 12 GiB.
- **Steal is significant (11–35%).** The 4 vCPUs share a host with noisy
  neighbors. The headroom still covers it.
- **Dropped frames came from the source, not the container.** From minute 5
  the Mac's FFmpeg dropped frames: 621 by 15 min and 6,283 by 28 min. Its CFR
  output was fighting the `RTCTIME` stamps on a Mac at load average ~8.
  Output fps followed the source down to ~22, while the container's encode
  speed held at 1.00 and its CPU fell with the frame rate. Nothing points to
  frames dropped inside the container. A later fix (`-fps_mode passthrough`
  at the source) was used for the drop and cold-start runs.

## 2. Glass-to-glass latency

Chrome on the same Mac played the watch page at YouTube's default **Normal
latency**:

| Screenshot (UTC) | Burned clock | Glass to glass | YouTube `live_latency_secs` |
| ---------------- | ------------ | -------------- | --------------------------- |
| 18:13:33.76      | 18:13:12.600 | 21.2 s         | 19.4 s                      |
| 18:13:55.57      | 18:13:34.333 | 21.2 s         | 19.4 s                      |
| 18:14:06.39      | 18:13:45.166 | 21.2 s         | 19.5 s                      |
| 18:14:17.01      | 18:13:55.766 | 21.2 s         | 19.4 s                      |
| 18:14:27.85      | 18:14:06.366 | 21.5 s         | 19.5 s                      |

- **Precision:** the screenshot bracket is ±0.3–0.5 s, and the Docker clock
  was within 20 ms of the Mac's.
- **Our hop is small.** YouTube measures its latency from its own ingest. So
  the path from the source through Stream and the container to YouTube adds
  only about 1.8 s. The rest is YouTube's player buffer.
- **Edge vs player.** A segment appears in YouTube's HLS playlist 4.1–5.5 s
  after its last frame was captured.
- **After a drop:** once the player re-synced, it ran at about 13 s glass to
  glass.
- **Pass.** Setting the broadcast to Low latency in YouTube would cut this
  further.

## 3. Score lead

Six score changes were measured on a 150 s recording of YouTube's 1080p HLS.
The scorebug changes on a single frame. Lead is the time the worker first
fetched the new score minus the burned clock on the first frame showing it:

| Revision | Worker fetched (UTC) | First new-score frame | Lead   | Lead from the 20 s boundary |
| -------- | -------------------- | --------------------- | ------ | --------------------------- |
| 23       | 18:14:37.295         | 18:14:36.100          | 1.20 s | 1.11 s                      |
| 24       | 18:14:57.518         | 18:14:56.333          | 1.19 s | 0.88 s                      |
| 25       | 18:15:17.420         | 18:15:16.300          | 1.12 s | 0.91 s                      |
| 26       | 18:15:37.354         | 18:15:36.166          | 1.19 s | 1.05 s                      |
| 27       | 18:15:57.618         | 18:15:56.500          | 1.12 s | 0.71 s                      |
| 28       | 18:16:17.432         | 18:16:16.333          | 1.10 s | 0.88 s                      |

- **Marginal fail** on the plan's definition: 1.10–1.20 s, against a ±1 s
  bar.
- **The other column** measures from the score's 20 s boundary, which
  includes the worker's 0.5 s poll and is a closer stand-in for a tap. On
  that measure the lead is 0.71–1.11 s.
- **The cause** is the intake delay: Stream's SRT in and out, plus the
  worker's input buffer, hold video about 1.1 s that the score doesn't wait
  for.
- **Remedy, from the spec:** the worker delays applying score changes by
  about 1.1 s. That's one constant in the worker, and the phone doesn't
  change.

## 4. Feed drops

The source was killed and restarted while the container kept running.
YouTube was checked with `yt-dlp` every 18 s during the gaps, and the viewer
was watched in Chrome.

| Gap              | Broadcast and link                  | Container  | Worker output back after the feed returned | Fresh frames on YouTube |
| ---------------- | ----------------------------------- | ---------- | ------------------------------------------ | ----------------------- |
| 3 s (incidental) | same                                | no restart | ~36 s                                      | n/a                     |
| 10 s             | same video ID, `is_live` throughout | no restart | 28.4 s                                     | +41 s (7 s poll)        |
| 60 s             | same, `is_live` throughout          | no restart | 22.2 s                                     | +33 s                   |
| 5 min            | same, `is_live` throughout          | no restart | 21.6 s                                     | +25 s                   |

- **What viewers see:** the last frame frozen under YouTube's buffering
  spinner (player state 3). `live_latency_secs` grows by the length of the
  gap: 37 to 67 s in the 60 s drop, 123 s two minutes into the 5-minute drop.
- **Recovery needs no reload.** When frames return, the player starts on its
  own, jumps back to the live edge, and plays at about 13 s glass to glass.
  With auto-stop off, YouTube didn't end the broadcast even after 5 minutes.
- **Pass.** The same broadcast and link resumed all three times. Nothing in
  this test needs the "hold the last frame or a slate" behavior in the spec.
  YouTube holds the last frame itself.
- **Recovery is slow, and the worker's retry logic is why.** When the feed
  stops, FFmpeg's SRT read from Stream doesn't end. The worker kills it after
  its 10 s `output_timeout` and starts again.
    - Each new attempt needs about 9–9.5 s to produce output through Stream:
      the SRT connect, FFmpeg probing, and waiting for a keyframe. That's just
      under the 10 s timeout, so an attempt that spawns a moment too early
      times out.
    - The attempt after a timeout sometimes exits with code 251.
    - After 3 attempts in 60 s, the retry budget waits for the window to
      roll over.
    - Net effect: 22–36 s from the feed returning to output again, whatever
      the gap.
- **Port fixes** (not tested here):
    - lower the input `-probesize`/`-analyzeduration` for the known SRT
      input;
    - raise `output_timeout` to about 15–20 s for the Stream source, or
      reset it when bytes arrive;
    - make the retry budget looser for a source that's gone than for a
      crash.
- **Early start:** the container was started 51 s before the source. Attempts
  1–3 timed out, the retry budget held, and output started 21 s after the
  feed arrived, with no container restart.

## 5. Cold start

Each run went from `/stop` (container destroyed, live input deleted) to
`/start` (new live input, container start), with `send.sh` started at the
same moment:

| Run | `/start` returned | Worker registered | Worker output | Fresh frame at YouTube's edge |
| --- | ----------------- | ----------------- | ------------- | ----------------------------- |
| 1   | 1.19 s            | 2.4 s             | 12.5 s        | 16.8 s                        |
| 2   | 1.22 s            | 2.2 s             | 12.4 s        | 16.7 s                        |
| 3   | 1.43 s            | 2.4 s             | 12.4 s        | 16.5 s                        |

- **Pass,** and there's no reason to start the container when the film screen
  opens.
- **Where the time goes:**
    - the container boots and the worker registers in about 2.3 s;
    - creating the live input takes about 1 s of the `/start` call;
    - most of the rest is the same ~9 s FFmpeg startup through Stream;
    - YouTube's 5 s segments add about 4 s at the edge.
- **Image pull wasn't a factor.** The first container start after the
  deploy also had the worker running within 1 s of `/start`.

## 6. Cost

**Usage:** about 55 container-minutes on 2026-11-16 (18:07–19:02 UTC), all on
`standard-4`. Check the billing pages on 2026-11-17 for the actual vCPU-s,
GiB-s, egress and Stream minutes. They aren't available until the next day.

Estimate per streaming hour at list price, before the Workers Paid plan's
included usage:

| Item                             | Basis                                                    | $/hour     |
| -------------------------------- | -------------------------------------------------------- | ---------- |
| Container CPU (active only)      | 31% of 4 vCPU = 1.24 vCPU × 3600 s × $0.00002            | 0.089      |
| Container memory (provisioned)   | 12 GiB × 3600 s × $0.0000025                             | 0.108      |
| Container disk (provisioned)     | 20 GB × 3600 s × $0.00000007                             | 0.005      |
| Egress to YouTube                | ~6.3 Mbps ≈ 2.8 GB × $0.025 (NA/EU; 1 TB/month included) | 0.071      |
| Stream delivery to the container | 60 min × $1/1,000 min                                    | 0.060      |
| **Total**                        |                                                          | **≈ 0.33** |

- **Memory is the largest item,** and the worker used about 0.8 GiB of 12.
- **A custom instance** passed to `ctx.container.start()`, around 4 vCPU and
  4 GiB, would bring the hour to about $0.26. Check it against the
  custom-instance limits first.
- **Fixed costs:** Stream's $5/month plan and Workers Paid at $5/month.

## Recommendation

1. **Build option 2** at 1080p30 on `standard-4`, with Stream as intake.
   Don't fall back to option 1 or 3.
2. **Pull Stream's SRT playback** URL in the container, not RTMPS, and
   update the spec. The worker's SRT reader then works unchanged.
3. **Delay score changes by about 1.1 s** in the worker, as the spec
   anticipates.
4. **Don't start the container early.** Start it at Go Live: cold start is
   about 17 s.
5. **Port tuning for the worker against Stream:**
    - faster input probing;
    - a longer or byte-aware output timeout;
    - a gentler retry budget while the source is absent.

    This takes recovery after a phone drop from 22–36 s down toward the
    ~10 s a fresh start takes. Skip the slate: YouTube holds the last frame,
    and the broadcast and link survive a 5-minute gap with auto-stop off.

6. **Set new broadcasts to Low latency** in YouTube when the Worker creates
   them, to cut the ~21 s glass to glass.
7. **Consider a custom instance** with less memory to cut about 20% of the
   hourly cost.

## Teardown

- **Stream:** live inputs deleted, and the API lists 0.
- **Worker and container:** the `scorebug-spike` Worker is deleted. Its
  container application `scorebug-spike-spikematch`, which survives a Worker
  delete, was deleted separately.
- **Source:** `send.sh` is stopped.
- **Left in place:** the unlisted YouTube test broadcast (`_bMXv6lYW-g`),
  which has auto-stop off. End or delete it in YouTube Studio when it's no
  longer needed.
