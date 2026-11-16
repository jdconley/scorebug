# Stream + Container Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove or disprove the media path the hosted design depends on:
SRT into a Cloudflare Stream live input, a Cloudflare Container that pulls the
feed and burns in the score with today's worker, and RTMPS out to YouTube. Do
this before any porting starts.

**Architecture:**

- **Control:** a throwaway Worker and Durable Object start and stop one
  Stream live input and one container.
- **Container:** it runs the unchanged `apps/home-daemon` image.
- **Fake control plane:** the Durable Object plays the control plane on
  `http://api.internal`, through the container's outbound handler. It serves
  the worker's assignment and connection, and a score that advances on a fixed
  clock.
- **Source:** FFmpeg on a Mac stands in for the phone and burns a wall clock
  into the video, so latency and score lead can be read off YouTube frames.

**Tech Stack:** Wrangler 4, Workers + Durable Objects + Containers
(`durable_object` scheduling policy), Cloudflare Stream API, FFmpeg 7 with
libsrt, the existing `apps/home-daemon` Dockerfile.

**Spec:** `docs/superpowers/specs/2026-11-16-hosted-cloudflare-design.md`
(section "Phase 0: spike before building").

This is a spike: throwaway code, no unit tests. It lives on branch
`spike/stream-container` and is never merged. Only the results document is
merged.

## Global Constraints

- Container instance type: `standard-4` (4 vCPU, 12 GiB).
- Video profile: `1080p30` first, then `720p30` only if 1080p30 fails
  measure 1.
- Encoder: `ENCODER=software` (x264 `veryfast`, `zerolatency`, as
  `apps/home-daemon/src/pipeline.ts` already sets).
- Stream live input: recording mode `off`. One input for the spike, deleted
  at the end.
- YouTube broadcast: unlisted, created by hand in YouTube Studio.
- Secrets are entered by JD with `wrangler secret put`. They never go in chat,
  files or commits.
- Pass bars, copied from the spec:
    - CPU sustained below 80% with no dropped frames for 30 minutes;
    - latency under 30 s glass to glass;
    - score lead within 1 s;
    - the broadcast and its link survive feed drops of 10 s, 60 s and 5 min;
    - cold start under 30 s. Between 30 and 90 s means starting the container
      early. Over 90 s is a failure.

## Review Focus

- **The pull starts before Stream has video.** The container is started at
  Go Live, possibly before the first SRT packet. The worker must keep
  retrying the RTMPS pull rather than exit. Task 3, step 4 checks this.
- **Stream playback URL shape.** Stream's RTMPS playback URL and key come
  back in the live input's `rtmpsPlayback` field, which isn't where its SRT
  publish URL is. A wrong field means the worker reads nothing. Task 2,
  step 3 logs both.
- **Outbound handler vs RTMPS.** Catch-all interception breaks raw-TLS
  RTMPS, which Streamline documents. Only `api.internal` may be intercepted.
  Task 2, step 2 pins this.
- **The 5-minute drop.** Stream may end the live input's video session, and
  YouTube may end a broadcast with auto-stop. The test broadcast must have
  auto-stop off, matching the design. Task 4, step 3 pins this.
- **Inactivity timeout while live.** The container must not be put to sleep
  mid-stream when no HTTP requests reach the Durable Object. Task 2, step 2
  sets the timeout to the 4-hour cap.

---

### Task 1: JD prerequisites

**Files:** none.

- [ ] **Step 1: JD subscribes to Cloudflare Stream**
      JD turns on the Stream plan (about $5/month) in the dashboard under Stream,
      on the account that already runs Containers. Claude doesn't buy it.

- [ ] **Step 2: JD creates a Stream API token**
      Dashboard → My Profile → API Tokens → Create, with permission
      `Account · Stream · Edit` for that account only.

- [ ] **Step 3: JD creates an unlisted YouTube test stream**
      In YouTube Studio → Create → Go live → Stream, set Visibility to
      Unlisted, turn **Auto-stop off** and **Auto-start on**, and note the
      RTMPS server URL and stream key. The channel must already have live
      streaming enabled.

### Task 2: Spike Worker, Durable Object and container

**Files:**

- Create: `spikes/stream-container/wrangler.jsonc`
- Create: `spikes/stream-container/package.json`
- Create: `spikes/stream-container/src/index.ts`
- Create: `spikes/stream-container/src/fake-control-plane.ts`
- Create: `spikes/stream-container/README.md`

