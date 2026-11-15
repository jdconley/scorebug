# Paired Watch and ordinary progressive vertical

> Use superpowers:subagent-driven-development with specification then quality review. Autonomous implementation/testing is authorized by the ongoing delivery goal.

**Goal:** Qualify real paired-simulator WatchConnectivity setup and native Watch scoring while the ordinary phone route records clean A/V and progressively streams through the proxy to both scored MP4 outputs.

**Current status:** Harness implementation passes 33 focused tests, both Debug UI builds and independent specification/quality reviews. The combined run reaches 360p and preserves recording/export, but Watch setup fails: the simulator reports its companion missing (WCError 7018), including on immediate messaging, despite installed bundles and an active pair. No Watch pairing or scoring command occurs. Physical phone build/install passes; Xcode cannot establish the physical Watch developer connection. Prioritize physical paired acceptance; any further simulator attempt needs a concrete registration change or isolated framework reproducer. See [registration evidence and Apple guidance](../../research/2026-09-25-watch-companion-registration.md). Do not download runtimes or alter unrelated simulators.

## Design

Add an explicit paired lane to the ordinary launcher, preserving its default phone-only behavior. Reuse the established owned pair creation/pairing, ordered installation and concurrent XCTest lifecycle from `test-paired-watch.mjs`; retain normal device lab, private credentials, environment sanitization, source hash/staging and production publishing factories. Build both apps/tests before capture. Create and clean up only this run's pair. Fail if required installed runtimes/device types are unavailable.

Add a simulator-only opt-in test invoking the common vertical with Watch scoring and ordinary source injection. Keep the physical test's simulator skip. Require the same acknowledged 240p startup and 360p/600000 measured increase before offering Watch setup; merely combining current flags would skip the increase branch. Preserve the 150-second increase gate and existing production timing. Retain failed gates and artifacts, with best-effort stop/export on failure.

Use real Watch identity advertisement, phone offer, Watch redemption, takeover, HOME point, undo, AWAY point and match end. Never inject Watch setup, credentials or a fixture identity. Bound the Watch offer wait to accommodate the phone's setup and adaptive gate; use an explicitly named paired-simulator test allowance, leaving unrelated/physical behavior unchanged. Retain the first-point hold so the phone observes scoring while recording/publishing are active. Ensure a bounded final-AWAY hold provides an observable scored output before ending the match. No automatic retaps.

Require both XCTest results to contain the intended executed test with no skips. Verify durable command history proves accepted Watch operations and actual start/stop broadcast transitions; account for the phone's initial takeover and actual broadcast generations instead of archive-only assumptions. Retain route diagnostics, but do not claim every command used relay merely because setup traversed WatchConnectivity.

Join both test processes and the lab on every exit path. Preserve phone/Watch results, app data, logs, database and completed media before deleting owned pair/devices. Keep cleanup errors visible and do not mask a failed test with successful export. Do not run heavy offline analysis alongside live media. The existing 390-second source is finite; do not silently loop/freeze it or extend the adaptive gate to fit a failing test.

Independently check actual native export and both live MP4s: full A/V decode, source identities, at least 24 fresh fps in each complete second, audio timestamps/waveform alignment, clean archive, archive continuation and visible Watch score changes. Use observed phase timing and matching 0–0/1–0/0–1 templates; the phone-only final 1–0 assumption is invalid here. UI success alone leaves media qualification false.

## Tasks

- [x] Implement explicit paired options/lifecycle and focused option/environment/process-cleanup tests, preserving phone-only defaults and secret handling.
- [x] Add the opted-in simulator phone/Watch test gates and durable command/result assertions. Build both schemes on installed runtimes.
- [x] Resolve independent specification and quality review; commit only intended harness/test changes.
- [ ] Run the combined native paired lane; inspect setup, adaptive, Watch command and archive/export evidence. Preserve failures and diagnose before retrying.
- [ ] Independently qualify all three outputs and Watch score phases. Update the current delivery status and session log without claiming hardware or fault recovery.

This lane cannot qualify physical camera capture, radio switching, background Watch delivery, thermals, congestion recovery, sustained matches or remote worker portability. Those remain explicit delivery gates.
