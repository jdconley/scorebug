# September 26 — Separate native scorer and physical camera

Start: `e2c4b1b`, branch `codex/local-validation`, authoritative checkout `/Users/jd/.codex/worktrees/scorebug-local-validation`.

## Scope

Verify one native simulator scoring app can take over, award/undo/award while the real phone records and publishes through the overlay proxy to both live recordings. This is an unimpeded role-separation smoke, not adaptive recovery or another physical phone/Watch qualification. Existing runner LAN-privacy and Watch developer-connection questions stay separate.

## Implementation and review

Added two explicit UI roles, a bounded launcher that builds before capture and owns one temporary simulator, and an independent durable-receipt verifier. The simulator scores with normal native controls and refuses capture permissions. The camera checks live/recording status between remote score changes, then continues its archive after live stops and exports the actual new UUID. Capture failures preserve terminal cleanup.

Native specification review corrected an initial HOME-ack race and prevented shared permission helpers from granting capture permission to the scorer. Launcher review required failed-run scorer inventory retention and clean committed source/binary provenance. Evidence review bound start/stop ACK selections and recording identity/start timestamp/sequence through final stop. Native quality review required finite duration baselines and actual advancement throughout the final hold. These are verification safeguards; production streaming policy is unchanged.

The combined first regression run found one mini Swift test harness missing the new default-disabled permission helper (45/46 passed). The harness now models that default and retains its original recovery teardown assertions. Final focused checks: 55/55 pass, including the actual scoring API/SQLite integration and rejection of contradictory receipts. Logs: `artifacts/qa/separate-native-scorer-validation/`. Swift parsing and diff checks pass. Builds and device run are next; no new media result yet.

## First build attempt

`separate-native-scorer-EoCbM8`, source `90036c4`: signed phone build passed; generic simulator build failed linking x86_64 SRT symbols. The launcher omitted the arm64/ONLY_ACTIVE_ARCH settings used by the existing ordinary simulator launcher. Host is arm64. Corrected only the simulator build arguments to match the established arm64 route, including its ad-hoc signing settings. No simulator was created, lab started or camera recording begun; command joined with no cleanup failures. Failure log is retained.

## Physical run and retained evidence

Source `78c4fdd`; launcher `separate-native-scorer-kfuQEO`; lab `device-lab-uZky2H`. Both signed phone and ad-hoc arm64 simulator builds passed. Both exact native XCTest leaves passed once, zero skipped: camera260.774s, scorer202.304s. The owned iPhone14/iOS26.2 simulator was shut down and deleted after both commands joined. Lab worker exited0 without force; receiver finished; no cleanup failures. Scorer recording/export inventories are empty.

Native camera observed HOME1→AWAY1→undo→AWAY1, retaining publishing and producing-output states. Scorer holds were12.65,12.66,30.76s. Camera archive checkpoints advanced36.27→54.00→72.20→121.94s; after streaming stopped it advanced to150.74s before final151.57s. UI reported240p350kbps startup and360p600kbps later. This observes physical automatic increase but does not qualify adaptive collapse/recovery or sustained motion.

`durable-evidence.json` passes the six-command/two-media-command contract, distinct scoring identities and continuous recording association. Final score1–1, final revision8, stream generation2/stopped, sole recording stopped after stream stop. Native UI export identity matches `0FA9CD92-8240-44BF-AA14-28E776A63E72`; only its new export was copied from the phone. Before/after source/binary/xctestrun hashes pass. Independent evidence review found no workflow/durable contradictions.

All media is retained under the lab, with inspection scripts/reports in the launcher artifact:

- Clean phone archive:151.536667s,4546H264 frames,1920×1080/~30fps, mono48kHzAAC.
- Proxy overlay MP4 and mock RTMP MP4:4243frames each,1920×1080/~30fps,141.437s video; overall~143.15s, mono44.1kHzAAC. Output1080p dimensions include proxy scaling; they do not establish native1080p live detail.
- All three full A/V decodes pass without errors with precise output timebase. The older helper's null-muxer default30fps output timebase emitted rounding/DTS warnings despite strict inputPTS. Replaying with `-fps_mode passthrough -enc_time_base:v 1:90000` removes these output warnings without modifying inputs. Both original and corrected logs remain.
- Encoded videoPTS strictly increase: maximum gap35ms archive,33.356ms proxy,34msRTMP; no>50ms gaps. Audio packetPTS increase, no gaps>5ms (maximum~1microsecond). These are timestamp claims, not fresh-content or perceptualsync claims.
- OCR everysecond shows both live outputs0–0→1–0→1–1→1–0→1–1; native actions and durable receipt order agree. Archive20-second samples have no overlay. Contact sheets and sampled images are retained.
- Scene is almost completely dark. User was asked to point the rear camera at a lit moving scene before another capture. No motion qualification from this run. Live video starts1.714/1.715s after initial audio; perceptualA/Vsync remains unqualified.

Final scope: separate native simulator scorer plus physical recording/streaming workflow and encoded-media smoke pass. `assessment.json` keeps `mediaQualified:false`, fresh motion, perceptualsync and adaptive recovery unqualified. `evidence-manifest.json` binds retained reports/database; media hashes are in `media-detail.json`. No production behavior changed.

## Next

Repeat with a lit scene after owner repositions the phone if motion inspection is needed; do not rerun unchanged dark capture. Resolve runner LAN privacy for the bounded physical recovery probe and Watch developer connectivity for combined paired scoring. Preserve those pending owner questions and prior failed evidence. Main delivery acceptance stays open.
