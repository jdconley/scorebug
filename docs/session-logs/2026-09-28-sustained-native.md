# Sustained native streaming — September28

Starting17728d0. Prior turn added current worker-crash recovery/tail evidence; all
previous jobs terminal. One longer run now targets the remaining sustained native
software-proxy qualification. No agents, physical hardware, broad suites or repeats.

## Preparation and scoped harness change

Existing headless native harness capped duration600s. Increased only its opt-in
no-finite-audit maximum to1200s, mirrored in the Swift test guard. Audit-enabled
runs stay600s; finite retention and production timing/queues/adaptation are unchanged.
The per-run diagnostic samples remain bounded by duration. Incremental build passes
and the actual new1050s configuration is executing. Syntax/diff checks pass.

Prepared a separate1200s fixture from the existing600s UHD clip; Downloads originals
and the prepared original remain unchanged. H264 has noBframes and is stream-copied;
packet timestamps explicitly useN\*512ticks at1/15360. PCM audio uses the first600s
repeated once, removing the original's20ms extra tail at the loop boundary.
All36,000video packets have exact30fpsPTS/DTS. All57,600,000audio samples have continuous
packet timestamps. A decoded boundary sample is17994…17999,0…5 as expected. SourceIDs
repeat every18,000frames; the verifier checks that exact qualified period, preserving
strict per-frame timestamp and zero-loss checks. No blanket relaxed tolerance.

Prep47289/qualification60768 joined0. Files in
artifacts/qa/sustained-native-20260928; source-qualification.json binds original and
prepared hashes. PreparedSHA768a5abf1829f1437583d11718135b8ab94e536f81d2ab12fc3b7c7105a52702.
Disk was104GiB free before prep. Do not delete original or retained recordings.

## ACTIVE run

headless-native-yFO9Hu, command handle80073. **Still running; rejoin this handle,
do not restart or infer a terminal state from an observation timeout.** Scoped
Xcode26.2, source sustained-native-20260928/input.mov, duration1050, quality2160,
timing-audit off, worker-encoder software. Normal ladder, no shortcuts/faults.
240initial,360trial55s/confirmed76s,720trial140s/confirmed161s observed so far.
This is progress, not sustained/media acceptance. Source-binding.json records
producing revision and exact modified harness/test hashes.

After terminal success, export once using the current already-built bundle:
`python3 artifacts/qa/publisher-blackhole-20260928/export-current.py
artifacts/qa/headless-native-yFO9Hu`.
Then run `verify-media.py <absolute-run>` and `analyze.py <absolute-run>` from
artifacts/qa/sustained-native-20260928. Prepared scripts syntax-check, have not yet
run against this ongoing capture. The media checker uses one fullA/V decode perfile,
sourceIDmod18000, unchanged RTMP millisecond quantization, exact source cadence,
audible gap-free audio and50ms A/V endbound. The analysis additionally requires
normal confirmations through2160/24Mbps, at least600s confirmedUHD and18,000actual
consecutiveUHD receiverframes, zeroSDK/appdrops/submiterrors and continuousarchive.
It must not infer a pass from final selectedquality. Save final hashes/results.

No other process from this session is active. Do not rebuild native code or run
another media workload concurrently with the capture.

## Capture complete; verification active

Capture80073 joined0, cleanup[].1056s through finalization. Confirmed4Kat316s,
receiver22635UHDframes/754.5s; allgeometrysteps3000ticks, no SDK/appdrops or native
submiterrors, hardware selection, maxsubmission32.60ms. Nativeexport succeeded.
Handle88436 now runs all-three-file media verification and finalanalysis; still
pending. Do not repeat capture/export/decodes while this handle is active.

## Final sustained result

Verification88436 joined0; no active jobs. Native export and all-three-file media
analysis succeed without a repeated capture or decode.527archive segment metadata
and payload hashes verified. Archive31,534 consecutive frames (IDs modulo18000 as
qualified); both outputs31,452 identical consecutive frame identities. All files
H264/AAC at3840×2160, full A/V decode succeeds. No video/audio timestamp gaps,
no source-frame identity errors, audible audio. Archive ends22.7ms after video;
proxy32.9ms and mockRTMP34.2ms. Archive continues20frames beyond live.

Actual ingress geometry:240p1614frames,360p2550,720p2400,1080p2253,4K22635.
Every geometry run has exact3000/90000PTSsteps.4K receiver duration754.5s; final
normal4K confirmation holds over600s with24Mbps selected. Native hardware selected,
zeroSDK/appdrops and native submiterrors throughout observed samples. Max native
submission32.60ms. Normal production control, no direct/fixed/warm/frozen shortcuts.

`sustained-acceptance.json` binds final media reports, source/harness/fixture hashes,
receiver log and cleanup. `sustained-media/result.json` retains each file's SHA and
all media metrics. RTMP uses its established1ms timestamp precision; archive/proxy
keep20µs. Qualified looping source IDs remain strict modulo18000, not ignored loss.
Final checker validates>=31500archiveframes and>=18000actualUHDreceiverframes.

This qualifies sustained nativeMac/software-proxy operation only. It does not erase
simulator congestion/UHD limitations, colocatedVideoToolbox contention,107ms crash
audio tail, or physical/otherhost/full-match requirements. UI/Watch/changing-score
results remain their separate retained passes. Main checkout has pre-existing dirty
files and was not merged or altered. Work remains in the authoritative worktree.

Next: remaining backend/platform limits and physical readiness after simulator
functional gates, without repeating completed local media runs. All process handles
joined; no artifacts or recordings deleted.