**Interfaces:**

- Produces Worker routes (all require header `x-spike-key: <SPIKE_KEY>`):
    - `POST /start {profile: '1080p30'|'720p30'}` →
      `{srtPublishUrl, rtmpsPlaybackUrl, startedAt}`;
    - `POST /stop` → `{stoppedAt}`;
    - `GET /status` → `{container: 'running'|'stopped', lastWorkerStatus, scoreChanges: {revision, at}[]}`.
- Container env (exact names from `apps/home-daemon/src/config.ts`):
    - `CONTROL_PLANE_URL=http://api.internal/`;
    - `HOME_TOKEN=<random 32 chars per start>`;
    - `WORKER_ID=spike`, `OUTPUT_ID=spike`;
    - `ENCODER=software`;
    - `VIDEO_PROFILE=<profile>`;
    - `LOG_LEVEL=info`.
- The fake control plane answers the exact endpoints `WorkerClient` calls:
    - `GET /v1/worker/snapshot`;
    - `GET /v1/worker/connection`;
    - the status report `POST` that `apps/home-daemon/src/worker-reporter.ts`
      sends.

    Response shapes are copied from the fixtures in
    `apps/home-daemon/test/worker-client.test.ts` and
    `apps/home-daemon/test/worker-reporter.test.ts`, with:
    - `connection.readUrl` set to the Stream RTMPS playback URL (the `url`
      plus `streamKey` of `rtmpsPlayback`);
    - `source.ready: true`;
    - `output.publishUrl` set to the `YOUTUBE_RTMPS_URL` secret;
    - `broadcast.desired: 'running'` and `generation: 1`.

- [ ] **Step 1: Write `wrangler.jsonc`**
    - **Worker:** name `scorebug-spike`, with a `compatibility_date` of today.
    - **Container:** class `SpikeMatch` with `scheduling_policy: "durable_object"`.
      Its image is built from `../../apps/home-daemon/Dockerfile` with
      `image_build_context: "../.."`.
    - **Durable Object:** binding `SPIKE` → `SpikeMatch`, SQLite storage.
    - **Variable:** `CF_ACCOUNT_ID`.
    - **Secrets:** `CF_STREAM_TOKEN`, `YOUTUBE_RTMPS_URL`, `SPIKE_KEY`.

- [ ] **Step 2: Implement `SpikeMatch` (Durable Object) in `src/index.ts`**
    - **Start:** `ctx.container.start({ image: ctx.container.images.base, instance: 'standard-4', enableInternet: true, env })`.
    - **Outbound handler:** before `start`, register exactly one
      `ctx.container.interceptOutboundHttp('api.internal', ctx.exports.FakeControlPlane)`.
      No catch-all handler and no `allowedHosts`, so RTMPS in and out go
      direct.
    - **Timeout:** right after `start`, set
      `ctx.container.setInactivityTimeout(4 * 60 * 60 * 1000)`.
    - **Stop:** `ctx.container.destroy()`, then delete the Stream live input.
    - **Fake control plane:** `FakeControlPlane` is a `WorkerEntrypoint` that
      calls back into the Durable Object over RPC. It keeps
      `revision = 1 + floor((now - startedAt) / 20_000)` and awards the next
      point to alternating teams, so the score changes on every 20-second
      boundary after start. It records each `{revision, at}` it first serves.

- [ ] **Step 3: Implement the Stream calls in `src/index.ts`**
    - **Create:** `POST https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/stream/live_inputs`
      with body `{"meta":{"name":"scorebug-spike"},"recording":{"mode":"off"}}`.
    - **Use:** keep the response's `srt` (url, streamId, passphrase) and
      `rtmpsPlayback` (url, streamKey). Log both field sets with keys masked
      to their last 4 characters.
    - **Delete:** `DELETE .../stream/live_inputs/{uid}`.

- [ ] **Step 4: Deploy**
      JD runs these himself:

    ```bash
    cd spikes/stream-container && pnpm install && wrangler deploy
    wrangler secret put CF_STREAM_TOKEN
    wrangler secret put YOUTUBE_RTMPS_URL
    wrangler secret put SPIKE_KEY
    ```

    Expected: the deploy prints the `scorebug-spike` workers.dev URL, and the
    container image build succeeds.

- [ ] **Step 5: Commit on the spike branch**
    ```bash
    git checkout -b spike/stream-container
    git add spikes/stream-container
    git commit -m "spike: Stream intake + container worker"
    ```

