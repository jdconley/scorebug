# Incremental delivery reporting implementation plan

> Execute inline using the existing approved portable-streaming design, TDD and independent review. Autonomous implementation is authorized by the user.

**Goal:** Carry bounded decoder arrival history through the authenticated worker/API path without retransmitting the entire ring on every update.

**Architecture:** A versioned packet carries scope-relative monotonic sample/coverage times, consecutive ordinal bounds and `[PTS, arrival time]` tuples. Full packets contain at most 256 entries. A cursor omits already acknowledged entries; receivers validate overlap and reconstruct the bounded tail. Scope-relative times are compared only within that scope, never with a phone epoch. Worker capabilities and read identity gate reporting. Server attempt/assignment ownership and timing tokens gate freshness. Native status consumers explicitly opt in and supply their cursor; legacy status responses omit this extension.

**Tradeoff:** Self-contained repeated snapshots simplify consumers but cost about 1.16 Mbps at 10 Hz in the prior fixture. Compressed full snapshots still repeatedly transmit unchanged history. Cursor deltas reduce the steady-state payload while bounded full snapshots recover after restart or history retirement. Lost acknowledgements safely cause overlap retransmission.

**Files:** `packages/protocol/src/decoder-delivery-report.ts` owns packet validation, delta creation and reconstruction; its tests live in `packages/protocol/test/decoder-delivery-report.test.mjs`. The worker's `decoder-delivery.ts` produces stable relative times; pipeline/supervisor carry current observations; reporter advances a cursor only after success and resets on session renewal. `worker-observations.ts` binds history/freshness to each active attempt. Media/publication status routes negotiate query parameters. Add focused worker and API integration tests.

- [x] Add failing protocol tests for full/delta reconstruction, acknowledged overlap, retirement, gaps, changed identities/times, invalid clocks, scope, sticky end/failure, malformed bounds and payload size. Run `pnpm --filter @scorebug/protocol test` before implementation.
- [x] Implement strict bounded protocol helpers and rerun protocol tests. Packet fields are version, scope, sampledAtMs, coverageAtMs, afterOrdinal, lastOrdinal, tuples, invalidReason and ended. Full coverage begins after ordinal max(0,lastOrdinal-256); partial packets require existing history for omitted entries.
- [x] Add failing worker tests for stable relative time sampling, capability downgrade, lost acknowledgement and renewed sessions. Implement current snapshot propagation and acknowledged cursors; run worker tests/typecheck.
- [x] Add API tests for authenticated ingestion, current-attempt binding, omissions, anti-replay, timing provenance, opted-in cursor status and legacy omission. Implement negotiated version, schema, history and server sample-age bounds; run API tests/typecheck.
- [x] Exercise actual FFmpeg data through delta reconstruction and real HTTP worker reporting. Verify exact PTS/ordinals/coverage and record payload bytes, reset/resync and process exits. No phone-to-worker latency claim until native source binding is implemented.
- [x] Review and fix findings, run affected full suites, document and freeze evidence, commit.

The next gate is native packet reconstruction, authenticated freshness and source/configuration matching into the deadline classifier. No automatic recovery activation is authorized by this checkpoint alone. Current archive and native scoring behavior must remain intact.


## Verified result

The worker now collects delivery history and sends it only after the API negotiates
`decoder-delivery-delta-v1`, the transport clock and private pipeline read identity.
A successful report advances the worker cursor. Failed acknowledgements leave it
unchanged; API session renewal clears it. Supervisor ownership checks suppress
history outside its active publication. The API retains a complete bounded tail,
rejects modified overlap and cross-attempt scope reuse, and exposes packets only to
authenticated status requests opting into the version. Cursor fields must appear
together; missing, retired or foreign cursors receive the retained full tail.

Review identified a frozen-sample freshness replay. Repeating the same sampledAtMs
now preserves the earlier age proof plus server residence. Initially unproven
samples, or samples restored after an omitted report, remain unknown. A new timing
token cannot retroactively date an old sample. The regression failed before the fix,
passed afterward, and independent review confirmed closure.

Actual fixture `incremental-delivery-native-r4qx4E` ran FFmpeg and real loopback HTTP
through WorkerReporter and the authenticated application routes. It reconstructed
478 decoder arrivals across 161 client reports and 162 worker posts. The deliberately
lost acknowledgement contained video through ordinal 160; overlapping retransmission
recovered it. API restart forced a full worker snapshot at ordinal 208. Client cursor
loss forced resynchronization at ordinal 304. The 256-entry bound and exact arrival
identities/coverage reconcile with the terminal decoder history. Output fully decodes.

Across the complete experiment, including acquisition and resynchronization, packets
averaged 300.789 bytes (maximum 5,723), or 22.541 kbps of delivery payload. Complete
worker request bodies averaged 62.462 kbps and status response bodies 70.034 kbps;
these exclude HTTP headers and transport overhead. This is measured local fixture
cost, not a WAN bandwidth guarantee. Independent reconstruction rejects six corrupted
evidence variants.

An initial fixture failed because its setup lacked the capture credential required
to report recording; its pipeline was stopped/joined and evidence retained. An
intermediate passing run dropped an acknowledgement before decoder arrivals, so the
final run moved fault injection into actual video delivery. Both are retained rather
than replaced.

Final verification: 6 protocol, 378 worker, 448 API and 1,272 tooling tests pass;
worker and API typechecks pass. No Swift source changed in this checkpoint, so the
prior Core/model/simulator/Release results are not presented as newly executed.
Evidence is frozen in `artifacts/qa/incremental-delivery-final-verification.json`.

## Remaining gates

Implement the native packet consumer with server epoch/publication binding, bounded
sample age and complete capture/configuration windows. The local HTTP fixture does
not include a real relay attachment or physical phone clock mapping. Preserve those
requirements before allowing deadline results to drive quality recovery. Candidate
headroom, recovery trials, reconnect and physical/remote tests remain necessary.
