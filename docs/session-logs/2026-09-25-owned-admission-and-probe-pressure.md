# Owned admission and probe pressure — September 25

## Starting point

Authoritative checkout `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`, starting `e8e5ece`. The previous goal turn made progress: candidate/recorder reviews closed, and a fresh native replay reproduced media loss with clean recorder shutdown. No live root process or open review carried into this continuation.

## Admission/application implementation

`4a86392` adds whole-original-history owned admission/application correspondence and narrowly extracts shared witness arithmetic. Failed owners remain represented; no legacy envelope, final snapshot or rebased campaign is fabricated. Implementer48new tests pass;414affected tests passed before the final isolated failed-owner guard,48after. Independent specification review passes293tests(48new+245affected) and verifies byte-exact lifecycle provenance; quality review passes407tests(48new+359related). Both approve without findings. Root replays complete original LvDNAy,uE9hUY,iUAsQ6 evidence: each retains4owners/2admissions and explicitly denies media/full recovery authority. Results saved separately as owned-admission-application-replay.json. This closes this slice, not the full recovery or production-enable goal.

## Queue pressure comparison

Read-only comparison of all five retained experiments saved `artifacts/qa/owned-probe-queue-comparison-20260925.json`, with original input hashes. No queue overflow drops occur. During the restricted750kbps phase, maximum forwarded-packet residence is832.60ms(LvDNAy),914.80ms(pzZozK),1412.54ms(D4EhKU),1513.95ms(uE9hUY),1670.71ms(iUAsQ6). The corresponding SRT peer buffers are700/700/1000/1000/1000ms. Residence exceeds those buffers in5/9/19/27/36sparse100msbins respectively. These bins are event observations, not continuous coverage.

The clean LvDNAy case shows that exceeding the buffer in a queue statistic does not by itself prove damaged media. Both clocks remain separate; the diagnostic does not invent an offset or identify specific encrypted packets. Missing decoded IDs in pzZozK include damaged identities, not three proved missing compressed frames.

In iUAsQ6, the third owner's500kbps probe runs142.144–142.963s after native bootstrap, then2Mbps until renewal rejection143.574s. The missing sourceframe4575 was encoded at146.828s, within the independently bracketed restricted period. Proxy peak residence occurs145.865s after its own start. Last successful native recovery observations show RTT rising63.7→234.6ms while reported sender-buffer duration remains61→168ms. This motivates checking the meaning of that buffer measurement before raising timing limits.

## Confirmed statistics semantic mismatch

