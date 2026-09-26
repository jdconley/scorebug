# Continuous delivery control — September 25

## Starting point

Checkout `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`, starts at8be29c6. Previous goal turn made progress: reviewed instantaneous SRT sampling27a502d, fresh native9IVqF0 shows four quality phases and continuous video but still a21ms live audio gap. The32MiB delivery audit exhausts at374healthy rows, leaving20.4s uncovered. All prior processes/reviews are terminal.

## Current work

Implement [continuous delivery control](../superpowers/plans/2026-09-25-continuous-delivery-control.md), preserving bounded complete audit semantics. The user has authorized autonomous work toward the full vertical; no new product decision is required for separating runtime control from laboratory retention. In parallel, inspect retained evidence to explain byte usage and preserve the audio failure; do not rerun an unchanged native scenario.

## Evidence storage diagnosis

Artifact-only `diagnose-delivery-audit-storage-20260925.py`, process60336 joinedexit0, measures the original9IVqF0 audit (SHA25695d19eb687916f97b9633090dc0a3f05a00a5b67dc200dd3261049d5a2163640). Original33,525,136bytes/374rows; canonical representation33,406,534bytes. Field payloads: history24,783,306bytes,timeline5,572,051bytes,frames2,134,415bytes.

An exact-value interning experiment stores each capture frame, encoded frame and receiver timeline once, with per-row references; it produces11,389,537bytes. Dictionaries have7901capture/7849encoded/250timeline entries. Full reconstructed value equality with the original audit is asserted. Summary saved as `native-app-9IVqF0/delivery-storage-diagnosis.json`; original bytes unchanged. This is a storage experiment only: overflow remains true and zero missing rows are recovered. A runtime schema change would need strict bounded references/expansion, transactional retention and compatibility tests before a fresh native run.

## Residual audio boundary

Independent read-only diagnosis saved `native-app-9IVqF0/audio-boundary-packet-hash-diagnosis.json` with input hashes, ffprobe commands and gap neighborhoods. All12,726AAC packet payloads are byte-identical and ordered identically in direct and overlay files. Both jump at packet4928(zero based):114.449274soverlay,114.449002sdirect. Excess intervals21.337/21.065ms differ by expected FLV millisecond quantization. This localizes the discontinuity to the common worker output before the tee; the mock RTMP recorder did not independently lose a packet.

The21.333ms size matches one1024sample48kHz native AAC frame, an inference rather than proven source location. Worker transcodes48k input to44.1k output. Retained native audio/mux timestamps cover8startup packets plus aggregate counts; the compressed-audio observer is post successful mux admission, not an independent pre-mux boundary. Worker packet timing was not enabled and its present collector retains only128startup packets per lane.

Smallest useful next trace: full-run scalar continuity counters and bounded first-discontinuity neighborhoods at native post-mux audio and worker demux/mux boundaries, including durations, previous/current PTS, ordinal and explicit completeness/overflow. If demux is continuous while mux jumps, inspect decoded audio PTS/sample counts to distinguish decoder from resampler/encoder. No identical native rerun or runtime audio change was made.

## Implementation verification in progress

Shared classifier/Continuous consumer and explicit driver selection implemented with advancing source/receiver fixtures. Initial regression used the audited baseline and failed after the cap. A600poll soak produces roughly900fresh positive windows;300ownership changes retain only current ownership plus2schedule cursors. A driver regression injects negative delivery after600polls and verifies the actual reset to minimum.

Current-authority retention addresses address reuse: Key now retains only its current authority and compares object identity; replacement releases the previous reference. The red lifetime test failed against ObjectIdentifier-only storage. Mixed healthy/invalid batches signal unavailability before results reach driver recovery processing.

Focused suite89tests passes; first full FilmModel suite630tests passes. Generic simulator build failed on x86_64 linking missing SRT symbols; the established arm64-only configuration builds successfully. Both logs retained. This is not an Intel simulator qualification.

Self-review tightened cancel compatibility: continuous feedback closes synchronously, while audit closure stays at the original joined stop boundary. The blocked-live-drain audit test reproduced2early-close failures before correction; final focused89tests pass. Final full-suite rerun passes630tests/0failures in176.067s and is joined. Runtime commit60fb8bb contains4code/test files; independent specification review approves without findings and independently passes89tests (log copied to artifacts/qa/continuous-delivery-agent/spec-review.log). Independent quality review also approves without findings after inspecting all4files, relevant authority/session code and the630test log; diff checking passes. Both reviews are closed. No production factory/timing/threshold changes or native replay are included in this slice.

A further read-only guard observation: recovery-budget-v1 independently allows RTT≤delay/4 and sender-buffer duration≤delay/2. In9IVqF0 the last retained pressure of failed owners is404msbuffer/237.445msRTT and309ms/246.973ms at1000msdelay. A hypothetical buffer+4×RTT budget is1353.78/1296.892ms. This is an engineering hypothesis, not a transport timing proof: msSndBuf includes unacknowledged traffic, so simply summing may double-count delay. No threshold or policy changed. Prefer bounded next-candidate probes and actual boundary evidence over an unexplained timing increase.

## Outcome and next step

Continuous delivery-control slice60fb8bb is complete and reviewed. It is reachable through explicit driver consumer construction, with the ordinary fixture path unchanged. Production phone adaptation remains disabled. All tests/builds and reviewers are terminal; no root process is live.

Next prioritize the runtime path: promote owned candidate types and construction out of debug fixtures, replace lifetime16attempt exhaustion with bounded one-owner/cooldown lifecycle, define next-candidate probe and network-cost configuration, then wire ordinary camera capture to the existing controller. Keep residual audio tracing, lossless complete audit retention and full recovery/paired acceptance as explicit gates. Do not spend another identical long replay merely confirming known failures.
