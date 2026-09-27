# Evening physical-device resume — September 26

User explicitly requested continuing. Started from clean `095ed51`. This begins a fresh resumed blocker audit; do not reuse the prior blocked-turn count. Goal is still incomplete. The initial probe used unchanged application code; bridge implementation follows below.

The Mac's current en0 address is10.0.0.122. The previous192.168.1.130 bind is no longer assigned; the launcher's validation correctly refused it before allocating a lab. Current physical iPhone lockState succeeds and reports unlocked.

Ran `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-physical-recovery.mjs --device 00008140-001474110C13001C --host 10.0.0.122 --lane network-probe`.

- Signed phone build passes. Artifact `physical-recovery-AeMjLt`, lab `device-lab-3mCm0Y`, source095ed51.
- The exact physical network-probe XCTest actually executes (8.242s); UI automation is working on this phone. Both HTTP requests fail before an HTTP response with NSURLError-1009, CFStream domain1/code50. Bounded NWConnection explicitly reports `unsatisfiedReason:localNetworkDenied`, then cancellation joins.
- Attachment `5AC3308C-A54F-40B3-BCD9-6AAB194F8EC6.json` holds the diagnosis. No inference about the Settings switch itself is possible; user was asked whether it is now enabled, already enabled, or absent.
- Root process53615 joins exit1. No camera or fault phases ran. Lab shutdown reports worker exit0, receiver closed with zero sessions and no cleanup failures. All17 recorded execution inputs were independently rehashed unchanged after joining.
- Fresh Watch lockState query45300 joins exit1 with Network.NWError54, connection reset by peer. No lock-state result was obtained; do not call the Watch locked or restart the paired test on this evidence.

Next: after a reported permission change, rerun this short probe using the currently assigned LAN address. Only after both HTTP checks pass should the physical720 recovery lane start. A missing/already-enabled runner entry needs targeted diagnosis; do not repeat the failed Settings automation unchanged. Paired Watch acceptance still needs a stable developer connection and successful automation initialization. Existing artifact-only paired launchers hardcode the previous LAN address and need current configuration before reuse.

## Enabled switch and supported alternative

User confirms ScorebugAppUITests-Runner already has Local Network enabled. A fresh installed-app query matches `live.scorebug.app.uitests.xctrunner` exactly (`installed-runner.json` in the probe artifacts). Do not keep treating this as a missing user permission.

Apple DTS [thread817792](https://developer.apple.com/forums/thread/817792) describes similar failures beginning with iOS26.3 and recommends a loopback listener in the app under test, using the app's granted network access. This is a supported architecture to test, not proof of an identical OS cause. Research and bounded DEBUG-only implementation plan were committed as82482fd. Implementation is in progress with focused tests and independent review before any hardware attempt. The original recovery mutation clocks, receipts and acceptance gates remain authoritative.

## Bridge implementation and local verification

Implemented fixed-route Debug-only app loopback control with strict canonical configuration/authenticated bounded HTTP, finite upstream requests, joined stop receipt and listener-refusal verification. Launcher opts in with `--runner-transport app-loopback --bridge-port 49173`; direct mode remains the default. The phone test proves no existing recording/publication before relaunching with bridge-only environment. Generated bridge errors are distinguished from actual upstream responses. Existing mutation timing/freshness/sequence checks remain unchanged.

Focused run passes51 Node tests, including the Swift harness's14 XCTest cases. Tests cover malformed configuration/framing/auth/routes, body/response limits, actual forwarding, timeout, expiry, port collision and active-request cancellation. Logs and joined process records are under `artifacts/qa/physical-loopback-validation-20260926/`. Syntax and whitespace checks pass.

Initial signed Debug build41113 and actual arm64 iPhone Release build89190 both joined0. `release-exclusion.json` records matching positive Debug / negative Release checks for bridge symbols, activation key and fixed route, plus actual binary hashes. The existing UI network diagnostic has an exhaustive-switch warning for the SDK's newer vpnInactive case; app-intents metadata warnings also remain. No bridge compile error occurred.

Independent specification review found one missing post-relaunch idle condition; corrected by repeating enabled start and both absent stop buttons. Final UI blobd09d84f098f5a712959f6c9f7a72414f4ebbbc4f is spec-approved. Final signed Debug rebuild and independent quality review follow before hardware.

Final signed Debug rebuild26131 joined0. Independent quality review approves all11 implementation/test/project blobs with no actionable blocker. Root verifies success markers and stores final source hashes plus log/binary checks in `root-verification.json` and `final-review-inputs.json`. Hardware probe is next; no capture acceptance is implied by these checks.

## Physical loopback probe passes

Sourceb639c81; command `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-physical-recovery.mjs --device 00008140-001474110C13001C --host 10.0.0.122 --lane network-probe --runner-transport app-loopback --bridge-port 49173`. Root87776 joined0. Artifact `physical-recovery-ymge6q`, lab `device-lab-urQgMy`. Exact probe leaf passes13.428s, zero skips.

Both APIroot and controllerroot return actual forwarded404 responses; the controller matches its expected unknown-operation body. Bridge shutdown is acknowledged and subsequent connection refusal verifies the listener closed. AttachmentB1D1DC36-6BC2-4EFF-9DDA-0B4E9536EFC3.json and separate shutdown attachment preserve the evidence. Root independently rehashes all25 listed runtime/config/source inputs unchanged. Controller audit is closed with zero records; receiver has zero sessions; worker exits0 and shutdown has no failures. This establishes app-mediated test connectivity, not restored direct runner privilege or media qualification.

Next is the physical720 ramp/collapse/recovery comparison. The user has been asked to provide a lit moving scene; no response yet. A new controlled hardware timing run can still diagnose application/transport behavior, but cannot establish fresh-motion or perceptual sync if the scene remains dark/static. No media gate will be relaxed.
