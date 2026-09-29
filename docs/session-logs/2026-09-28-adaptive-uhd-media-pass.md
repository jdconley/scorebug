# Adaptive UHD and final media pass — September 28

Starting0099fbe. Joined the already-running normal ladder/software-proxy capture;
no source changes, hardware, agents, push or broad suite. Previous turn was progress:
isolated proxy backend interaction and launched this material verification.

## Evidence

`headless-native-nZ4tzv`, exec80423 joined0, cleanup empty;330s configured,332s
through finalization. Normal240→360→720→1080→2160 ladder, no diagnostic shortcuts.
UHD trial256s/confirmed270s, stays at24Mbps until stop. All five receiver geometry
runs have exactly3000/90000maximum PTS delta;2234UHD frames (about74s),0SDK/app
input drops and0native submit errors. Native hardware selected; proxy software.
Producing fe332cb+saved patch matches the code later committed0099fbe.

Native RecordingLibrary export reuses the current test bundle, exec41230 joined0.
All167segment metadata/hash entries verify. A single full A/V decode per file
checks source identity, with packet timestamps read separately:

| Media | Consecutive source frames | First–last identity | A/V end offset |
| --- | --- | --- | --- |
| Clean native archive |9927 |0–9926 |approximately0ms |
| Proxy final MP4 |9846 |61–9906 |−2.126ms |
| Mock RTMP recorder MP4 |9846 |61–9906 |+13.436ms |

All are3840×2160H.264/AAC, audible audio with0timestamp gaps; both outputs have
identical frame identities. Archive continues20frames beyond the final live frame.
Preview frames at300s show clean volleyball footage in the archive and the score
overlay in the proxy output. Score stays0–0 here; changing score/native Watch/UI
have separate retained acceptance and were not repeated.

## Verifier correction

Media exec97533 joined1 because its initial20µs interval tolerance rejected every
RTMP33/34ms step. This was a verifier precision error, not a frame loss. Saved packet
data proves maximum anchored30fps error0.667ms across all9846frames, with consecutive
source IDs and matching output identities. Applied a1ms quantization bound only to
the RTMP path and also checked cumulative cadence error. No decode rerun.
`final-media/result-first.json` preserves failure; `result.json` records correction
and retained evidence hashes. All actual codec decodes exited0 without errors.

`final-acceptance.json` hashes adaptive analysis, final/original media reports,
native export, verification script and viewed preview frames. Full reports in
`final-media/`; script `artifacts/qa/uhd-readiness-20260928/verify-final-media.py`.
This is short local native/media acceptance, not physical/full-match/UI qualification.

## Result and next work

The local full-feature media path now has a passing4K configuration using software
proxy encoding. The simulator UHD encoder ceiling and colocated VideoToolbox/probe
interaction remain explicit backend limits; do not silently generalize this pass.
Plan records the completed local media milestone and retains sustained/backend
qualification. Acceptance history was trimmed into current status with session
history retained separately. Local runbook has the reproducible command.

Next address intermittent loss/whole-client outage, severe-congestion media and
abrupt output tails. Reuse this media pass. All80423/41230/97533 handles joined;
no active jobs. Documentation-only updates need diff checking, no test rerun.
