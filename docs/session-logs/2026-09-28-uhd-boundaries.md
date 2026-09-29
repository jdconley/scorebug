# UHD boundary diagnosis — September 28

Starting edb4b94, clean worktree. Previous turn completed isolated publishing-hop
blackhole/restoration evidence. Sustained4K remains the first performance gap.

## Investigation and change

Retained gZctuL proves actual4K receiver geometry and pre-receiver loss but its
compact policy diagnostics omit the boundary counters needed to localize drops.
The SDK already counts raw queue evictions, exposed internally only; the app also
has live ingress accounting and a native encoder-submission callback.

Expose the existing SDK counter read-only and include it only when a health observer
is installed. Optional headless UHD observers collect scalar submission count,
errors/duration and SDK drop count; normal app construction installs none. Headless
samples also save existing ingress admitted/dequeued/evicted/rejected counts and
retained capture/encoded counts with omission counts and local timestamps. Observers
retain no media and make no quality decisions. No queue/timing/profile changes.

Incremental FilmModel build-for-testing passes (build.log in uhd-boundaries-20260928).
No unit suite or hardware run. Code review confirms instrumentation is opt-in and
all local stages remain separate rather than being presented as receiver delivery.

## Completed checkpoint

Capture headless-native-nm6xCH, labPRuCD0, exec82440 joined0, cleanup[].300s configured,
302s through finalization; recording/publishing remain active at capture end.
360/720/1080confirm;4Ktrial starts256s and rolls back271s with captured147 versus
encoded/received145. This reproduces the real failure with new boundary evidence.

App ingress: zero video evictions and rejections throughout. SDK raw-input drops:
0 before UHD,2 at269.2s,4 at271.2s,7 after fallback at271.7s. Native submissions
return no error, but maximum call duration rises from<5ms before UHD to24.6ms at
admission, then34.9/44.0/68.3/90.8ms while UHD continues. The pre-encoder SDK queue
is the demonstrated dropping boundary. Slow native submissions precede the drops;
shared-host contention versus intrinsic encoder throughput is still unproven.

Receiver geometry independently confirms 444 actual3840×2160frames with a
9000/90000 maximum timestamp step. No sustained4K or full-media pass claimed.
No redundant export/decode, queue enlargement or quality-threshold change. Source
observation windows were evicted normally: retained callback totals are not cumulative
counts and are not subtracted across those boundaries. Health/app/submission samples
are sequential rather than atomic; provenance remains in native-boundaries.json.

Evidence: boundary-analysis.json, native-boundaries.json, diagnostic.json and
implementation.patch/json in the headless artifact; worker.log and shutdown.json
in the lab. All jobs joined. Next diagnosis should isolate encoder/host load with a
short native path, not repeat the unchanged five-minute adaptive run. The Mac is an
Apple M4 Max; the lab concurrently decodes, records, publishes and transcodes4K.

## Independent retention reconciliation

While capture runs, inspected current PublishingDeliveryMonitor and six corresponding
current test methods against exact passing lines in the retained FilmModel log.
Audited/continuous selection is explicit; finite row/byte/serialization failure is
terminal and cannot return health for unretained rows. Production continuous mode
retains no proof rows and survives beyond audit caps. Saved source/log hashes and
case list in uhd-boundaries-20260928/audit-reconciliation.json. Closed this plan TODO
without another suite; audio/media and sustained-profile gates remain open.
