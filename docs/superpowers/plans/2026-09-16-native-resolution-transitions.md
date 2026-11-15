# Qualify native encoder resolution transitions

Continue the approved portable streaming plan from the fixed 540p checkpoint.
The production requirement is automatic quality selection with reliable independent
local recording. Before selecting profiles automatically, qualify deliberate
1080p→540p→1080p encoder changes on the same paced structured source.

The current SDK settings setter invalidates the session on size changes and the
next append creates its replacement. Measure this path before deciding between
preserving it, explicitly draining/replacing the encoder, or restarting the whole
publication. Restarting publication adds receiver acquisition gaps; prefer an
in-place transition if its ownership and bounded delivery can be proven.

Add a simulator-only native experiment using the unchanged codec settings path.
Submit 1800 consecutive source frames: 600 each at 1080p/6 Mbps, 540p/1.5 Mbps and
1080p/6 Mbps. Reuse identical pixels per phase while source PTS advances. Pace at
30 fps without catch-up bursts. Retain only bounded scalar metadata. Join all
encoder callbacks to actual delivered compressed samples by exact source PTS.
Require one distinct encoder-session revision per phase, exact dimensions on every
frame, ordered delivery, and a sync frame containing an IDR NAL at each new phase.
Inspect H.264 parameter sets and preserve native property snapshots taken directly
after each phase's first append. Record transition request, append and snapshot
times; they are diagnostic boundaries, not production mutation receipts.

Keep the existing native runner's owned simulator, timeout, cancellation, attachment
selection and joined cleanup. Add a separate strict version-7 verifier and negative
tests for missing/mixed frames, sessions, formats, headers, timestamps and pacing.
Run the complete tool suite and the actual iPhone 14/iOS 17.5 experiment. Preserve
failures; repair native replacement only after deterministic reproduction and
regression tests establish its cause.

This gate does not establish downstream decode continuity, archive independence
during transitions, cancellation under replacement, transport capacity or automatic
adaptation. Those remain next: SDK transition lifetime tests, then the same sequence
through native publishing and worker decoding with a full-resolution local archive,
then scheduled bandwidth pressure/recovery and longer runs. No production profile
selection is enabled by this diagnostic.

## Native results

The first iPhone 14/iOS 17.5 run, `encoder-resolution-transition-JrdbHQ`, passes.
All 1800 frames (0–1799) join exactly and remain in delivery order. Each 600-frame
phase has its own encoder-session revision, every output has the requested actual
dimensions, and all three phase starts have sync/IDR evidence and SPS/PPS types.
Measured settled compressed payload is 6.020→3.521→6.020 Mbps. Source pacing is
30.00005 fps. The reduced phase still exceeds its requested 1.5 Mbps rate; profile
selection cannot treat configured bitrate as achieved payload.

Replacement is not instantaneous. The first append takes 107 ms for the downshift
and 59 ms for the return to 1080p. Consecutive compressed-output delivery has a
349 ms gap at the downshift and 398 ms at the return. Maximum callback completion
lag is 558 ms. These measurements preserve all frames and their source timing, but
do not prove continuously smooth live delivery or decoded playback.

The iOS 26.2 repeat, `encoder-resolution-transition-sABLpY`, also preserves all 1800
frames with the same 6.020→3.521→6.020 Mbps settled payload. Source pacing is
30.00004 fps. Down/up first-append durations are 102/41 ms, delivery gaps 396/419 ms,
and maximum callback completion lag 541 ms. Both runs use unchanged production
codec replacement code. No transport or local archive was part of these runs.

All 910 tooling tests pass. The positive version-7 verifier test first failed against
the prior verifier's unsupported-version assertion, then passed with strict frame,
phase, native property, header and pacing checks. Negative mutations cover missing
and mixed identities, stale dimensions, missing sync/IDR/parameter sets, incorrect
native rate readback, reordered delivery and invalid timing. An independent read-only
review approves the source and the iOS 17.5 interpretation, explicitly retaining
the delivery gaps and the metadata-only scope.

The additive delivery-gap/completion-lag summary fields were added after the first
run and while the second native run was underway; neither native test source nor
existing acceptance checks changed. Both completed raw reports are replayed with
the final verifier into separate summaries, preserving original artifacts.

## Lifecycle gate before enabling profile selection

Do not infer that every outstanding callback is safe from these two paced runs.
Apple documents explicit completion of pending frames separately from session
invalidation in its [compression session workflow](https://developer.apple.com/documentation/videotoolbox/vtcompressionsession-api-collection).
The current codec invalidates its old session during replacement without an
explicit completion call at that boundary. Test outstanding callbacks, stop,
cancellation and failed replacement deterministically before exposing a production
profile-changing operation.

If an explicit drain is required, execute it off the stream actor so the existing
bounded compressed-output consumer can continue. Suspend raw input with a bounded
policy, serialize concurrent changes, and prevent stop or late completion from
reviving an obsolete session. Require observed source/session/profile receipts,
not merely a successful settings write. The integrated experiment must measure
these 0.35–0.42-second output gaps and any ingress loss as well as decode and archive
continuity. These are concrete remaining requirements, not qualified by this probe.

Reproduction: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:encoder-transition`.
Use `SCOREBUG_IOS_RUNTIME=26.2` for the newer-runtime repeat. Runs own a fresh
simulator and join test execution, attachment export, shutdown and deletion.

Final verification: all 910 tooling tests pass again after the additive timing
summaries. The final verifier replays seven retained native reports (versions 2,
3, 4, 6 and 7), covering 12010 previously captured frames, without rerunning or
rewriting the original experiments. Formatting and diff checks pass. The independent
review also approves the completed iOS 26.2 report and both final summaries, with
no blockers. All owned native/test processes are terminal before evidence hashing.
