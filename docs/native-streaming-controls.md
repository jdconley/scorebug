# Native Film streaming controls

The iPhone Film tab records an offline, clean archive without a server or match. Score remains the existing native scoring tab; switching tabs does not restart capture. Recordings still uses the native local library, recovery/export and AVPlayer flow.

Streaming is an independent optional attachment to an already running recording. Open Film → Streaming → Setup, enter the control server URL, installation token, worker ID and output ID, then save and connect to the active match. Capture joins with role `capture` and a stable device UUID. Start recording, then choose Start streaming. Stop streaming detaches the publisher and leaves the archive running. Stopping recording clears capture identity and cancels publishing before archive shutdown awaits. Backgrounding stops recording through the same path.

## Automatic reconnection

A failed native stream connection retries while the same recording and authorized
broadcast remain active. The app shows “reconnecting” and keeps Stop available.
Retries wait for the old publisher to finish, revalidate server ownership and start
with minimum upload quality. Backoff rises from2seconds to30seconds. Explicit Stop,
recording replacement/end, authorization failure or a changed/stopped broadcast
cancels retries. Local recording continues independently; the live output can have
an outage gap. Physical radio changes and sustained blackholes remain unqualified.

## State and credentials

`FilmModel` publishes `CurrentCapture` (recording ID, stable ISO start time, fresh `PublishingTap`) only after source readiness. It invokes its synchronous lifecycle callback before archive draining on stop. It has no API client or streaming dependency.

`CaptureStreamingModel` owns the client, broadcast coordinator and publisher attachment. It validates the local recording and attempt identity after every suspended startup stage. Control polling is a separate two-second task from archive health polling; local publishing health and worker observation expiry use a separate100ms task. Delayed HTTP requests cannot delay capture failure handling. `PublishingSession` bounds the media queue, monitors publisher health and discards stale queued samples at shutdown.

Capture configuration, its match credential, stable device UUID, recording-report outbox and bounded stop-ownership ledger use the device-only Keychain service `live.scorebug.capture.setup`. They are separate from the scorer's Keychain service. Publish URLs remain in memory inside one publishing attempt and are never added to saved setup, command files, UI messages or diagnostics.

Broadcast commands use `BroadcastCommandCoordinator` and a private `pending-broadcast.json` file. Scope is the canonical endpoint plus a SHA-256 installation-token account digest; each pending record also has the capture device ID and game. Unresolved commands and storage errors prevent setup replacement and remain visible/retryable. Recovery checks receipts before retrying, and never turns a recovered result into camera or publisher startup. Expired commands require a second receipt check before removal. Stops are restricted to recordings owned by this capture device; the coordinator also verifies the selected recording against its freshly fetched generation before submitting a stop.

Recording reports preserve one start time and monotonically increase sequence on status transitions. The Keychain keeps acknowledged live records so relaunch can convert them to higher-sequence `interrupted` reports. Terminal reports are queued after the archive shutdown outcome is known: normal completion reports `stopped`; capture, writer or drain failure reports `interrupted`. Terminal reports are retried until acknowledged. A separate ledger reserves up to 64 recording IDs before broadcast startup and retains ownership after report acknowledgment until safe server reconciliation; a full ledger blocks additional streaming attempts without evicting unresolved ownership. No historical live report is replayed when that capture is no longer running. Relaunch never starts camera capture or publishing automatically.

## What status means

“Camera publishing: sending media” means the local publisher is running. It does not assert viewer delivery. Worker producing-output status is a separate server observation with a short, monotonic freshness deadline; late responses after local stop are ignored. Expired observations become stale. API errors, local publisher failures and changed/ended remote selections stop publishing while the local recording continues. Pending command reconciliation is visible independently of publisher state.

## Validation

The `ScorebugFilmModelTests` target includes the original offline library/capture tests, capture lifecycle tests, and injected-client/publisher tests for offline operation, start/stop independence, delayed join/access/publisher startup, network failures, receipt recovery, storage failure/retry, setup device identity, stopping another device's selection, stale worker replies and report sequencing/relaunch.

Run with Xcode 26.2:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcodegen generate --spec ios/Project.yml
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination 'platform=macOS' test
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -destination 'generic/platform=iOS Simulator' ARCHS=arm64 build
```

The vendored SRT binary's Intel Simulator slice has unresolved SRT symbols; use ARM64 simulator qualification. A physical iPhone remains necessary for camera permission, interruption, storage pressure, thermal behavior and long-running radio validation. Development qualification uses the local API, local ingest and local worker sink; no external broadcast is required.

Debug simulator video preserves the 16-bit frame barcode. Audio carries 200 ms bursts every two seconds, with frequency `1000 + 20 * floor(time / 2)` Hz, to measure archive/live audio-video alignment.
