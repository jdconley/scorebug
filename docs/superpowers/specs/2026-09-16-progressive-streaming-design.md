# Progressive sender adaptation

## Requirement and current status

The September 16 owner clarification is authoritative: bring live audio/video online
at the lowest qualified quality without an initial bandwidth test, improve quality
as conditions permit, reset to the lowest live profile when sustained excessive
frame loss occurs, then recover gradually. Keep the independent clean local archive
running through every live quality change and outage. Target 30 fresh fps; protect
the 24 fps floor. Native phone/watch scoring and portable workers remain unchanged.

The industry umbrella term is adaptive bitrate streaming (ABR); this project needs
sender-side bitrate/resolution adaptation and congestion control on the upload.
Viewer ABR selects among downloadable renditions. Here the camera produces one live
uplink and must change its encoder under network, thermal and worker constraints.
"Immediate" means no deliberate preflight probe or quality ramp before publishing;
connection, worker and first-keyframe latency still exist and must be measured.

This is a design amendment, not a claim that automatic adaptation currently works.
At commit `5853b45`, native video cost is measured and fixed540 pressure passes, but
production upgrades are disabled. The experimental quality driver starts at 1080p;
its two-profile ladder is 540p/1080p. Existing policy normally lowers bitrate by 20%
before descending one profile, waits 30 healthy seconds before an increase, and
rolls failed trials back to their preceding baseline. These do not fully satisfy
low startup or mandatory lowest-profile reset. The previous actual adaptive trial
also failed media continuity; enabling it is not an acceptable shortcut.

## Established behavior to reuse

