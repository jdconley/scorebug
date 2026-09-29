# September 29 — physical TV capture and Watch inspection

Starting HEAD `0c9ccc5`, authoritative worktree `scorebug-local-validation`.
User supplied phone, Watch and a volleyball broadcast on TV; physical work resumed.
Xcode26.2, authorized team B222J9J7B8, LAN192.168.1.130, software proxy.
No external broadcast or original/user recording deletion.

## Physical phone results

- `physical-recovery-wkEu4m`: signed build succeeded; runner lost its IDE connection
  before capture (exit74), cleanup passed. No camera result inferred.
- `physical-recovery-jD6654`: focused app-loopback network probe passed. This justified
  one retry of the actual camera workflow.
- `physical-recovery-EcJuQu`, lab `device-lab-MvyTsz`: real camera/archive/SRT/native
  phone point/stop/archive continuation/native export ran. The adaptive workflow
  failed before controlled impairment:240→360 trial at revision1, then240 reset at
  revision2. Original failure and `mediaQualified:false` are retained.
- No impairment exchanges occurred. Reset cause was `missingCapacity,unknownPressure,
  trialRollback`; thermal unknown, worker/transport nominal,150captured/encoded/received
  frames and zero reported source loss in the selected five-second interval.
  Last two-second delivery report had60on-time frames, no late/missing/uncertain frames.
  Measurement renewal rejected its changed policy/authority context. These observations
  do not establish why thermal evidence became unknown or justify changing thresholds.

The phone's exact exported recording `DBC046C8-46BB-463C-87AF-8C073D4978DC` was copied
without altering its original. The matching attempt transition journal was also copied.
`media-validation.json` binds all three saved files and records full strict A/V decode,
frame timestamps and audio packet continuity. Each check passes:

| File | Video | Maximum video gap | Audio gaps >5ms |
| --- | --- | --- | --- |
| Clean archive |1920×1080,4297frames,143.237s|35ms|0|
| Proxy MP4 |1920×1080 canvas,3735frames,124.503s|33.356ms|0|
| Mock RTMP MP4 |1920×1080 canvas,3735frames,124.503s|34ms|0|

Proxy canvas resolution is not upload resolution: upload remained240p except the
brief360p trial. Visual samples show the TV volleyball footage, no Scorebug overlay
in the clean archive, and proxy score changing0–0 to1–0. Encoded continuity alone
is not fresh-frame, perceptual-sync, or adaptive-recovery acceptance.

## Diagnostic changes

A gated Watch UI test inspects saved setup provenance without issuing setup/scoring
UI actions. Normal app restoration/receipt recovery still runs on launch. Generic
signed Watch build-for-testing succeeded. Initial `watch-inspect-current-ItPrgW`
execution timed out before test launch: Xcode asked for unlocked-device readiness.
User confirmed both devices ready; `watch-inspect-ready-20260929` is the separate
retry, retaining the same frozen test configuration. No pending pairing identity
has yet been established; no Keychain or pairing reset is authorized by these results.

The applied-transition journal now includes bounded raw thermal state, freshness,
closed/quarantined state, and enclosing interval bounds for unknown pressure as well
as elevated pressure. This is evidence for the next capture, not a policy change.
The previous physical capture predates this instrumentation.

## Watch readiness and safe recovery

The ready-device retry lost its runner connection before launch. After the user put
the unlocked Watch on their wrist, `watch-inspect-wrist-20260929` passed. The retained
provenance confirms the exact old test game16565f6b-c70b-42e3-9de4-e0cbde243dae and
pairingde9c7b59-2f70-4b54-949c-a706a08ef3da, with no pending scoring command.

`watch-reconcile-20260929` used a SQLite backup of the original owned lab database,
served briefly at its original private endpoint. The original database was preserved.
A separate identity-gated UI test invoked the normal Reconcile pairing action. The
server confirmed unused expiry; final Watch provenance has neither setup nor scoring
pending, and the backup row is expired with no redemption/credential. Test passed,
server stopped and joined. No Keychain clearing or expiry bypass.

The thermal diagnostic's one existing native transition check passed (one test, no
skips), and the signed phone build-for-testing passed. Watch diagnostic and recovery
builds passed; real inspection and reconciliation tested their opt-in paths.

`physical-paired-live-dB8WXx` is the subsequent paired phone/Watch vertical run, using
the fresh binaries, exact input hashes, normal WatchConnectivity setup and scoring,
real camera, software proxy and both output recordings. Results follow below.

## Phone-side saved setup

The first paired vertical failed before any new Watch offer/scoring. Its recording
cleanup completed and the lab joined. Screen recording shows “Watch is ready for
setup” plus the saved-request controls; the test incorrectly diagnosed absent
`phoneWatch.connect.0` as missing identity. WatchConnectivity identity delivery was
working. Do not repeat discovery/radio debugging for this failure.

Added nonsecret DEBUG identity metadata on the phone's existing saved-request reset
button and a separate opt-in exact-identity recovery UI test. It first verifies no
active capture, relaunches the installed build, and refuses a different saved request.
`phone-watch-reconcile-20260929` passes: the phone request exactly matched the already
expired/unused old pairing and normal Start a new setup request cleared it. No
Watch credentials or scoring actions were reset. Signed phone build passed.

The failed paired run's quality journal records360p followed by transport pressure:
70ms sender buffer against60ms (half the120ms negotiated delay), zero transport
drops. This is a different trigger from the first recovery run. The journal lacks
new raw thermal fields, so it does not verify the diagnostic instrumentation on
the still-running physical app. The guarded phone recovery now explicitly relaunched
the installed binary after checking capture idle.

Fresh paired run `physical-paired-live-LlJlWn` follows this concrete state repair.

## Final physical paired acceptance

`physical-paired-live-LlJlWn/vertical-acceptance.json` records the completed pass.
Both named physical UI tests pass; real WatchConnectivity setup, Watch takeover,
home point, undo, away point and match end are observed on the recording phone.
The clean recording continues after remote match end/stream stop and exports.
All owned test/lab/server/media-analysis processes are joined; lab shutdown has
no failures. No unchanged simulator regression or full-match soak was repeated.

Saved-media verification fully decodes all three H264/AAC MP4s. Clean archive:
1920×1080,3829frames/127.637s, maximum35ms video gap; both live files3283frames,
maximum34ms gap. No audio gaps over5ms. Track ends differ by at most71.622ms,
within the existing100ms gate. Visual samples in each output show1–0 at65s and
0–1 at100s. The clean archive has no added Scorebug overlay.

This is a short physical functional pass at240p upload, upscaled to the1080p proxy
canvas. Its transition journal is empty; the live point checkpoint reports a
measured candidate rejected for `capacityHeadroom`. It does not qualify physical
adaptive recovery, sustained higher upload profiles, perceptual sync, fresh-motion
loss thresholds, cellular/paired-fallback handoffs or a full match. The earlier
360p confirmation failure remains open. Keep the original result's mediaQualified
flag unchanged; the separate acceptance names exactly what was independently checked.

Final review tightened the phone recovery test to require a visible idle Start
control before relaunch, rather than relying on absent Stop controls while the UI
loads. The signed build-for-testing passed after this test-only guard change; no
repeat capture or attempt to re-clear the already-reconciled setup was needed.
