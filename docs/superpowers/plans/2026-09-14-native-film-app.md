# Native filming app integration plan

> **For agentic workers:** Use superpowers:subagent-driven-development for implementation and separate spec/quality reviews.

**Goal:** Record offline through the native app, retain native scoring on the same or another phone, and recover/export recordings after relaunch.

**Architecture:** The app owns one filming model independently of its native scoring model. Film, Score, and Recordings tabs keep capture alive across role changes. A library owns recording directories and completion metadata; the existing segmented archive remains authoritative for recovery. Simulator injects a timed NV12/PCM source into the same capture owner. Device capture uses the reviewed iPhone adapter.

**Tech stack:** SwiftUI, AVFoundation, ScorebugCore, ScorebugMedia, XcodeGen, XCTest/XCUITest, local Simulator and FFmpeg validation.

- [x] Implement and unit-test filming state, exclusive recording ownership, failure handling, and off-main recording library scan/export. Distinguish completed, recoverable, and unavailable media; retain originals.
- [x] Replace the obsolete camera scaffold with Film/Score/Recordings views. Reuse the native scorer; camera permissions occur only after Record. Display local recording state truthfully, with no unimplemented LIVE indicator.
- [x] Add a bounded, timed Simulator source and real-media fixture test. No per-frame tasks; source stop joins its pump.
- [x] Exercise Score without camera permission, offline Record/Stop/Export/Playback, relaunch, and forced-termination recovery through XCUITest. Decode exported MP4s and inspect screenshots.
- [x] Build ARM64 iPhone and Simulator with iOS 17 deployment; run the app workflow on iOS 17.5, 18.5, and 26.2 where installed. Preserve separate native scoring regression coverage.
- [x] Review, document measured behavior and remaining device limits, and commit the checkpoint.

Production live publishing, adaptive quality, Watch networking/UI, physical camera qualification, and other-host workers retain their existing milestones. This integration must not claim those are complete.
