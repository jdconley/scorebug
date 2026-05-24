# Scorebug iOS

Native iPhone app. Captures 1080p from the rear camera, forks every sample buffer:

1. **Stream** — encode H.264, publish via SRT to the VPS (HaishinKit).
2. **Archive** — write a fragmented MP4 to the app's Documents directory, never re-encoded. Crash-safe via `movieFragmentInterval`.

## Generate the Xcode project

```sh
brew install xcodegen
cd ios
xcodegen generate
open Scorebug.xcodeproj
```

The `.xcodeproj` is gitignored — regenerate it from `Project.yml` whenever you pull.

## First run

1. Settings (gear icon) → set **Control plane URL** (`https://api.scorebug.live`) and paste the **phone bearer token** from the VPS `.env`. Token persists in the iOS Keychain.
2. Fill in team names + paste a fresh YouTube stream key.
3. Tap **Start Game**:
   - `POST /games/start` to the control plane → receive `{ host, port, streamId, passphrase }`.
   - Connect SRT and begin publishing.
   - `AVAssetWriter` starts recording the full-resolution archive locally.
4. **End Game** stops publishing and finalizes the archive. Find it in Files app → "On My iPhone" → Scorebug → archives.

## Known TODOs

- **HaishinKit 2.x API verification:** `CameraSession.swift` makes best-effort calls against HaishinKit 2.0.x. If the version SPM resolves has different method signatures (`stream.publish` vs `stream.publish(nil)`, `attachCamera` vs `attachVideo`, etc.), adjust to match. Search for `TODO(HaishinKit 2.x)`.
- **Sample-buffer fan-out to SRT stream:** depending on whether HaishinKit's SRTStream pulls samples directly via `attachCamera` / `attachAudio` or accepts manual `append`, the `publishQueue.async` block may need to forward samples. Search for `TODO(HaishinKit 2.x)`.
- **Code signing:** set your dev team in the project settings before running on device.
- **Icon:** the `AppIcon` asset is a stub. Drop a 1024×1024 PNG into `Resources/Assets.xcassets/AppIcon.appiconset/` before shipping to TestFlight.

## Architecture

```
AVCaptureSession ──┬─► [video] ──► fanout ──┬─► ArchiveWriter (passthrough, fragmented MP4)
                   │                        └─► SRTStream (HaishinKit, encoded H.264)
                   └─► [audio] ──► fanout ──┬─► ArchiveWriter
                                            └─► SRTStream (AAC)
```

Both fan-outs run on dedicated serial queues so the publisher slowing down can't drop archive frames and vice-versa.

## Camera permissions

`Info.plist` declares `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`. iOS prompts on first capture attempt; if denied, the camera state shifts to `.error` and the start button stays disabled.

## Why HaishinKit (not stock URLSession or AVFoundation alone)

Stock iOS has no SRT. RTMP would work via AVFoundation but RTMP rides TCP — useless on a hostile venue network. HaishinKit ships an SRT module with caller-mode publish and a sensible bitrate-control API.
