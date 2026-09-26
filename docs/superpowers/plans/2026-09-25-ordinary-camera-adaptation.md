# Ordinary camera adaptive publishing

> Execute after the production probe/cost slice passes specification and quality review. Use superpowers:subagent-driven-development. The user has authorized autonomous implementation and device testing; preserve original recordings and installed runtimes.

**Goal:** Run the reviewed progressive controller through normal app construction, without laboratory selectors, while clean recording and native scoring remain independent.

## Runtime construction

- Add an explicit production publisher factory. Start the actual live encoder at `.minimumStartup` before its first sample. With valid observation ownership, create one `PublishingCandidateCampaignOwner`, forward the live publisher's compressed AAC observations to it, enable bounded native probes, and wrap the publisher in continuous `NativeOwnedCandidatePublisher` using per-next-profile production plan selection. Recording configuration remains untouched.
- Preserve the existing behavior when optional observation construction fails: minimum publishing and the archive continue; unavailable measurement cannot authorize an increase. Do not turn optional diagnostics into a new start failure.
- Add a production quality-driver factory using progressive measured-candidate strategy, shared candidate-recovery credit, guarded mutations and the continuous delivery consumer. Use the existing timing contract conservatively for the first device integration; do not silently promote experimental2/3s settings into production. Measure the actual phone path before selecting a broader latency contract.
- Construct the supported ladder explicitly. Begin with240p/360p integration evidence, then qualify540p/1080p using the same measured next-candidate route. Current4K exceeds the native probe cap and is outside automatic support. Do not advertise unqualified maximum resolution.
- Resolve worker pressure limits from the current authenticated processing report's recognized backend (`software`, `videotoolbox`, `nvenc`) with explicit configured limits. Keep publication/processing-scope checks, and reject unknown/missing backend evidence for recovery. Do not hardcode the Mac's VideoToolbox backend for cloud/home workers or treat a backend name as proof of capacity.
- Install the owned publisher in the actual session with recovery-budget probe policy. Install candidate, delivery and cadence readers through existing weak, current-attempt/tap/publication ownership checks. Production candidates must use the new production admission estimate; lab candidates retain the laboratory route. Selection belongs to the constructed publisher/reader, not a mutable environment lookup at admission time.
- Ordinary Debug and Release construction must agree. Preserve all explicit simulator fixture routes and their schemas/flags; a diagnostic route intentionally lacking a quality driver must not fall through into production adaptation. Promote only the actual runtime hooks still inside DEBUG in `CaptureStreamingModel`.
- Disable retained quality-driver JSON histories in the explicit production factory without changing defaults used by laboratory/tests. The continuous delivery consumer and owned lifecycle remain authoritative and bounded throughout a match.

## Verification

- [ ] Add construction tests for normal Debug/Release-compatible dependencies, real minimum-start settings, campaign AAC forwarding, explicit production admission selection, continuous control, backend selection and missing-observation fallback.
- [ ] Exercise one full model path: clean-recording tap → minimum native publisher → healthy source/delivery → next candidate → acknowledged increase → fresh congestion/delivery failure → minimum → renewed healthy recovery. Verify current receipts and owner joins; do not substitute a fabricated capacity flag.
- [ ] Preserve existing lab-route, cancellation, stop/replacement, stale-report and native scoring tests. Run appropriate focused suites, fullFilmModel and arm64 Release simulator build; review specification then quality.
- [ ] Run an ordinary-construction simulator camera/source vertical against the local proxy and mock RTMP recorder. Verify all three outputs, score changes, start-low, actual increase/reset/recovery and archive continuation. Keep experiment flags confined to source/fault injection, never to enabling the production controller.
- [ ] Rebuild current signed phone/Watch products, confirm device availability and announce UI automation before launching it. Do not repeat the known Watch preparation timeout without a readiness change. Run the paired physical vertical when reachable, including visible camera, Watch point/undo, clean archive export and both overlaid MP4s.
- [ ] Record achieved profiles, frame delivery, startup/ramp/fallback times, audio gaps, thermal state and archive integrity separately. A short smoke pass does not close full-match, cellular, broader-device,4K or remote-host qualification.

## Inspection notes

Current `CaptureStreamingModel` already tracks source, decoder-delivery/cadence and receiver-probe reports in Release. Remaining construction hooks are its default publisher/quality factories, DEBUG owned-publisher installation and simulator-only candidate reader. `PublishingQualityDriver` currently stores fixed worker limits and up to512diagnostic rows; production needs explicit backend resolution and diagnostics disabled. `PublishingQualitySession.SourceScope` already binds processing scope/publication, so preserve that identity rather than creating a second recovery tracker.

The existing `NativeStreamingTests` always sets `SCOREBUG_TEST_VIDEO_OBSERVATIONS=1`, which selects a laboratory1080p default when no live profile is specified. Preserve that test's semantics. A new ordinary-construction test should omit that selector; `SimulatorCaptureSource` can provide synthetic input or the staged file independently. Injecting a source or network fault must not enable the controller. Check actual acknowledged profiles through bounded observation/status evidence, and verify recorded media separately; proxy output dimensions alone cannot reveal changing source resolution when the proxy scales it.

Physical availability is a separate constraint: the latest read-only CoreDevice check reports both known devices unavailable. The earlier Watch failure occurred during destination preparation before its test started, not inside the scoring test. No new hardware test has been launched for this plan.
