# Measure negotiated SRT sender delivery delay

Execute inline under the autonomous portable streaming/Watch goal. Previous turn
made verified progress: actual statistics cadence is 255 ms, trial rollback is
1.70 seconds and worst native receiver window improves to 15.2 fps, still failed.

**Design:** Carry libSRT `msSndTsbPdDelay` from each successful timestamped native
collection into `PublishingTransportStatistics.senderDeliveryDelayMilliseconds`
and the same raw quality-evidence sample. Preserve nil for unavailable/legacy data,
zero as an actual zero value, and reject negative values. This is an instantaneous
observed gauge, not a latency configuration, delivery receipt or capacity estimate.
No policy, thresholds, connection options or media gates change. Version-three
quality evidence gains an optional diagnostic field; old evidence stays readable.
The independent raw-pressure verifier validates the optional scalar's native Int32
range but does not use it to infer network health.

Alternatives: querying a socket option separately would add another actor read
and separate collection instant; inferring delay from defaults cannot prove the
negotiated value. Reuse the already-collected scalar to preserve exact provenance.

- [x] Add model tests for known/unknown/zero/negative delay and immutable history;
      add exporter tests proving the delay stays attached to its actual sample.
      Add verifier negative tests rejecting malformed optional values. Reproduce
      the missing field/validation before implementation.
- [x] Map the native scalar, retain it in bounded history, and export/validate it.
      Run media, streaming, app-model and tooling tests plus unsigned Apple build.
- [x] Repeat the unchanged 240-second rate4m native fixture. Verify archive, actual
      native delay/cadence/pressure timing and live media without weakened gates.
- [x] Record measured delay versus observed buildup before choosing a separate
      latency or threshold change. Hash terminal evidence and commit; leave full
      adaptation, physical devices, long soaks and other hosts open.

Files: `ios/Packages/ScorebugMedia/Sources/ScorebugMedia/PublishingTransportStatistics.swift`,
its existing tests, `ios/Packages/ScorebugStreaming/Sources/ScorebugStreaming/SRTPublisher.swift`,
`ios/Sources/Scorebug/Capture/PublishingQualityDriver.swift` and its tests,
`scripts/native-quality-pressure.mjs` and the existing qualification test file.
No SDK patch change is required: its native wrapper already carries this scalar.

Validation uses Xcode 26.2 (26.6 remains unlicensed): `swift test --package-path
ios/Packages/ScorebugMedia`, `swift test --package-path ios/Packages/ScorebugStreaming`,
`xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination
'platform=macOS' test`, `pnpm test:tools`, the existing unsigned combined Apple Release
build and exactly the preceding native adaptive rate4m command.

## Verified checkpoint

Causal model/export tests fail before retention/serialization, and five malformed
verifier values fail before optional-field validation. Final checks pass: 187
XCTest plus 66 Swift Testing media tests, 61 streaming tests, 204 app-model tests,
968 tooling tests and the unsigned combined iPhone/Watch Release build. The first
incremental streaming link reused an object referencing the old initializer; an
owned package clean/rebuild resolves it without another source change. Read-only
review reports no blockers. No transport/policy setting changes in this checkpoint.

The unchanged run `native-app-HUreDi` completes the UI workflow. All 998 distinct
retained native collections report an actual sender delivery delay of 120 ms.
Sampling remains 255.49 ms median (265.48 ms p90; 266.89 ms maximum). At bootstrap
+60.046 seconds, RTT first exceeds that delay (159.893 ms). The retained sample at
+60.549 has a 173 ms sender buffer; pressure evaluates at +60.837 after
retransmissions appear, and the lower profile acknowledges at about +61.32.
These comparisons are diagnostics, not proof of a specific receiver discard.

Seven one-second local pressure windows independently replay and all four native
profile changes have matching bounded receipts. The 41 accepted receiver windows
are already 1.758–1.986 seconds old at evaluation (median 1.824), close to the
existing two-second freshness cap. Increasing transport latency without checking
this budget would risk making those windows inadmissible.

The archive independently passes: all 8105 consecutive 1080p/30 frames over
270.167 seconds, all 134 matched A/V markers, 18.67 ms end coverage difference,
and no rejected/dropped archive samples. Native publishing retains 7767 consecutive
source identities across five phases. The acquired live recording contains 7577
frames spanning 7707 source positions: 130-frame count deficit (1.687%) plus 48
non-increasing barcodes. Count deficit is not complete source-identity loss.

Full live qualification remains failed: -123.9 ms A/V end discrepancy, monotonic
source identity failure and a worst five-second receiver window at 14.2 fps.
Audio PTS gaps total 128.78 ms (maximum 43.20 ms). The pressure schedule passes;
the single SRT reader recovers initial timing damage and ends at normal stop.
Archive success and controller confirmation do not establish live-media success.

The owned runner and analysis are terminal/joined, container/simulator are absent,
and collector is stopped. Exact source snapshot, stopped QA, fixed-category ingest
diagnostics, independent analysis and cleanup remain under the run directory.
Terminal hashes: `artifacts/qa/negotiated-delay-final-verification.json`.

## Next design: downward response within the transport recovery budget

The preceding fixes each resolve their tested subproblem, but full live delivery
still fails. Step back from isolated numeric tuning: the local post-ack observation
minimum is one second, a geometry change takes about another half second, and this
connection's actual delivery delay is 120 ms. Receiver freshness is independently
close to its two-second cap. These constraints need a coherent downward response.

Preserve all source/receiver health durations and upward probation rules. Investigate
a shorter, explicitly downward-only local observation path, with strict actual
sample bracketing, post-ack ownership, nonoverlap, raw pressure replay and missing
receiver/capacity evidence. Compare current RTT with a conservative fraction of the
measured sender delivery delay (bounded by caller limits); missing/zero delay must
not invent a healthy recovery budget. Do not allow short windows to authorize
increases or rewrite legacy version-three evidence. Reproduce the post-ack timing
problem and the recovery-budget mismatch independently before implementing the
cohesive policy and a separately versioned replay contract.

Do not assume a fast bitrate write solves this simulator case: the earlier native
payload experiments already show that requested 1.5 Mbps can still emit 5.576 Mbps
at 1080p; 720p was worse for this exact fixture, and low-latency encoder creation
was unsupported. Retain the real profile-transition stress test. A deliberate
latency change would require a separate treatment of the bounded receiver-evidence
age, not simply relaxing the media/frame/cadence gates. Any production/default
policy still requires successful end-to-end pressure, device and host qualification.
