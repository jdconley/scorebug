# Replacement latency breakdown and physical recovery plan

**Goal:** Separate first-new-frame encoder latency from the work before submission, using existing retained traces, then make the ordinary recovery test runnable against the physical camera.

**Status:** Existing trace inspection shows about 42 ms from replacement request to first new submission on both platforms. Submission-to-completion is about 431 ms in the simulator and 27–30 ms on the Mac hardware encoder. These preliminary calculations need strict replay and review. They do not prove phone behavior or isolate old-session drain time.

**Architecture:** Extend the existing offline native downshift analyzer. Reuse already matched exact source PTS, encoder IDs, native submission/completion, compressed output and replacement receipt; add no runtime observers or media queues. Keep the recovery policy and all media acceptance gates unchanged. Physical camera recovery uses the existing finite recovery gates with real camera input, not the simulator file fixture.

## Decisions

- Reuse retained native traces first. Adding runtime drain observers would add code and capture overhead before establishing that current evidence is insufficient.
- Do not repeat relative sender pacing: the earlier explicit `maxbw=0` experiment already failed live media. Keep its original contract and failure evidence.
- Do not infer phone latency from Mac hardware or simulator results. Hardware acceptance still requires a real run after unlock.
- Native-only mocked-socket traces establish encoder/mux boundaries, not network delivery, A/V integrity or full collapse behavior.

## Tasks

- [ ] In `scripts/native-downshift-analysis.test.mjs`, add causal tests for first-new-submission/completion/output/receipt intervals, counts, rate-only absence and a new submission before replacement request. Confirm missing-analysis and invalid-order failures before implementation.
- [ ] In `scripts/native-downshift-analysis.mjs`, return `replacementTiming` or null. Bind all values to the receipt's exact first-new PTS and encoder. Require request ≤ submission ≤ completion ≤ compressed output ≤ receipt. Report request-to-submit as a combined upper bound for pre-submission work, not exact drain duration.
- [ ] Run `node --test scripts/native-downshift-analysis.test.mjs`. Replay both modes at frames 180 and 181 in the retained host/simulator directories with fresh analysis outputs. Preserve input hashes and old results. Independently review the exact code and results.
- [ ] Inspect and implement a separately opt-in physical camera recovery UI entry point and launcher, reusing the current ordinary recovery gates and audited control endpoint. Preserve hardware-only checks, current signed apps, finite cleanup, existing archive data and source-specific media limitations. Review the concrete design before implementation; build before any capture.
- [ ] When unlocked, run physical paired scoring/camera acceptance and then the physical collapse lane sequentially. If hardware remains locked, retain readiness as pending; do not fabricate a hardware pass or repeat an unchanged simulator campaign.

## Physical recovery design

The simulator-only controller and UDP proxy bind loopback. Add explicit `physicalRecovery: true` to `startDeviceLab`, valid only with `publisherRecovery: true`. Derive the controller bind, UDP frontend bind and publishing host from the already validated, locally assigned RFC1918 `options.host`; default remains exactly `127.0.0.1`. A shared test utility validates bind addresses before socket allocation. Reject wildcard, public, DNS, IPv6, noncanonical and unassigned private addresses. Do not expose tokens in command arguments/logs. Keep the authenticated two-command controller, byte/time bounds, token/run/sequence checks, fault settings and joined shutdown unchanged.

Add hardware-only `testPhysicalIPhoneRecover720ScoreStopAndExport`, guarded by `SCOREBUG_PHYSICAL_RECOVERY_720=1`. Set the existing recovery720 flag, retain a physical evidence prefix and `captureSource: physical-camera` in its phase attachment, and call `runVertical(...recovery:true)` without simulator source injection. Invoke the adaptive gate for physical recovery too; preserve failures through stop/export. A Foundation-only test helper validates controller configuration: loopback remains valid for simulators; LAN is accepted only by the physical entry point and only for the exact private API host. Token remains 64 lowercase hex characters and run ID remains UUID. Include this helper in the host FilmModel tests via the generated project spec.

Add `scripts/test-physical-recovery.mjs`: explicit phone UDID and private host, default 700 ms upload budget, dedicated signed physical build products, private test environment/plist, 900-second lab, opt-in physical recovery, one selected XCTest with finite timeout, exact non-skipped leaf requirement, retained xcresult/phase evidence and joined lab shutdown. No simulator creation, file-source substitution, existing recording deletion, or media-pass claim. Store the audited run/lab identity and private artifact paths. Device media collection uses the actual new recording/export and successful-transition audit, never old recordings. Physical-camera images lack fixture barcodes, so camera continuity and visual acceptance require source-appropriate checks; do not run the file-fixture barcode validator against arbitrary camera imagery.

- [ ] Add/test explicit LAN bind validation and device-lab physical routing; prove authenticated real UDP constrain/restore and default loopback unchanged.
- [ ] Add/test native controller configuration parsing and physical UI entry point; compile current signed iPhone UI test products.
- [ ] Add/test physical launcher options, private environment and lifecycle behavior; inspect concrete dry configuration before a real device run.
- [ ] Independently review all changed code. Run relevant host/Node tests and signed build sequentially before any capture.