### Task 3: Source and first light

**Files:**

- Create: `spikes/stream-container/send.sh`

**Interfaces:**

- `send.sh <srtPublishUrl> [seconds]` streams a 1920×1080 30 fps test
  pattern at 6 Mbps H.264 (GOP 60) with AAC audio. A wall clock with
  milliseconds is burned in at the top left
  (`drawtext=text='%{localtime\:%T}.%{eif\:mod(t*1000\,1000)\:d\:3}'`).
  It sends to the SRT URL as MPEG-TS and runs until killed, or for
  `seconds`.

- [ ] **Step 1: Write `send.sh`** using `ffmpeg -re -f lavfi -i testsrc2=size=1920x1080:rate=30`
      and `-f lavfi -i sine=frequency=440`, `-c:v libx264 -preset veryfast -b:v 6M -g 60 -c:a aac`,
      `-f mpegts "<srtPublishUrl>"`.

- [ ] **Step 2: Start**
      Run `curl -s -XPOST -H "x-spike-key: $SPIKE_KEY" $SPIKE/start -d '{"profile":"1080p30"}'`.
      Expected: JSON with `srtPublishUrl` and `rtmpsPlaybackUrl`. Note
      `startedAt`.

- [ ] **Step 3: Send**
      Run `./send.sh "<srtPublishUrl>"`.
      Expected: within about 30 s, YouTube Studio shows "Receiving" and then
      live video with the scorebug, and the score advances every 20 s.

- [ ] **Step 4: Check the early pull**
      Repeat steps 2–3 with `send.sh` started 45 s after `/start`.
      Expected: the worker keeps retrying (visible in `wrangler tail`) and goes
      live once the feed exists, with no restart of the container.

### Task 4: Measurements

**Files:**

- Create: `docs/superpowers/specs/2026-11-16-stream-container-spike-results.md`

- [ ] **Step 1: CPU (measure 1)**
      Run 30 minutes at `1080p30`.
    - Record container CPU from the dashboard's Containers metrics.
    - Record the FFmpeg `speed=` and dropped-frame counts from
      `wrangler tail`, or from `wrangler containers ssh` and `top` if the
      image allows it.
    - Pass: below 80% sustained, `speed` ≥ 1.0, and 0 dropped frames after
      warm-up.
    - If it fails, repeat at `720p30`.

- [ ] **Step 2: Latency and score lead (measures 2 and 3)**
    - **Latency:** take 5 screenshots of the YouTube player next to a
      `time.is` window. Latency is wall clock minus burned clock.
    - **Score lead:** for each of 5 score changes, step through the YouTube
      DVR to the first frame showing the new score. Lead is that change's
      server time (from `GET /status` `scoreChanges[].at`) minus the burned
      clock in that frame.
    - Pass: latency < 30 s, and lead within ±1 s.

- [ ] **Step 3: Feed drops (measure 4)**
      Stop `send.sh` for 10 s, 60 s and 5 min, restarting after each.
    - Record what YouTube shows during the gap, whether the same watch URL
      resumes, and whether the worker reconnects without a container restart.
    - Pass: the same broadcast resumes all three times.

- [ ] **Step 4: Cold start (measure 5)**
      Three times, from `/stop`: call `/start` and run `send.sh` immediately.
      Record seconds until the first frame plays in YouTube's preview.
    - Pass: < 30 s.
    - 30–90 s: record "start the container when the film screen opens".
    - Over 90 s: fail.

- [ ] **Step 5: Costs (measure 6)**
      The day after, record the Containers (vCPU-s, GiB-s, egress) and Stream
      (minutes delivered) usage from the billing pages for the spike runs, and
      work out $/hour.

- [ ] **Step 6: Write the results doc**
      One section per measure:
    - the numbers;
    - pass or fail against the bar;
    - the recommendation: proceed with option 2 at 1080p or 720p, start the
      container early or not, or go back to JD with option 1 or 3.

- [ ] **Step 7: Tear down and merge the results**

    ```bash
    curl -s -XPOST -H "x-spike-key: $SPIKE_KEY" $SPIKE/stop
    wrangler delete --name scorebug-spike
    ```

    Expected: no Stream live inputs are left in the dashboard, and no
    container is running.

    Then commit the results doc on a branch from `main`, open a PR, and merge
    it when green.
