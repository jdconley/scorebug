# Native motion and bitrate workload validation

Use brainstorming and writing-plans before implementation, then bounded
subagent-driven implementation with independent specification and quality reviews.
This is the next local workload after the snapshot-isolation native repeat passes.
If that repeat fails, diagnose it before proceeding with this plan.

## Why the current fixture is insufficient

The barcode fixture is mostly flat black, sixteen large barcode bands and one
small moving square. Its archive and live containers average about 0.13/0.10 Mbps,
far below the configured 12/6 Mbps video rates. It establishes source identity,
ordering, clean recording, scoring and transport behavior at low encoded payload
rates. It does not establish encoder/storage/network behavior at sports-video
payload rates or qualify physical camera, thermal load, cellular or adaptive quality.

## Design to explore and measure

Add an explicit DEBUG-simulator-only motion workload while retaining the existing
fixture as the default. Prefer a small bounded set of deterministic textured frame
backgrounds, prepared before the capture clock begins, over expensive random-pixel
generation on every callback. Allocate a fresh pixel buffer for each emitted frame;
never mutate a buffer after offering it to capture consumers. Include texture and
color changes across a substantial central image area, with a documented fixed
memory budget and seed. This is a synthetic encoding stress case, not a claim to
represent real volleyball footage.

Preserve the exact source barcode and audio marker clock. Keep the entire score
comparison crop's background static: otherwise moving background pixels could
falsely satisfy the existing overlay-change test. Preserve source formats, PTS,
callback order, cancellation/join behavior, diagnostic hooks and production source
selection. No capture pacing, queue limits, encoder profiles or quality budgets
change in this slice.

Two options are available: seeded texture buffers with cheap per-frame copying,
or decoded prerecorded motion. Choose the first for an initial reproducible local
experiment: it avoids external assets, licensing dependencies and an additional
live decoder competing with the recording pipeline. Actual camera footage remains
a separate physical-device gate.

## Ordered work

- [ ] Define an explicit trusted opt-in fixture option and its memory/content
  contract. Reject malformed settings before starting owned resources. Plumb it
  through the runner, Xcode test environment, native UI launch and DEBUG simulator
  source selection; absent options preserve the old source. Record selected
  workload in the artifact configuration.
- [ ] TDD the deterministic source: stable seeded initialization, changing central
  image area, unchanged identity bands/static overlay crop, immutable published
  frames, correct NV12 layout/PTS/audio, bounded retained data and joined stop.
  Include scaled test profiles, while actual workload qualification uses 1080p30.
- [ ] Measure actual encoded video payload rates from packet sizes and media
  timestamps in both finalized outputs. Keep audio/container overhead separate.
  Exclude acquisition/partial boundaries explicitly; report steady-window rates
  and retain exact measurement scope. Unit-test packet accounting, invalid/empty
  intervals, mixed streams and timestamp handling. Never treat configured bitrate
  as measured throughput.
- [ ] Run a short isolated calibration experiment, keeping all current frame,
  A/V, scoring, archive and delivery gates. Target sustained video payload rates
  near the existing 12/6 Mbps configuration; initially assess whether at least 6/3 Mbps
  is achievable without the generator missing its own deadlines. These are workload
  calibration targets, not product quality guarantees. If payload stays low or
  generation stalls, inspect the measured cause before selecting a workload.
- [ ] Freeze and review the measured workload and acceptance criteria. Run a
  three-minute hold, then 600 seconds if it passes. Full decode, complete archive
  identities, live terminal delivery, zero recording rejections/drops, clock/age
  integrity and unchanged cadence gates remain required. Preserve all failures.
- [ ] Record exact revision, selected workload, encoded payload rates, retained
  pressure evidence and limitations. Do not enable automatic quality changes or
  higher device profiles on this evidence alone. Continue to actual camera and
  Watch/phone testing when hardware is reachable.

The conditional prerequisite now passes in `native-app-6o9S2U` at `a49408c`.
Independent design review approves this direction; implementation has not started.
