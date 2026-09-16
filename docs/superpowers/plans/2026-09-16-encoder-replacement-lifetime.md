# Explicit encoder replacement lifetime

Implement the next gate from the resolution-transition experiment. The existing
paced runs preserve frames but do not prove pending callbacks are completed before
invalidation, or that stop/cancellation prevents stale replacement commits.

Introduce a codec-owned prepare/drain/commit operation. Prepare captures the exact
active session and revision without changing its settings. One immutable handle
owns a once-only completion operation that runs off the stream actor; it does not
finish the compressed-output queue. The codec rejects overlapping replacement,
bitrate updates, input or unchecked settings writes while the operation is pending.
Input/settings violations latch a live codec failure instead of silently losing a
frame or allowing ambiguous configuration ownership.

Commit requires the same pending handle, active codec, unchanged revision, healthy
failure latch and completed native drain. Only then invalidate the old encoder and
stage new settings for creation on the next raw frame. Keep source timestamp order
and the existing output queue. A native drain failure is terminal. Stop clears the
pending operation and invalidates the old session; later drain completion or stale
commit cannot mutate a stopped or restarted codec. The stream owner must join the
operation before reuse; native completion has no timeout of its own. A stream-level
deadline and ingress pause policy are separate integration work, not promised by
this internal codec primitive.

Use deterministic fake native sessions to cover drain-before-invalidation, repeated
drain, commit-before-drain, competing changes, input/mutation during drain, native
failure, notification invalidation and stop/restart with a delayed completion.
Run real native compressed-output continuity tests through this new primitive,
including a bounded queue with a concurrent consumer. Add a version-8 paced native
1080p→540p→1080p experiment using explicit drain/commit and retain version 7 as the
legacy comparison. Validate actual per-phase source/session/format ownership and
record drain time separately from first-append time and output-delivery gaps.

Do not enable production adaptation until this primitive is integrated with the
SRT stream's raw-input owner, deadlines, cancellation, profile receipts, worker
decode and independent local archive, then qualified under network pressure.

## Implementation and deterministic checks

`VideoCodec.prepareReplacement` captures the current native session, invalidation
revision, target settings and failure latch. `VideoEncoderReplacement.drain` invokes
native completion once without holding its state lock or closing output. Commit
checks identity, revision, the failure latch and the actual completion result before
invalidating the old session. It stages the next configuration; it does not claim a
new encoder has already applied it. Input, legacy settings writes and terminal
finish during pending replacement fail explicitly. Verified bitrate writes reject
without native mutation. Wrong handles, native drain failures, notifications and
late completion after cancelled stop/restart cannot commit new state.

The first positive lifecycle test failed against the initial API stub, then passed
with the operation implemented. Review found the reverse-order finish race: a
previously captured terminal completion could overlap a new replacement drain.
Both capture-only and already-running terminal completion cases reproduced the
failure. The codec now records terminal completion ownership synchronously and
rejects replacement until a fresh start. All 145 SDK tests pass, including ten new
replacement tests and a real 40-frame, two-format native encoder test through the
same eight-item compressed output queue. The deliberate creation-failure test
retains its expected native-error warning.

The version-8 verifier checks explicit drain intervals and successful native status
in addition to the existing exact frame/session/format/header/pacing checks. Review
also found that ordered delivery alone did not prove old callbacks had completed
before drain returned. An adversarial timestamp mutation reproduced that gap.
The final verifier requires every callback from the preceding phase to complete
by drain return while allowing already-completed queued output to be consumed later.
All 914 tooling tests pass, including both regressions.

## Paced native results

`encoder-drained-transition-MUyCip` passes on iPhone 14/iOS 17.5 Simulator with all
1800 frames, three distinct sessions, actual 1080p→540p→1080p formats and sync/IDR
phase starts. Source pacing is 30.00001 fps and settled payload remains
6.020→3.521→6.020 Mbps. Explicit drains take 88/30 ms; subsequent first appends take
1.5/1.3 ms. All old-session callbacks complete by the respective drain returns.
Output delivery gaps remain 349/417 ms, with maximum callback lag 559 ms. This
moves the completion wait off the codec owner but does not eliminate startup delay.

`encoder-drained-transition-bhgh6h` also passes all 1800 frames on iOS 26.2, at
30.00007 fps and the same settled payload rates. Drains take 89/30 ms, first appends
0.95/1.79 ms, output gaps 348/409 ms, and maximum callback lag 574 ms. The final
verifier replays both raw reports, including the old-callback completion boundary.
The first run began before that stricter assertion was added; its completed raw
report is independently requalified without changing the captured native evidence.

The 55 streaming-package tests and unsigned combined iPhone/Watch Release build
also pass. The final verifier replays nine retained native reports (versions 2,
3, 4, 6, 7 and 8), covering 15610 previously captured frames. Formatting/diff checks
pass. Tests, native runs and builds are sequential and joined before evidence hashes.

## SDK provenance maintenance

The documented SDK patch verification initially failed: the maintained patch had
fallen behind current sources. Reconstruct the baseline offline from the last
patch commit, `5e8e8108fcbe8abed925066c3db2100f66460ae6`, reverse that historical
patch, and verify all 162 unchanged upstream hashes before generating a current
patch. It now covers 18 modified upstream files and seven added source primitives,
including the prior compressed-frame observer and this replacement handle. Preserve
existing patch block order and append new files to keep the review diff focused.
The final reverse/hash/forward/byte-for-byte round trip passes. The verifier now
rejects newly added source files omitted from its provenance inventory.

## Next integration gate

The production app does not yet use this primitive. The SRT raw-input owner must
pause at a known source boundary, keep compressed output/audio consumption alive,
apply a bounded ingress policy, own a deadline and join cancellation/terminal finish
before reuse. New-session creation and actual frame formats must establish profile
receipts; staging settings at commit is insufficient. Then repeat the down/up
sequence through worker decoding while independent local 1080p recording continues,
measuring transition gaps and every missing source frame. Automatic selection,
network recovery, longer soaks and physical phone/Watch/other-host tests remain open.

Reproduction: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:encoder-drained-transition`.
Set `SCOREBUG_IOS_RUNTIME=26.2` for the newer-runtime run.
