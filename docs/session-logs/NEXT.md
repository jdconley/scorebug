# Next session handoff

## Current state

- Active unbounded goal: a reliable native recording/scoring/Watch/progressive-streaming vertical through the portable overlay proxy to mock RTMP MP4 and optional overlay MP4. Goal remains active; do not claim completion.
- Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Do not edit original `/Users/jd/src/scorebug`.
- [Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns current goals/status/todos. [Current session log](2026-09-25-ordinary-camera-adaptation.md) owns chronology, failed artifacts, exact hashes and reviews.
- Runtime: production probe source-wait scheduling `3926e83`; point-refresh fix `ce482b7`; measured-cost feedback `8946937`. Offline audio checker `de6ebfb`. Paired harness `2544de8`, exact Xcode configuration selector `0b5b171`. Later commits may be docs only.
- No root or agent process remains active. All live runners, labs, decoders and waveform jobs joined. Every failed artifact is preserved. No PR created/requested.
- Sole source implementer has been `/root/ordinary_native_vertical`; independent reviewers `/root/continuous_delivery_spec` and `/root/srt_instantaneous_pressure` are idle and available. Root owns docs/independent media analysis. Continue specification then quality review for new implementation slices.

## Verified checkpoint

**Run14 `ordinary-native-owpmLF` / `device-lab-KCyGMI` (runtime3926e83, docs HEAD5a4670d)** passes the ordinary native workflow145.341s/no skips and clean cleanup. Normal app starts240p, scores HOME on one native tap, acknowledges360p600k, holds, stops streaming while recording continues and exports through the native app. First candidate evaluates fresh but lacks headroom, learns912136bps; the next succeeds with cost912152bps/padding1307575.617bps and sourceage1.421965s. Ack attachmentF5AC2767-7935-4F27-A9B2-8F7C3CCE2D64.json.

Root verifies41archive segments/sourcehash, full A/V decode and frame identities: archive2372frames0–2371, bothlive2109identicalframes153–2261,30freshfps, no audioPTSerrors>3ms, tail110frames. Corrected waveform check passes18archive/16eachlive probes, A/Vcoverage, both0–0→1–0 glyphs and cleanarchive. Durable combined report: `native-media-verification/qualification-summary.json`. This is a passing checkpoint, not sustained/recovery/hardware qualification.

Scheduling change passes216 targetedtests plus final2timingcontrols, both reviews and DebugUI/Release builds. Audio correction passes89tests and both reviews. Its513tap kernel requires256real support samples, retains exhaustive1/32grid/all thresholds, and independently fixes lossless high-frequency controls. Complete frozenrun12 requalification passes40archive/38eachlive probes; original failing liveframe1817 now.992534 at unchanged.98 threshold. Original failed report hash unchanged. New reports/provenance in each run's `av-overlay-513tap/`; run12's adaptive failure remains failed.

## Watch boundary and paired attempt

[Paired ordinary plan](../superpowers/plans/2026-09-25-paired-ordinary-vertical.md) is implemented/reviewed:33focusedtests, bothDebugUIbuilds. Explicit `--lane paired`, real WatchConnectivity identity/setup, unchanged150s240→360gate before offer, HOME30s/AWAY15s holds, intended-test/no-skip and durable commands/generations, bounded joined cleanup. Capture/scoring identities are distinct; selected capture binds to actual active recording. Exact Xcode scheme/platform/SDK26.2/arm64 configuration avoids generic Watch sibling ambiguity. Interrupted creation ownership is recovered by exact per-run names/IDs.

- Attempt1 `ordinary-native-LM7oKh` fails before UI/capture due ambiguous Watch xctestrun files; cleanup[]. Selector fix0b5b171 addresses that observed cause.
- Attempt2 `ordinary-native-LhOSEV` / `device-lab-kv7aZq` at0b5b171 reaches240p64.21s and360p113.40s, but Watch identity/offer gates fail. Phone continuation277.90s/export292.39s pass. Both test runners/lab join; cleanup[]. Zero Watch pairings/commands, one accepted phone takeover, broadcastgeneration1start→2stop. `paired-failure-summary.json` and both attachments retained.
- Owned pair is active/connected, both app bundles installed, phone embeds Watch and companion ID correct. WatchWC activates/reachabletrue but installedfalse; context and immediate probe both return7018. Sanitized logs and registration inventories were captured before deletion. This reproduces earlier gKwDrj/WWMaEj failures in the legacy log; do not forget this boundary or repeat unchanged paired runs.
- Root full decode60943 joined0: actual export114segments, archive6762consecutiveIDs0–6761; bothlive6481identicalIDs154–6634,30freshfps, no identity/audioPTSerrors, tail127. No Watch-score or sampled waveform/glyph qualification claimed for this failed run.
- [Apple guidance and evidence](../research/2026-09-25-watch-companion-registration.md): Apple's official sample calls for physical iPhone/Watch testing. This is not proof all simulator APIs are unsupported or a confirmed Apple defect. Further simulator work needs a concrete registration change or minimal independent framework reproducer; no speculative immediate-message fallback.

## Latest device readiness reply

The user approved the automation prompt and reported both devices ready. One fresh Watch build retry still exits70 before compilation after181.326s; `watch-ready-retry-build*` artifacts are preserved under the physical preparation directory. Follow-up readiness still shows the developer tunnel disconnected/DDI unavailable. Computer-use inspection found the Mac locked; a new question asks the user to unlock the Mac so Xcode’s connection window can be inspected. Do not ask for automation approval again. No capture/test started; all children joined. See the [new session log](2026-09-25-watch-readiness-retry.md).

Read-only ordinary congestion proposal is retained at `artifacts/qa/ordinary-congestion-design-proposal-20260925.md`: separate publish/read addresses, bounded event-triggered impairment after confirmed360 and restoration after acknowledged240, longer finite source. No source implementation yet.

## Next work

1. Inspect Xcode after the pending Mac-unlock reply, then resume physical paired acceptance once destination preparation succeeds. Automation approval is already granted; do not request it again without an observed new prompt. Do not blindly rerun Watch preparation.
2. If hardware readiness remains unresolved, progress independent ordinary congestion/reset/recovery qualification. Read the [owned recovery plan](../superpowers/plans/2026-09-25-owned-recovery-qualification.md) and preserved failures before changing anything. Wider profiles, sustained operation, route changes, other scorer devices and remote workers remain open.
3. Preserve the older `native-app-9IVqF0` failures: experimental3000ms/1000ms has four phases but32MiB audit exhaustion leaves20.4s uncovered, plus21ms liveaudio gap. Exact-value interning experiment33.5→11.4MB is not integrated. The513tap checker fix does not fix that gap. No cap increase or unchanged rerun; boundary/evidence diagnosis comes first.

## Environment and commands

- Signing Conley Chaos LLC `B222J9J7B8`; phone16Pro `00008140-001474110C13001C` iOS26.7, Ultra2 `00008310-0000B2CE3E08A01E` watchOS26.6. Physical artifacts `physical-paired-current-mtc1mc54`: phone fresh signedbuild/install at runtime3926e83 passes, existing881appfiles preserved; Watchbuild exits70 connecting before compilation. Watch booted/DeveloperModeenabled/paired but developer tunnel disconnected/DDI unavailable. User was asked for USB/unlocked-nearby and Xcode connection warning; the newer Mac-unlock question is pending; see latest readiness reply above.
- Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; installediOS26.2/watchOS26.2. No downloads or unrelated simulator cleanup. Disk lastchecked233GiBfree.
- FFmpeg/ffprobe `/opt/homebrew/opt/ffmpeg-full/bin/`; LAN192.168.1.130. Normal maintained `scorebug/ingest:campaign-probe-v3`, worker100ms reports. Remote templates unqualified.
- Source `artifacts/qa/prepared-native-owned-recovery-hHjv1n/input.mov`,390s/391321588bytes, SHA256 `c1d0642bb102ca27733f39ece227c77135699e89f9ad29a67ddec34d5d2af814`. Downloads originals untouched.
- Ordinary command: `node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-native-owned-recovery-hHjv1n/input.mov`; add `--lane paired` only after resolving/reframing the registration boundary.
- Root artifact helpers: `collect-ordinary-export-20260925.py`, `analyze-ordinary-recordings-20260925.py`, `verify-ordinary-av-overlay-20260925.mjs`. Use exclusive output directories and actual native exports, never concatenation. Paired checker `verify-paired-ordinary-av-overlay-20260925.mjs` is prepared/syntaxchecked for ordered0–0/1–0/0–1 but has no passing paired media yet. Do not apply phone-only final1–0 checks to Watch runs.
- Print bounded scalar diagnostics; keep private setup/tokens/full timelines out of tool output. No heavy offline analysis/builds during live capture.
