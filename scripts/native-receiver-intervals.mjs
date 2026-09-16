import assert from 'node:assert/strict';
import { qualifyNativeBandwidthProbe } from './native-bandwidth-probe.mjs';
import { qualifyWorkerPublicationEvidence } from './worker-publication-evidence.mjs';
import { qualifyReceiverProbeEvidence } from './receiver-probe-evidence.mjs';
const uuid = (s) =>
  typeof s === 'string' &&
  /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(s) &&
  s.length === 36;
function uint(s, maximum = 18446744073709551615n) {
  assert.ok(typeof s === 'string' && s.length <= 20 && /^(0|[1-9][0-9]*)$/.test(s));
  const n = BigInt(s);
  assert.ok(n.toString() === s && n <= maximum);
  return n;
}
function packetProgress(p) {
  return uint(p.deliveredMessages) * 7n + BigInt(p.pendingPackets);
}
function validateSnapshot(p, accepted) {
  assert.equal(p.convention, 'mpegts-null-probe-v1');
  assert.equal(p.invalidReason, undefined);
  assert.equal(p.id, accepted.id.toLowerCase());
  assert.equal(p.publishingGeneration, accepted.publishingGeneration);
  assert.equal(p.bitRate, 1000000);
  const count = uint(p.deliveredMessages, 12748n);
  assert.equal(uint(p.deliveredPayloadBytes), count * 1316n);
  assert.equal(p.nextSequence, p.deliveredMessages);
  assert.ok(Number.isInteger(p.pendingPackets) && p.pendingPackets >= 0 && p.pendingPackets <= 6);
  assert.ok(p.pendingPackets === 0 || count < 12748n);
  const at = uint(p.observedAtNanoseconds, 86400000000000n);
  if (count === 0n) {
    assert.equal(p.firstDeliveredAtNanoseconds, undefined);
    assert.equal(p.lastDeliveredAtNanoseconds, undefined);
  } else {
    const first = uint(p.firstDeliveredAtNanoseconds, at),
      last = uint(p.lastDeliveredAtNanoseconds, at);
    assert.ok(first <= last);
    if (count === 1n) assert.equal(first, last);
  }
}
/** Cross-check app-generated intervals with separate authenticated relay polling.
 * Receiver read rates are delivered load, never spare capacity or upgrade permission. */
