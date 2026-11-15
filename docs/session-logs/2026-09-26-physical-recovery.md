# Physical camera recovery and paired scoring — September 26

## Implementation checkpoint

Source `2bdcd60` adds the explicitly enabled physical camera recovery lane. The ordinary controller and UDP frontend can bind only an assigned canonical RFC1918 host; default simulator routing remains loopback. The controller keeps its bearer/run/sequence checks and bounded mutation contract. The physical UI test resolves local-network permission with an authenticated nonmutating preflight before recording, preserves recovery failures through stop/export, and records the actual new recording UUID.

The launcher performs a signed build, checks phone lock state, uses a private configured xctestrun, hashes the actual Debug implementation and test executables before/after execution, requires the exact non-skipped test, and joins lab shutdown before workflow success. It never declares media qualification.

Validation: 89 combined ordinary/options/network tests and 7 launcher tests pass; 5 native configuration tests pass; final signed phone build-for-testing passes. Independent review approved exact runtime, Swift and launcher blobs for bounded capture. Evidence is under `artifacts/qa/physical-recovery-{network,native,launcher}-validation`. The provenance red test also exposed an accidental test argument insertion; that test-only error was corrected before the final seven-test pass.

## Device attempt

User confirmed the automation prompt approved and both devices ready. The phone subsequently reported `passcodeRequired:false`. Watch connection establishment failed once with a CoreDevice tunnel error and once with a bounded timeout, before any lock-state result; this is connectivity pending, not proof the Watch is locked. A single networking clarification is pending. No paired capture started.

Phone-only recovery started from `2bdcd60`: `artifacts/qa/physical-recovery-OQkGiR`. The signed build passed and the UI test launched, but setup failed at32.6s as orientation changed during scoring.endpoint hittability. No recording started. Command51525 exited1; lab cleanup failures were empty. Failure xcresult, exported attachments and screenshot are retained. Native test setup stabilization is in progress. This is actual camera imagery, not the barcode volleyball fixture; media qualification must use appropriate camera evidence.

## Setup stabilization

Source `3b682f7` sets a physical test's orientation to portrait only after the existing no-capture guard and requires one second of unchanged portrait app geometry within a10-second bound. Normal hit testing, production app code, recovery deadlines and cleanup remain unchanged. Independent review approved UI blob `988b999002afbc3c4242492e33f0dbf05100006d`; signed phone build14155 joined0 and19 ordinary launcher regressions passed. Second phone attempt: `physical-recovery-BD0Vxw`, pending.

## Runner local-network diagnosis

`physical-recovery-BD0Vxw` passed portrait setup and connected both native scorer and Film settings to the current lab. Its runner's authenticated GET to the private recovery controller timed out20s later, before recording. Source `3b682f7`; lab `device-lab-kLMBKF`; command84055 joined1; cleanup failures empty. Native phase evidence contains no recording milestones or controller exchanges; controller audit is closed with no mutations. Retained screen recording shows no network permission prompt and Film still ready to record.

The host controller is bound to the correct private address and Node has an explicit incoming-firewall allow rule. The app itself connects successfully, but the request originates in the separate XCTest runner while Scorebug is foreground. Apple's [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) documents that iOS background apps with undetermined local-network permission are denied without a prompt; the simulator does not model this privacy behavior. This is the leading explanation, not yet a confirmed device fix. The next bounded change foregrounds the test runner only during pre-recording nonmutating preflight, then restores Scorebug. No firewall bypass, privacy reset, app data deletion or production networking change is warranted.

Same-host private-LAN authenticated GET check `physical-preflight-server-Jq6UYy` passed with404/expected body and a closed empty mutation audit; it proves server response behavior, not phone reachability. The reviewed runner foreground delta validates the exact installed runner ID and existing processes, activates it before the finite GET, restores Scorebug with defer on both outcomes, and verifies Scorebug foreground before recording. No privacy reset or production change. Nineteen ordinary launcher regressions pass.

Source `f6dc8bf` foreground-preflight build53274 passed; independent review approved blob816ad7a. Attempt `physical-recovery-IFCArW` visibly triggered a Scorebug runner local-network alert and tapped its exact Allow button at90s, confirming the missing-prompt diagnosis. The original URLSession request nevertheless timed out and no recording started. Command1529 joined1 with no lab cleanup failures. This does not yet prove the permission persisted or that LAN control works. One unchanged-source retry `physical-recovery-N6qxbW` follows this observed permission-state change; no repeat without new evidence after that.

`physical-recovery-N6qxbW` repeated the runner GET timeout without another permission prompt; command18161 joined1, cleanup failures empty, no recording. During the attempt the Mac reached the controller (unauthenticated401) and lsof showed the listener but no established phone connection. Full-lane retries are stopped. A reviewed isolated probe compares runner API/controller GETs with task/error metrics and a bounded TCP fallback; it never records or mutates the recovery phases. Launcher `--lane network-probe` has an explicit flag/test,240s lab bound and120s XCTest/180s command limits. Eight launcher tests pass after an observed unsupported-lane red test.

## Isolated hardware diagnosis

Source `c1fef11`; independently reviewed native probe blobcd4e3c and launcher98d8e3; signed build2335 passed,27 combined ordinary/physical launcher tests passed. Probe `physical-recovery-2UDoQf`, lab `device-lab-JGKeku`, command61505 joined1. The intended hardware method ran and failed its HTTP assertions with useful evidence:

- API root and controller root both completed without an HTTP response in about0.14/0.17s. Each reports NSURLErrorDomain-1009, underlying CFNetwork-1009, CFStream domain1/code50. Neither used a proxy connection.
- TCP probe explicitly reports path unsatisfied / `localNetworkDenied`; cancellation joined after5s.
- Native logs say `Local network prohibited` on Wi-Fi. This establishes a runner privacy denial, not a controller response bug or production streaming failure.
- Controller audit is closed with zero phase mutations. No recording started. Launcher/lab cleanup failures empty. Root manually verified all retained source/binary/configured-xctestrun hashes unchanged after the failed probe, because automatic successful-workflow verification was not reached. Evidence: `network-diagnostic-verification.json` and attachment `7192CF7C-995A-491A-8A95-CDFCB673CAD3.json`.

User was asked to enable ScorebugAppUITests-Runner in iPhone Settings → Privacy & Security → Local Network, or report missing/already enabled. That operational state is pending. Do not retry full capture while runner access is denied. Watch developer connectivity clarification also remains pending. All builds, probes and media-analysis commands in this session are joined; no capture is left running.

Independent result review confirmed both timed HTTP failures, explicit TCP privacy denial, all17 retained input checks, zero controller mutations and zero receiver sessions. No further code change is justified before the runner privilege is resolved.
