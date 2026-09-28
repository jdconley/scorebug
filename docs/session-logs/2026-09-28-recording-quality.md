# Recording quality and native 4K archive

Starting point: `471401e`, `codex/local-validation`, authoritative checkout
`/Users/jd/.codex/worktrees/scorebug-local-validation`.

The simulator-first batch adds an explicit 1080p/4K recording choice. Source and
archive receive the same immutable profile for each recording; the control locks
through startup, recording and shutdown. Defaults remain 1080p30/12Mbps; 4K uses
3840×2160 at30fps/30Mbps. Both use H264/AAC, mono48kHz audio. Streaming continues
through the separately measured production ladder, currently capped at1080p.
The camera selects the exact requested format and rejects unsupported geometry.
File fixtures likewise reject mismatched dimensions instead of upscaling.

## Verification

- Focused `ScorebugFilmModelTests/FilmModelTests`:10 tests,0 failures,0.073seconds.
  New coverage verifies source/archive profile equality, default quality, switching
  between recordings and locked selection during startup/recording/shutdown.
- Phone plus embedded Watch arm64 simulator build and UI test build pass, using
  the existing `OrdinaryNativeApp` DerivedData. No hardware or broad suite.
- First native UI attempt `artifacts/qa/recording-quality-20260928` stalled waiting
  for the quality menu to become idle, before recording. Screenshot showed the
  menu open. Explicitly terminated owned xcodebuild with SIGTERM (exit-15); runner
  copied available artifacts and removed its owned simulator. This is not a media
  failure or a pass. Replaced the menu with a segmented control for two choices.
- Follow-up native 4K record/export/playback/relaunch passed in36.106seconds in
  `artifacts/qa/recording-quality-20260928-segmented`. The ad-hoc collector retained
  the pre-install app-container path, so media was not copied before simulator
  removal. This run qualifies only UI behavior; that artifact-collection error is
  preserved and does not count as media evidence.
- Corrected collection resolves the current app container after the UI run and
  refuses deletion if successful media is missing. No rebuild was needed. The
  short retry `artifacts/qa/recording-quality-20260928-media` passes UI and media:
  actual3840×2160 H264/AAC,247 consecutive source IDs0–246 at30fps, no audio
  timestamp gaps,21.333ms A/V end offset. Joined source/archive diagnostics match
  all247frames and295audio buffers, with no queue rejection/drop or writer failure.
  The source delivers approximately30fps with maximum2.318ms source lag. See
  `media-acceptance.json` and `archive-source-acceptance.json` for exact evidence.
- All jobs joined; owned simulators removed. Existing24MiB archive mailbox suffices
  for this8.2second test; sustained simultaneous recording/upload remains unqualified.
  No mailbox or streaming-probe budgets were enlarged in this batch.

The prepared input is the existing120second4K SDR derivative of the owner's
volleyball match, `match-footage-n6n1f13m/long-replay/4k-source.mov`. Originals in
Downloads are unchanged. Earlier console-harness4K results do not qualify this
new app path. Sustained capture, physical camera and4K adaptive upload remain
separate gates; no4K streaming claim is made.