Both `SRTSocket` production reader defaults call `srt_bstats`. Haivision documents that `msSndBuf` from that API is a moving average; `srt_bistats(..., instantaneous=true)` returns current state. Our native probe guard applies an immediate queue ceiling to that smoothed value. The bundled iOS/macOS headers expose `srt_bistats`; no new dependency is needed. [Official statistics documentation](https://github.com/Haivision/srt/blob/master/docs/API/statistics.md#mssndbuf).

A separate real-SRT loopback experiment demonstrates the difference without changing app code: `artifacts/qa/srt-instantaneous-statistics-20260925/probe.cpp`, compiled10241exit0, run80852exit0. It limits sending to10000bytes/s, queues85packets1316bytes at10ms intervals, and reads both APIs with clear=0. At packet43,current buffer511ms versus average123ms. Maximum current1013ms versus maximum average399ms. All sockets/thread/processes joined; result,stderr,source/binary/library hashes and linked-library provenance retained. This used installed HomebrewSRT1.5.6 on the Mac, not the phone or bundled iOS library. It proves a sampling mismatch, not that this is the sole cause of prior media loss.

Next runtime fix: use instantaneous native queue statistics for pressure checks while preserving clear-counter behavior, sample timestamps, failed-read invalidation and closed/cancelled ownership checks. Add regression coverage at the native API selection boundary, build the bundled target, then repeat the native scenario under unchanged policy thresholds. Do not simply increase the receiver buffer or relabel old evidence.

## Additional primary-source context

Current WebRTC source uses bounded probe clusters and waits for feedback; the inspected configuration has15ms minimum probe duration and100ms initial duration, rather than our staged0.8-second holds. This is evidence to review probe-induced congestion, not a drop-in SRT tuning value or claim about Facebook/YouTube mobile apps. [Probe controller](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/congestion_controller/goog_cc/probe_controller.cc) (blob4589173f128721571eb8cc5acd6cb76d43ca63cd), [bitrate prober](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/pacing/bitrate_prober.cc). The direct statistics mismatch is the smaller, evidenced change to test first.

The controlled statistics experiment also passes against the bundled macOS SRT1.5.4 static archive (same dependency version as the app), with source and binary retained separately: compileexit0,run9506exit0. At packet44,current512ms versus average127ms; maxima985ms/current and380ms/average. `bundled-provenance.json` records the library hash and result. This strengthens the API diagnosis; no phone or media-loss fix is claimed.

Runtime implementation is now assigned to switch the native call boundary to instantaneous sampling, preserve clear flags0(demand)/1(periodic), add selection/failure/cancellation regression tests, and compile/test the bundled target. No buffer/rate thresholds are being changed. Reviews and a fresh native replay must follow.

## Instantaneous statistics correction

Runtime commit `27a502d` switches both socket constructors to one `srt_bistats` reader. Demand reads retain clear=0 and periodic reads retain clear=1; both request instantaneous=1. Timestamp ordering, failed-read invalidation, cached access and closed/cancelled ownership remain unchanged. No policy, buffer or bitrate thresholds change.

The regression first failed with five assertions against averaged readings, then passed:71focused tests,80related recovery/staged/replacement/transport tests, and8final sampling tests. The bundled arm64 iOS simulator app builds successfully. The maintained patch verifies all162upstream hashes and exact round trip. Logs are under `artifacts/qa/srt-instantaneous-statistics-20260925/`. Independent specification review reran8sampling tests and patch verification and approved without findings. Independent quality review also reran8sampling tests and diff checking and approved without findings. Both reviews are closed.

The next launcher is `artifacts/qa/run-owned-reliability3000-peer1000-native-20260925-instantaneous.py 3000`: the same prepared source,3000ms decoder budget,1000ms SRT,750kbps restriction90–150s and270s hold. It uses exclusive new outputs and records its source checkpoint. This replay must establish media behavior independently of the statistics regression; no media-loss fix is claimed yet.

## Fresh native replay after the correction

Launcher ran at reviewed runtime27a502d/documentation116765b. Root11576 joined with the intentional diagnosticexit1, artifact `native-app-9IVqF0`; the UI workflow passed in360.852s and collection errors are empty. This exit is deliberately not an acceptance verdict. Four native phases,556owned events,4owners,2acknowledgements and2failed settlements remain in original history. Recorder code0, no forced termination, eight clean lifecycle events.

Root analysis6549 joined0. Archive9273frames0–9272; both live8827frames229–9055. All three fully decode A/V; no missing or reversed frame identities. Maximum video gaps33.334msarchive/34msdirect/33.334msoverlay. Both live identity arrays match exactly, and the archive continues217frames beyond live. All five timing/native/compressed/profile/capacity-clock leaves pass; the admission/application join passes4owners/2admissions and still denies full-media authority.

The accounted-media leaf rejects `Invalid deadline audit envelope`: delivery-deadlines.json is33,525,136bytes, marks overflow=true at374rows, and reaches its32MiB budget before the512row limit. All374retained windows are healthy with no rejected observations; final encoded media extends20.4096s after the last evaluation. Missing terminal coverage remains a real qualification failure. Do not raise the established lab cap or relabel this run.

`instantaneous-pressure-comparison.json` retains input hashes and original per-owner pressure/retirement observations for iUAsQ6 versus9IVqF0. Failed probes still retire for transportPressure. Current measurements now show larger queue values; the timing of failed attempts differs. This comparison alone is not a causal proof that every media fault is fixed. Recorded audio checks subsequently finished as recorded below.

## Production integration assessment

Independent read-only assessment found a five-slice path using existing capture/scoring architecture:

1. Extract continuous delivery classification from finite Audit retention. Keep current identity, two schedule cursors and current observations bounded; preserve actual missing/stale-evidence invalidation. Ordinary audit256rows and256phases currently stop classification. Driver512event cap only truncates diagnostics.
2. Promote owned lifecycle runtime types; retain fixture export behind DEBUG. Replace lifetime16attempt gate with existing cooldown, exactly one active measurement and joined predecessor. CandidateCampaignOwner already has constant-size ownership.
3. Parameterize next-candidate probe stages: OwnedMeasurementLease currently pads500kbps→2Mbps→12Mbps and assumes stage3. Preserve binding/300msleases and pressure limits. Replace laboratoryIPv4’s fixed44byte/message costing with a documented, validated production framing basis before cellular/IPv6 use.
4. Wire ordinary camera publication through a production factory, compressed AAC observation, guarded mutations, delivery/source freshness and owned measurement. Qualify the existing240p350k→360p600k step first, then extend supported ladder/backend limits.
5. Verify release phone construction, bounded soak beyond512windows/256identity changes/16attempts, stale-owner stop/replacement, camera/thermal/archive integrity and genuine paired-Watch scoring under live stress. Existing simulator pairing failure and separate direct/injected tests do not establish paired success.

No product clarification is needed for these engineering slices. Runtime integration remains disabled pending implementation/verification.

## Final replay verification

A/V analysis54722 joinedexit1. Archive64waveform probes pass. Both live waveform checks reject a21.33ms lag spread. Independent audio timestamp analysis finds one gap near114.449s in each live output:21.065msdirect and21.337msoverlay; no archive gap above3ms. Saved `audio-timestamp-diagnosis.json`. No phase-audio or presentation-time pass is claimed. The instantaneous queue correction does not resolve all live audio loss.

A separate bounded glyph check (`verify-instantaneous-score-glyphs-20260925.mjs`, exit0) verifies score0→1 in both live outputs: all four template matches pass. Results and cropped samples are retained in `independent-score-glyphs/`. This separates successful overlay behavior from the failed audio gate without changing either result.

All root native/analysis processes are joined; specification, quality and read-only production reviewers finished. No hardware was rerun, and no production adaptation is enabled. Next work should address the remaining live audio/probe behavior and complete audit retention, then implement the identified production slices; another identical native replay without a change is not useful.
