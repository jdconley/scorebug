# 240p live fallback qualification

The 360p candidate remains about 3.55 Mbps on the structured-motion fixture and
is not cheaper than 540p. Qualify the planned 426×240/30 fps candidate next, with
an initial requested video bitrate of 350 kbps. That rate is an experiment setting,
not a claim about achievable bandwidth. Keep the source workload and independent
1080p archive unchanged so a smaller format cannot disguise missing frames.

Use the existing fixed-profile native fixture, scoped format/cost observers and
portable worker. Add `low240` / `240p30` explicitly. Geometry must use independent
horizontal and vertical scale factors because 426×240 is not an exact uniform
scale of 1920×1080; round diagnostic crop rectangles to integer pixels. Existing
540p/360p geometry and production defaults stay the same. Probes remain 540-only.

- [x] Add failing profile, fixture-admission, actual-format, actual-cost, geometry
      and worker-configuration tests for 240p, including crossed-profile rejection.
- [x] Implement native profile, explicit UI/runner admission and worker profile.
      Do not enable automatic adaptation or change production startup.
- [x] Run streaming/media/model/tooling/worker tests and worker typechecking;
      build simulator and unsigned iPhone/Watch targets.
- [x] Freeze source inventory and run the same 180-second fixed-profile native
      simulator fixture with a timed 4 Mbps phase. Independently verify actual
      dimensions, native byte cost, archive/live frame identities, audio alignment,
      full decodes and joined teardown.
- [x] Compare measured cost with retained 360p evidence. A cheaper successful
      result becomes a candidate for a stricter link test; passing a 4 Mbps test
      alone does not qualify operation on a weaker link or quality transitions.
      Record failures without weakening media continuity criteria, then commit.

## Verified outcome

80 streaming, 254 media (188 XCTest + 66 Swift Testing), 231 capture-model,
345 worker and 1,199 tooling tests pass. Worker typechecking, simulator test build
and the combined unsigned iPhone/Watch Release build pass. Targeted red tests
reproduced the missing native profile and tooling admission/format/cost support.
The 540-only bandwidth-probe restriction is retained and explicitly tested against
both lower profiles.

Actual run `native-app-hB2BBX` passes the finite fixed240 scheduled-pressure test:
6,424 consecutive archive frames, 6,049 consecutive retained live frames (192
through 6,240), all 106 archive/100 live audio markers and clean full decodes.
The native pre-mux format is actually 426×240. Minimum reported receiver cadence
is 29.6 fps. The limited phase lasts 60,000.443208 ms and forwards 16,846,176 wire
bytes without proxy drops. All process owners join.

Eight retained complete native video-cost windows contain 3,966,157 payload bytes
and peak at 1,992,332 bps, compared with 3,546,668 bps in the preceding fixed360
run `native-app-H73kCA`. This is about 44% less measured peak-window payload for
these separate finite trials. The constrained phase's average wire load, including
transport traffic, is 2.246 Mbps. Neither measure establishes available capacity,
a worst-case bound, or achievement of the requested 350 kbps rate.

Independent verification reconstructs actual decoded frame identities, native
format, callback payload sums, audio coverage and proxy accounting. The unchanged
control passes and all 11 damaged copies are rejected. Source and evidence hashes
are frozen in `artifacts/qa/low240-final-verification.json`; the before/after
comparison explicitly records its separate-trial limitation.

Next qualify this candidate under an explicit 3 Mbps uplink schedule, preserving
all existing 4 Mbps cases and continuity requirements. Its observed 2.246 Mbps
wire load makes that a useful stricter experiment; this is not a promise it will
pass. After that, qualify transitions to/from the minimum and implement the short
health windows and progressive controller. Production startup and automatic
adaptation remain unchanged, and physical phone/watch/remote host gates stay open.
