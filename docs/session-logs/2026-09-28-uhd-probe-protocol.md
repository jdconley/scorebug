# UHD probe protocol

Starting commit `e3f9e56` in the authoritative local-validation checkout. This batch
implements the explicit protocol budget in the [design](../superpowers/specs/2026-09-28-uhd-probe-budget.md).
It does not enable the app's4K ladder yet.

Native SRTStream selects a budget once at construction. UHD requires repeatable
campaigns, preserves the budget across stage replacement and joined restart, emits
v4, caps at48Mbps/64MiB, keeps300ms leases/60second lifetime, and never banks more
than one packet. Legacy paths retain all previous bounds. Relay observation, API
validation and native Swift receiver validation understand v4 with the same counter
rules. The new relay patch applies after the existing scorebug/drain patches.

## Focused verification

All commands/logs live in `artifacts/qa/uhd-probe-20260928`:

- Native `SRTStagedBandwidthProbeTests`:18tests pass, including new explicit-budget,
  token/wire/expiry and final-whole-message checks. No actual throughput claim.
- Native `SRTStreamPaddingTests.uhdBudgetSurvivesReplacementAndJoinedRestart`:passes;
  verifies the actual stream owner carries budget through replacement/restart and
  revokes the old authority. Socket is an explicit in-process double.
- Real relay Go source `go test ./internal/servers/srt -run TestProbeReader -count=1`:
  passes in0.535seconds. Newv4 reader checks cover wire/rate, whole-message reserve,
  restart accounting, mixed-version rejection and legacy bounds; existing probe
  reader tests also pass. No live SRT network run in this batch.
- API receiver stages/campaigns:63tests pass; protocol build and API typecheck pass.
- Swift `WorkerReceiverProbeCampaignTests`:11tests pass, includingv4/legacy limits.
- SDK patch reverses to all162 upstream SHA256 hashes and reapplies exactly. Only
  changed source sections were regenerated, preserving unrelated patch text.
- The pinned MediaMTX archive hash and all three patches apply; probe source/tests
  exactly match the tested checkout. Dockerfile includes the new patch/version.
  No image was built or selected yet; cached `drain-v1` remains the current lab image.

All jobs joined with exit0. No simulator/hardware capture or broad suite was run.
The next batch must carry the budget through ScorebugStreaming's owned wrappers,
source/output capability selection and candidate plan, then build a separately tagged
relay image and qualify actual4K native/media throughput. Existing diagnostic audit
helpers intentionally still requirev3; extend them explicitly for the new lane,
without rewriting old evidence or broadening legacy bounds.
