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
packet timestamps explicitly useN*512ticks at1/15360. PCM audio uses the first600s
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
