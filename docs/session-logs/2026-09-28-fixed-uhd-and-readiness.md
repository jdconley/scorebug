# Faster combined UHD diagnosis and readiness optimization — September 28

Startingb2b492f, clean. The previous turn ruled out plain encoder count/selection and
replacement in short isolated cases. This turn inspected capture sharing: the same
immutable source buffer feeds independently bounded recording/publishing branches;
no extra pixel copy or writer wait occurs on the publishing branch.

## Fixed-profile diagnostic

Added explicit debug-only fixed4K construction to the headless runner. Requires
`--fixed-uhd on --quality 2160 --timing-audit off`, duration≤60s and no injected
disconnect. Retains real archive, API, SRT, proxy and both outputs, and100ms control
polling. Skips adaptive quality control/probing deliberately; cannot qualify normal
startup/admission. Normal app/release behavior remains adaptive. The entry gate still
requires actual UHD source and fresh matching worker/output capability.

35s run headless-native-KS4ILp, labytjSFH, exec50640 joined0, cleanup[].70boundary
samples, recording/publishing true at36s.0app ingress evictions/rejections,0SDK raw
queue drops,0native submission errors,34.3msmaximum submission. Receiver sees998
consecutive3840×2160frames with exact3000/90000PTS steps. Both output files are kept;
no full archive/audio/overlay decode or sustained qualification is claimed.

This uses the first35s of the existing UHD fixture, whereas the latest adaptive
failure occurs near source256–271s; scene/long-running state differ. It demonstrates
that the combined path can process4K, not that policy overhead alone caused loss.
The next comparison must preserve content/warm-state differences explicitly.
Evidence/source hashes: fixed-uhd-analysis.json and implementation.patch/json in
KS4ILp. The optimization below postdates that capture and gets no integration credit.

## Production optimization

Found a needless allocation in pollLocalHealth: every100ms it copied both2048-frame
source-history rings solely to test whether encoded history was nonempty. Added a
lock-protected scalar presence accessor backed by the ring's existing lastPTS marker.
It preserves prior retained-history semantics including disabled history, invalidity,
eviction and close. It introduces no new health/admission credit or freshness gate.
The full history snapshot remains available for consumers that actually need it.

11focused VideoSourceHistoryTests pass, including the semantic equivalence case.
Incremental FilmModel build-for-testing passes. Logs: fixed-uhd-20260928/readiness.log
and readiness-build.log. Handles3532/54367 joined0. No broad suite, full adaptive
rerun, device work or quality/queue changes. All owned work is terminal.

Remaining: verify sustained adaptive4K with the optimization and continue combined
workload diagnosis if loss persists. Reuse the fixed-profile≤60s path for independent
component checks; never present it as adaptive acceptance.