export function qualifyNativeReceiverIntervals(
  proof,
  records,
  scope,
  accepted,
  workerRecords,
  nativeProof,
) {
  const workers = qualifyWorkerPublicationEvidence(workerRecords, scope);
  const native = qualifyNativeBandwidthProbe(nativeProof, {
    mode: accepted.mode,
    scope,
    publishingGeneration: accepted.publishingGeneration,
  });
  for (const key of ['id', 'publishingGeneration', 'acceptedPayloadBytes'])
    assert.equal(native[key], accepted[key]);
  const receiver = qualifyReceiverProbeEvidence(records, scope, accepted);
  assert.equal(proof.formatVersion, 1);
  assert.equal(proof.isClosed, true);
  assert.equal(proof.invalid, false);
  assert.deepEqual(proof.scope, scope);
  assert.ok(Array.isArray(proof.intervals) && proof.intervals.length <= 128);
  if (accepted.mode === 'renew')
    assert.ok(proof.intervals.length > 0, 'No native receiver intervals');
  else assert.equal(accepted.mode, 'expire');
  const snapshots = records.map((r) => r.probe);
  let prior,
    identity,
    total = 0n,
    duration = 0n,
    minimumRate = Infinity;
  let offsetLower = -Infinity,
    offsetUpper = Infinity;
  for (const row of proof.intervals) {
    const worker = workers.find(
      (w) =>
        w.workerId === row.workerId &&
        w.workerEpoch === row.workerEpoch &&
        w.attempt === row.workerAttempt,
    );
    assert.ok(worker, 'Uncorrelated worker identity');
    assert.deepEqual(row.publication, worker.publication);
    for (const key of [
      'requestStartedAt',
      'responseReceivedAt',
      'nativeReadStartedAt',
      'nativeReadFinishedAt',
      'evaluatedAt',
      'nativeStartedAt',
      'nativeLeaseDeadline',
      'nativeLastAcceptedAt',
      'requestDurationMs',
      'residenceDurationMs',
      'serverAgeUpperBoundMs',
    ])
      assert.ok(Number.isFinite(row[key]) && row[key] >= 0, key);
    assert.ok(
      row.requestStartedAt <= row.responseReceivedAt &&
        row.responseReceivedAt <= row.nativeReadStartedAt &&
        row.nativeReadStartedAt <= row.nativeReadFinishedAt &&
        row.nativeReadFinishedAt <= row.evaluatedAt,
    );
    assert.ok(Number.isSafeInteger(row.serverAgeUpperBoundMs));
    assert.ok(
      row.requestDurationMs <= (row.responseReceivedAt - row.requestStartedAt) * 1000 + 0.001,
    );
    assert.ok(
      row.requestDurationMs + row.residenceDurationMs <=
        (row.evaluatedAt - row.requestStartedAt) * 1000 + 0.001,
    );
    assert.ok(
      (row.nativeReadFinishedAt - row.nativeReadStartedAt) * 1000 <=
        row.residenceDurationMs + 0.001,
    );
    assert.ok(
      Math.abs(
        row.snapshotAgeUpperBoundMs -
          row.serverAgeUpperBoundMs -
          row.requestDurationMs -
          row.residenceDurationMs,
      ) < 1e-6,
      'Understated snapshot age',
    );
    assert.equal(row.nativeStartedAt, nativeProof.events[0].sample.startedAt);
    assert.ok(
      row.nativeStartedAt <= row.nativeLastAcceptedAt &&
        row.nativeLastAcceptedAt <= row.nativeReadFinishedAt &&
        row.evaluatedAt < row.nativeLeaseDeadline,
    );
    assert.ok(
      nativeProof.events.some((e) => e.sample.leaseDeadline === row.nativeLeaseDeadline),
      'Unobserved native lease',
    );
    assert.ok(row.nativeLeaseDeadline - 0.3 <= row.nativeReadFinishedAt + 1e-6);
    const reportedAccepted = uint(row.acceptedPayloadBytes);
    for (const event of nativeProof.events) {
      const n = uint(event.sample.acceptedPayloadBytes),
        last = event.sample.lastAcceptedAt;
      if (last === row.nativeLastAcceptedAt) assert.equal(n, reportedAccepted);
      else if (last === null || last < row.nativeLastAcceptedAt) assert.ok(n <= reportedAccepted);
      else assert.ok(n >= reportedAccepted);
      if (event.observedAt <= row.nativeReadStartedAt) {
        assert.ok(n <= reportedAccepted);
        assert.equal(event.sample.reason, null, 'Interval sampled after native withdrawal');
      }
    }
    const receiverMilliseconds = Number(uint(row.end.observedAtNanoseconds)) / 1e6;
    offsetLower = Math.max(
      offsetLower,
      row.requestStartedAt * 1000 - row.serverAgeUpperBoundMs - receiverMilliseconds,
    );
    offsetUpper = Math.min(offsetUpper, row.responseReceivedAt * 1000 - receiverMilliseconds);
    assert.ok(offsetLower <= offsetUpper, 'Native/receiver clocks cannot fit the request bounds');
    for (const p of [row.start, row.end]) {
      validateSnapshot(p, accepted);
      const at = uint(p.observedAtNanoseconds);
      const before = snapshots.findLast((s) => uint(s.observedAtNanoseconds) <= at);
      const after = snapshots.find((s) => uint(s.observedAtNanoseconds) >= at);
      assert.ok(before && after, 'Native endpoint outside independent receiver coverage');
      assert.ok(
        packetProgress(before) <= packetProgress(p) && packetProgress(p) <= packetProgress(after),
        'Independent receiver counter mismatch',
      );
      if (before.firstDeliveredAtNanoseconds !== undefined)
        assert.equal(p.firstDeliveredAtNanoseconds, before.firstDeliveredAtNanoseconds);
      if (p.firstDeliveredAtNanoseconds !== undefined)
        assert.equal(p.firstDeliveredAtNanoseconds, after.firstDeliveredAtNanoseconds);
      if (p.deliveredMessages === before.deliveredMessages)
        assert.equal(p.lastDeliveredAtNanoseconds, before.lastDeliveredAtNanoseconds);
      else assert.ok(uint(p.lastDeliveredAtNanoseconds) >= uint(before.observedAtNanoseconds));
      if (p.deliveredMessages === after.deliveredMessages)
        assert.equal(p.lastDeliveredAtNanoseconds, after.lastDeliveredAtNanoseconds);
      else assert.ok(uint(after.lastDeliveredAtNanoseconds) >= at);
    }
    const p = row.publication;
    assert.equal(p.publisherId, receiver.publicationId);
    assert.equal(p.publishingAttemptId, scope.publishingAttemptID.toLowerCase());
    assert.ok(uuid(p.readerId) && p.readerId !== p.publisherId && uuid(row.workerEpoch));
    assert.ok(typeof row.workerId === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(row.workerId));
    assert.ok(Number.isSafeInteger(row.workerAttempt) && row.workerAttempt > 0);
    assert.equal(p.clock.convention, 'mpegts-ingress-origin-90k-v1');
    uint(p.clock.originPTS, (1n << 33n) - 1n);
    const nextIdentity = [p, row.workerId, row.workerEpoch, row.workerAttempt];
    if (identity) assert.deepEqual(nextIdentity, identity);
    else identity = nextIdentity;
    assert.equal(row.nativeProbeId, accepted.id.toLowerCase());
    assert.equal(row.nativePublishingGeneration, accepted.publishingGeneration);
    const count = uint(row.end.deliveredMessages) - uint(row.start.deliveredMessages);
    const elapsed = uint(row.end.observedAtNanoseconds) - uint(row.start.observedAtNanoseconds);
    assert.ok(elapsed >= 1000000000n && elapsed <= 5000000000n);
    assert.equal(uint(row.durationNanoseconds), elapsed);
    assert.equal(uint(row.deliveredMessages), count);
    const lowerBytes = count * 1316n - BigInt(row.start.pendingPackets) * 188n;
    assert.ok(lowerBytes > 0n);
    assert.equal(uint(row.deliveredPayloadBytesLowerBound), lowerBytes);
    const rate = (Number(lowerBytes) * 8e9) / Number(elapsed);
    assert.ok(
      Number.isFinite(row.payloadBitsPerSecondLowerBound) &&
        Math.abs(rate - row.payloadBitsPerSecondLowerBound) < 0.001,
    );
    const nativeBytes = uint(row.acceptedPayloadBytes, BigInt(accepted.acceptedPayloadBytes));
    assert.equal(nativeBytes % 1316n, 0n);
    assert.ok(
      (uint(row.end.deliveredMessages) + (row.end.pendingPackets ? 1n : 0n)) * 1316n <= nativeBytes,
    );
    for (const age of [row.snapshotAgeUpperBoundMs, row.lastDeliveryAgeUpperBoundMs])
      assert.ok(Number.isFinite(age) && age >= 0 && age <= 1500);
    // Uptime brackets the ContinuousClock samples. Qualify with the entire outer
    // span too, so coordinated understatement of exported durations cannot admit
    // evidence older than the freshness budget.
    const outerSnapshotAge =
      row.serverAgeUpperBoundMs + (row.evaluatedAt - row.requestStartedAt) * 1000;
    assert.ok(outerSnapshotAge <= 1500, 'Stale outer snapshot age');
    const deliveryAge =
      Number(uint(row.end.observedAtNanoseconds) - uint(row.end.lastDeliveredAtNanoseconds)) / 1e6;
    assert.ok(
      Math.abs(row.lastDeliveryAgeUpperBoundMs - row.snapshotAgeUpperBoundMs - deliveryAge) < 1e-6,
    );
    assert.ok(outerSnapshotAge + deliveryAge <= 1500, 'Stale outer delivery age');
    if (prior) {
      assert.ok(
        uint(row.start.observedAtNanoseconds) >= uint(prior.end.observedAtNanoseconds),
        'Overlapping native intervals',
      );
      assert.ok(nativeBytes >= uint(prior.acceptedPayloadBytes));
      assert.ok(
        row.requestStartedAt >= prior.responseReceivedAt && row.evaluatedAt >= prior.evaluatedAt,
      );
    }
    prior = row;
    total += lowerBytes;
    duration += elapsed;
    minimumRate = Math.min(minimumRate, rate);
  }
  return {
    intervalCount: proof.intervals.length,
    deliveredPayloadBytesLowerBound: Number(total),
    receiverReadCoverageSeconds: Number(duration) / 1e9,
    minimumPayloadBitsPerSecondLowerBound: proof.intervals.length ? minimumRate : null,
    receiverCapacityQualified: false,
  };
}
