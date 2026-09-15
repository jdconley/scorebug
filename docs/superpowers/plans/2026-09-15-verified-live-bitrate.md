# Verified live bitrate application

Continue after the ingress-observation native qualification. Use bounded
implementation with independent specification/quality review; keep one owner for
native/media execution. This is the next diagnostic/control primitive, not approval
to enable automatic adaptation or change resolution.

## Source findings and bounded design

`SRTPublisher.setBitRate` currently reads/modifies the generic SDK settings. The
`VideoCodec.settings` observer calls `VideoCodecSettings.apply`, which discards the
native property-write status and accepts a missing session. In average-rate mode,
`makeOptions` resolves default data-rate limits from bitrate, but `apply` changes
only the bitrate property. A later update can therefore retain the previous native
burst cap. These are source findings, not measured causes of past media failures.

Add a dedicated synchronous throwing update through the SRT actor, outgoing stream
and codec. Preserve initial generic configuration separately. Require the matching
publishing lifecycle, open input, a running compression session, no pending session
invalidation and no publishing/finishing failure before attempting a write. The
codec's `passthrough` flag controls timestamp handling and is true for the current
raw encoder; it cannot identify compressed passthrough. SRT compressed input bypasses
the codec, and must not receive a false update acknowledgment.

Start with the configured average-bitrate mode. Validate the requested rate before
mutation. Share effective data-rate-limit resolution with initial options: default
`[0, 0]` resolves to `[bitRate / 8 * 1.5, 1]`, explicit limits remain explicit and
`nil` remains absent. Check native status on all required writes, then read back
bitrate and applicable limits with strict type/value validation. Commit stored
settings only after verification, without triggering a second unchecked write via
`settings.didSet`.

A preflight rejection leaves a healthy stream running. A failure after an attempted
native mutation leaves applied state uncertain: return a typed error, acknowledge
nothing, and terminate only live publishing through its existing failure latch.
Keeping the old settings value does not prove native rollback. The local archive
must remain independent.

Two boundaries require explicit design before implementation:

- Codec notification selectors currently mutate session invalidation outside the
  SRT actor. Serialize or otherwise synchronize invalidation with the update path;
  an actor method alone does not establish lifecycle safety.
- Native property readback establishes accepted settings, not achieved output rate,
  transport capacity or the exact frame where a change becomes effective. Do not
  assign already queued encoder completions to a new profile revision. Attempt and
  caller ownership must be rechecked across adapter awaits, and policy activation
  still requires a separate transition/source-boundary design.

## Implementation and evidence sequence

1. Specify the synchronous update result/error and invalidation ownership boundary.
   Use a narrow internal session/property fake with native production defaults.
   Add failing tests for absent/decompression sessions, pending invalidation,
   invalid requests, native write/readback errors, malformed or mismatched readback,
   second-property failure and unchanged-request verification.
2. Implement shared limit resolution and verified settings commit. Test default,
   explicit and absent limits against initial options, exactly one commit, and
   terminal uncertainty after any attempted mutation fails. Preserve initial
   configuration behavior and existing encoding/finish tests.
3. Integrate SRT publishing/finishing identity guards and the app adapter. Use the
   existing SRT finish tests and `SRTMediaPublisher.Operations` seam for cancellation,
   overlapping stop and late-success suppression. No controller enablement.
4. After focused/full affected suites and independent review, extend the existing
   small native codec fixture: create an encoder, verify changed properties, continue
   encoding and drain. Check real output continuity separately from configuration
   acceptance. Run Apple builds for simulator and device configurations. A further
   long native workflow needs a concrete unresolved concern; do not repeat it merely
   because the setter has a new isolated test.

A bounded read-only source review agrees with this direction and identified the
notification-invalidation and profile-boundary limitations above. No implementation,
native property-application proof or runtime adaptation is claimed by this plan.