Use an OBS-style dynamic bitrate supervisor above the existing SRT transport:
respond to growing queues before frame loss, lower load promptly, and recover in
small increments with a hold between increases. OBS's implementation uses a 200 ms
queued-video trigger, 1–2 second rate estimates and four-second increase intervals.
Its increase is one tenth of the original configured rate and its initial rate is
the original rate. Low startup and reset-to-lowest are additional Scorebug product
rules, not claims about OBS. Read on September 16, 2026:
[OBS guidance](https://obsproject.com/kb/stream-connection-troubleshooting) and
[RTMP dynamic bitrate implementation](https://raw.githubusercontent.com/obsproject/obs-studio/master/plugins/obs-outputs/rtmp-stream.c).

WebRTC's AIMD rate controller similarly separates increase/hold/decrease, using a
0.85 default decrease factor and adapting its increase to capacity knowledge. This
supports the fast-down/slow-up control pattern, but porting that file alone would
not implement GoogCC: its transport feedback and estimator dependencies matter.
[WebRTC AIMD implementation](https://webrtc.googlesource.com/src/+/main/modules/remote_bitrate_estimator/aimd_rate_control.cc).

[IETF RFC 8836](https://www.rfc-editor.org/rfc/rfc8836.html) calls for prompt reaction
to capacity changes and avoidance of excessive queuing. Its scope is interactive
RTP, not a normative SRT broadcast policy. We reuse those principles without
claiming RFC conformance or a universal acceptable frame-loss percentage.

A published WebRTC quality scaler uses a two-second base checking interval, at
least 60 samples, and a 60% encoder-frame-drop trigger. Its rolling statistics and
rescheduling differ from a two-second delivery window. That trigger is unsuitable
for a broadcast required to stay above 24 fps; do not copy it as a video delivery
loss budget. [Pinned quality-scaler source](https://webrtc.googlesource.com/src/+/a49e33414106101e00443c86e930deab3ab76bf8/modules/video_coding/utility/quality_scaler.cc).

SRT retransmits packets, and its sender-buffer timespan includes unacknowledged
packets. Therefore packet loss is not missing video, and OBS's 200 ms unsent-video
queue threshold must not be applied directly to `msSndBuf`. Retain SRT-specific
recovery-budget/RTT pressure interpretation. [SRT statistics](https://github.com/Haivision/srt/blob/master/docs/API/statistics.md).

Alternatives: switching the media transport to WebRTC would allow reuse of its
integrated congestion controller but expands transport, worker and qualification
scope. Reusing a viewer ABR algorithm would require a different buffering and
rendition model. The OBS-style supervisor is the closest fit for this existing
single-upload SRT pipeline. Implement documented behavior using existing project
owners; do not paste external source into the project as part of this amendment.

## Policy contract

### Startup and the ladder

Start each new publishing connection at the lowest **qualified** profile and rate,
including reconnects and route changes that establish a new connection. Begin local
recording independently; publishing setup and probes cannot delay archive capture.
Do not begin at a high profile and call its subsequent downshift "low startup."
Actual first compressed dimensions, configuration identity and receiver output must
prove the initial profile before policy records it as applied.

Qualify 240p30 (426×240) and 360p30 (640×360) as low-end candidates, followed by
540p30, 720p30 and 1080p30. Exact rates and included profiles come from measured
encoder/media results, not labels. Both dimensions remain even. Add higher profiles
only when device, encoder, relay and destination qualify them. The policy takes an
ordered capability ladder rather than embedding model-specific limits. Every tier
retains audio and a 30 fps target; resolution/bitrate is reduced before frame rate.
If a lower candidate cannot be encoded reliably on a device, exclude it explicitly
and expose the actual minimum rather than silently claiming a lower profile.

### Health, reset and recovery

The following numbers are **initial qualification settings chosen for this product**.
The research supports the control pattern and short measurement timescales, not a
universal 5% loss threshold. Keep them together in a named configuration and report
them in evidence. Change them only with a reproducible comparison of recovery time,
frame continuity, quality oscillation and archive integrity.

| Signal | Initial action |
| --- | --- |
| Growing live queues, exhausted SRT recovery budget, worker or thermal pressure | Cancel probes/increases and reduce live load promptly using existing validated downward-only observations. Do not wait for missing frames. |
| More than 5% expected frames missing or late in a complete two-second source window | Reset directly to the lowest qualified profile at its minimum rate. Exactly 5% is not this trigger. At exactly 30 fps, four missing frames out of 60 trigger it; three do not. |
| Fewer than 24 unique fresh frames per second over a complete one-second window, or a confirmed one-second delivery stall | Reset to lowest without waiting for the two-second percentage window. Exactly 24 meets the floor but does not qualify recovery. |
| At least four seconds of continuous healthy evidence at startup | Permit one qualified next increase; this is an earliest opportunity, not an unconditional timer. |
| A reset after loss or failed increase | Require ten seconds of continuous healthy evidence at the minimum before retrying. Repeated failures back off to 20, 40, then at most 60 seconds. A confirmed successful trial clears the repeated-failure count. |
| Missing, stale or inconsistent measurements | Suspend increases and cancel probes; never manufacture a healthy window. Existing local pressure and a separately owned delivery watchdog still act. |
| Lowest profile remains insufficient | Stay at the minimum and report degraded/reconnecting status; continue the archive. Avoid repeatedly recreating an unchanged encoder. |

Fresh means a unique source frame delivered within the stage's qualified latency
budget, not a duplicated output frame or a late burst of queued frames. Account for
the same missing frame only once in a stage's loss ratio. Use source PTS/sequence and
explicit expected-frame counts, with attempt, revision, publication and worker scope.
A timer without progress must detect stalls even when no new frame arrives to close
a source window. A missing control response alone is unknown delivery, not proof
of a stall. Scope changes or telemetry gaps clear recovery accumulation.

Recover one ladder step at a time, with at least four healthy seconds between
increases and only one native application/trial in flight. Where bitrate controls
are proven effective, start with increments no larger than 10% of the current rate;
this is a conservative adaptation of the published ramp pattern, not OBS's exact
increment formula. Where the encoder ignores bitrate controls, move between qualified
resolution profiles only after measuring the proposed profile's actual cost and
proving headroom. Treat nominal bitrate changes as intent until actual bytes confirm
the response. A resolution step may exceed 10% in cost and needs its own admission.

Maintain existing trial probation and ownership deadlines. A frame-failure reset
has priority over rollback to the preceding higher baseline; once latched it cannot
be cleared by an unrelated healthy sample or failed/expired native application.
An acknowledgment must describe the actual native result. Only a completed reset
starts the recovery hold. During an outage, reconnect at the minimum once possible;
recording does not stop just because streaming cannot maintain its floor.

### Measurement and lifecycle integration

The existing worker decoded-video observation uses five-second windows. It cannot
be divided arithmetically to invent one- or two-second evidence. Add bounded shorter
windows and a progress watchdog through the authenticated scoped reporting path;
retain longer windows for diagnostics. Confirm report transit/freshness permits the
reaction budget. Native captured/encoded observations can protect local resources
before remote reports arrive. Distinguish worker decode, worker encode and destination
delivery; decode cadence alone does not prove what a viewer receives.

The newly measured current-profile H.264 cost is a prerequisite, not candidate cost
or link capacity. Candidate admission must include fresh proposed-profile cost,
startup keyframe, audio, mux/network overhead and margin. Bounded repeated/staged
probe ownership must cancel on pressure, reset, stop, route change and scope change.
Do not use the disproven packet-pair bandwidth gauge or current throughput as spare
capacity. Do not delay first publication while collecting these upgrade measurements.

Keep archive and publishing owners separate. Profile changes must preserve media
clock continuity, include usable codec headers/keyframes, and avoid overlapping
encoders or unbounded pending media. Probe, encoder, transport and fixture owners
must join at teardown. Watch/phone scoring remains independently usable throughout.

## Qualification and delivery sequence

1. Qualify low-resolution profiles with actual compressed dimensions/bytes and
   archive/live media evidence; choose the lowest supported profile per capability.
2. Establish short-window loss/cadence and progress-watchdog evidence. Deterministic
   boundary tests must distinguish 3/60 from 4/60 loss, 24 from 23 fps, isolated
   blips, late delivery, duplicates, missing reports and a no-new-frame stall.
3. Extend `QualityController` for direct minimum reset, healthy holds, bounded retry
   backoff and reset precedence over an active trial. Keep attempt/revision/time
   admission and native acknowledgments. Exercise failed/expired/reentrant changes.
4. Wire true minimum-profile startup before the first live encoder sample in
   `CaptureStreamingModel`/`SRTPublisher`; bootstrap `PublishingQualitySession` from
   actual dimensions/session evidence, not just its current bitrate receipt.
5. Finish fresh candidate cost and repeated/staged headroom admission, then enable
   progressive trials behind the native diagnostic gate. Do not activate production
   automatic increases until real transition continuity passes.
6. Run deterministic policy tests, streaming/model suites and iPhone/Watch builds,
   then actual impaired-network fixtures sequentially on this Mac. Compare first
   usable A/V latency against the fixed-low baseline (no preflight delay), ramp
   time, minimum/reset latency, frame loss, repeats, audio alignment and quality
   oscillation. Preserve independent full decodes and intact archive proof.
7. Exercise a clean startup, a brief recoverable burst, gradual capacity loss,
   abrupt collapse, sustained below-minimum capacity, repeated oscillation, full
   disconnect/reconnect, missing receiver reports and thermal/worker pressure.
   Repeat on physical iPhone 14-class/newer hardware with paired-watch scoring;
   then CPU, Mac GPU and home/cloud GPU workers. Simulator results do not qualify
   phone radio, thermal behavior or encoder rate-control support.

The exact implementation plan for each slice follows the established milestone
process. This amendment supersedes earlier startup and loss-recovery assumptions;
previous fixed-profile evidence remains valid only for the behavior it tested.
