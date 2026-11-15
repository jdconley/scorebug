# Physical recovery loopback bridge

> Execute with superpowers:subagent-driven-development under existing autonomous implementation/test authorization.

**Goal:** Run the real-phone adaptive recovery test despite the XCTest runner's confirmed local-network denial, using the app's legitimately granted network access and Apple's recommended loopback approach.

**Evidence:** User confirms the runner switch is enabled; the exact installed runner still reports localNetworkDenied. See [research](../../research/2026-09-26-xctest-local-network.md). Simulator/publication/control policies are unchanged.

**Architecture:** An explicit DEBUG-only HTTP bridge in the normal filming app, bound only to127.0.0.1. Fixed per-run API/controller destinations, same canonical RFC1918 host, no discovery or arbitrary forwarding. The runner uses loopback while Scorebug stays foreground. The app starts with bridge configuration only after XCTest proves no existing recording/publication. A dedicated authenticated stop operation closes the listener and active work without terminating Scorebug or affecting recording.

## Protocol and invariants

- Random64-lowercase-hex bearer token, explicit high loopback port and run ID from private runner configuration. Reject partial/invalid configuration before opening any listener. Every bridge route requires the token, including API health and shutdown.
- Allow only GET `/` to the fixed controller root, GET `/api-health` to the fixed API root, POST `/constrain` and `/restore` to the existing controller, and POST `/stop` for local teardown. Forward existing controller bodies unchanged; do not manufacture success receipts. No redirects, retries, CONNECT, absolute-form URLs, arbitrary headers/targets, chunked or pipelined requests.
- Bound header/body/response sizes and concurrent requests. Maximum body8192bytes, upstream response4096bytes, bounded request deadlines and900-second maximum bridge lifetime. One request per connection, close after response. Do not log credentials or payloads. Bind collision is a failed preflight.
- Keep original mutation clock brackets, freshness checks, run/sequence validation and no-retry behavior. Mark bridge transport in evidence so it cannot be confused with direct runner access.
- Guard app relaunch with actual idle capture state; preserve saved recordings. Explicit stop must work independently of recording cleanup and report failure if shutdown cannot be verified. No broad app termination to clean up the bridge.
- Release compilation excludes bridge networking and activation entirely. Debug without explicit environment behaves identically to normal app.

## Work and verification

- [x] Implement isolated bridge/config/parser with meaningful malformed/auth/size/route and lifecycle tests. Use existing Swift mini-harness conventions or a focused package test; avoid source-text-only proof.
- [x] Integrate Debug-only app ownership and explicit physical-test startup/teardown. No fixture media or quality factory selection. Route both short probe HTTP requests through the bridge and preserve the direct probe option for diagnosis.
- [x] Add opt-in physical launcher configuration and regression tests covering default unchanged, private destination validation, explicit port/token, source/binary/config hashes, and exact leaf selection. Preserve ordinary simulator behavior.
- [x] Run focused tests, signed Debug phone build and Release exclusion/build checks; review exact final code for spec and quality.
- [x] Run the bridge network probe on the unlocked phone/current LAN; inspect actual upstream results and zero mutation audit. Verify listener shutdown and unchanged runtime inputs.
- [ ] Only after probe success run physical720 recovery, then collect the actual new archive and both live MP4s. Preserve independent workflow, transport and media results; no automatic acceptance from a green bridge test.

Root owns hardware runs and source freezing. Join all builds/reviews before capture. No privacy resets, helper app identity tricks, external service purchases or Watch changes.
