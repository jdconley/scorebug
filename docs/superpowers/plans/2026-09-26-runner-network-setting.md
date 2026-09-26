# Physical runner network-setting diagnostic

> Execute with superpowers:subagent-driven-development. Existing authorization covers autonomous physical-device diagnostics; no additional product design decision is needed.

**Goal:** Identify the physical UI runner's Local Network Settings state so actual-phone adaptive recovery can proceed without guessing at the existing `localNetworkDenied` result.

**Architecture:** One opt-in hardware XCTest in the existing PhysicalStreamingTests class. It checks idle capture, navigates ordinary Settings UI, reads only the exact ScorebugAppUITests-Runner entry, attaches a small scalar report, and restores Scorebug foreground. No setting changes, network requests, camera start, privacy reset or app deletion. UI automation itself is the measurement; source-text mirror tests would not establish device behavior.

**Alternatives:** Repeating the network probe supplies no new cause while permission is unchanged. Mirroring is currently unavailable while the phone is in use. Moving controller orchestration out of the runner is a larger possible fallback, not needed before checking the actual setting.

## Tasks and acceptance

- [ ] Add `testPhysicalRunnerNetworkSetting` guarded by exact `SCOREBUG_PHYSICAL_NETWORK_SETTING=1`, hardware-only and exact expected runner bundle ID. Default execution skips.
- [ ] Preserve existing capture: activate Scorebug, dismiss only its existing setup sheet if needed, select Film and refuse if recording/streaming active. Use a finite total allowance and bounded navigation. Do not open Settings until this guard passes.
- [ ] Navigate using normal accessibility elements to Settings → Privacy & Security → Local Network. Read only the exact runner entry, never the Scorebug app's permission. Allow only known navigation labels and a bounded number of scrolls. Never tap a switch or approve prompts.
- [ ] Emit small JSON with phase, exact target identifier, entry-found flag and normalized on/off/unknown value. No screenshots, whole UI dumps, installed-app lists, arbitrary Settings strings, credential data or automatic failure screenshots from explicit test code. A bounded unsuccessful search must remain inconclusive, not permission denied.
- [ ] Always restore Scorebug foreground after visiting Settings. Build current signed phone bundle, review exact source, then run only this XCTest using a private test configuration with the explicit flag. No lab or camera needed.
- [ ] Inspect the exact result and attachment. If disabled, normal user setting change remains pending; if enabled/missing, diagnose that result before repeating full recovery. Record evidence in this session's log and update current handoff.

Validation commands use Xcode26.2 with team B222J9J7B8, existing PhysicalPhone derived data and device00008140-001474110C13001C. Root owns build/run configuration and device execution; implementer must not launch hardware or edit other sources.
