# Current signed device build — September 28

Starting6ebcf36, clean checkout. Prior turn made progress: current simulator crash
regression and all six output A/V tails pass. Hardware readiness reply remains
pending; no device polling or automation was performed.

Prepared the current real-device binary once using existing incremental
`ios/DerivedData/PhysicalPhone`, Xcode26.2, generic iOS destination, Debug,
teamB222J9J7B8 and build-for-testing. Scorebug's target embeds ScorebugWatch, so the
phone and Watch apps build together. Command47625 exited0, TEST BUILD SUCCEEDED.
No XCTest was executed. No production code changed.

Preserved signed bundle and logs at
`artifacts/qa/device-build-current-el0CCp/Scorebug.app`.
`readiness.json` binds producing6ebcf36, executable SHA256 values, app IDs and
profile facts. Deep/strict codesign verification passed. Both profiles use the
requested team, include the known iPhone16Pro/Ultra2 IDs, and expire2027-09-25.
Deployment minima remain iOS17/watchOS10. This proves signed artifact readiness,
not installation, camera behavior, companion transport or physical qualification.
The archived bundle is not affected by later incremental rebuilds.

All commands terminal, no apps installed/launched, no credentials or recordings
changed. Wait for the existing readiness reply; do not repeat it. Next physical
work can reuse this build and the retained simulator passes. Do not rerun simulator
suites merely because the destination changes.
