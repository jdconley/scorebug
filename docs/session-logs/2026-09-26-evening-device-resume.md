# Evening physical-device resume — September 26

User explicitly requested continuing. Started from clean `095ed51`. This begins a fresh resumed blocker audit; do not reuse the prior blocked-turn count. Goal is still incomplete. No application code changed.

The Mac's current en0 address is10.0.0.122. The previous192.168.1.130 bind is no longer assigned; the launcher's validation correctly refused it before allocating a lab. Current physical iPhone lockState succeeds and reports unlocked.

Ran `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-physical-recovery.mjs --device 00008140-001474110C13001C --host 10.0.0.122 --lane network-probe`.

- Signed phone build passes. Artifact `physical-recovery-AeMjLt`, lab `device-lab-3mCm0Y`, source095ed51.
- The exact physical network-probe XCTest actually executes (8.242s); UI automation is working on this phone. Both HTTP requests fail before an HTTP response with NSURLError-1009, CFStream domain1/code50. Bounded NWConnection explicitly reports `unsatisfiedReason:localNetworkDenied`, then cancellation joins.
- Attachment `5AC3308C-A54F-40B3-BCD9-6AAB194F8EC6.json` holds the diagnosis. No inference about the Settings switch itself is possible; user was asked whether it is now enabled, already enabled, or absent.
- Root process53615 joins exit1. No camera or fault phases ran. Lab shutdown reports worker exit0, receiver closed with zero sessions and no cleanup failures. All17 recorded execution inputs were independently rehashed unchanged after joining.
- Fresh Watch lockState query45300 joins exit1 with Network.NWError54, connection reset by peer. No lock-state result was obtained; do not call the Watch locked or restart the paired test on this evidence.

Next: after a reported permission change, rerun this short probe using the currently assigned LAN address. Only after both HTTP checks pass should the physical720 recovery lane start. A missing/already-enabled runner entry needs targeted diagnosis; do not repeat the failed Settings automation unchanged. Paired Watch acceptance still needs a stable developer connection and successful automation initialization. Existing artifact-only paired launchers hardcode the previous LAN address and need current configuration before reuse.
