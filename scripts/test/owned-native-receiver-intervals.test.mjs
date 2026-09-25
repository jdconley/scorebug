import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import test from 'node:test';
import { qualifyOwnedReceiverProbeEvidence } from '../owned-receiver-probe-evidence.mjs';
const implementation = await import('../owned-native-receiver-intervals.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
function fixture() {
  const json = (path) => JSON.parse(readFileSync(new URL(`../../${path}`, import.meta.url)));
  const provenance = json('scripts/test/fixtures/owned-intervals-LvDNAy.provenance.json');
  const reused = json(provenance.reusedProvenance);
  const read = (entry) => {
    const bytes = gunzipSync(readFileSync(new URL(`../../${entry.fixture}`, import.meta.url)));
    assert.equal(bytes.length, entry.bytes);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), entry.sha256);
    return JSON.parse(bytes);
  };
  return {
    intervals: read(provenance.intervals),
    workerRecords: read(provenance.worker),
    records: read(reused.receiver),
    rawOwned: read(reused.native),
    ...reused.options,
  };
}
function qualify(f) {
  assert.equal(
    typeof implementation.qualifyOwnedNativeReceiverIntervals,
    'function',
    'whole-history owned interval replay must exist',
  );
  return implementation.qualifyOwnedNativeReceiverIntervals(f);
}
const rows = (f) => f.intervals.intervals;
const receiver = (f) =>
  qualifyOwnedReceiverProbeEvidence(f.records, f.rawOwned, {
    scope: f.scope,
    publishingGeneration: f.publishingGeneration,
    timingProfile: f.timingProfile,
  });
const authorityFlags = [
  'receiverCapacityQualified',
  'admissionQualified',
  'candidateAdmissionQualified',
  'retryPolicyQualified',
  'mediaQualified',
  'recoveryQualified',
  'upgradeAuthorized',
];
test('joins complete original intervals without dropping failed or short stages', () => {
  const f = fixture(),
    before = structuredClone(f),
    native = receiver(f),
    result = qualify(f);
  assert.deepEqual(f, before);
  assert.equal(result.mode, 'owned');
  assert.deepEqual(result.scope, f.scope);
  assert.equal(result.publishingGeneration, '1');
  assert.equal(result.observedIntervalCount, 13);
  assert.equal(result.stageCount, 10);
  assert.equal(result.attempts.length, 4);
  assert.deepEqual(
    result.attempts.map((a) => a.terminal),
    ['settledAcknowledged', 'settledFailure', 'settledFailure', 'settledAcknowledged'],
  );
  const covered = rows(f).flatMap((r, i) => {
    const s = f.records.map((p) => p.probe).filter((p) => p.id === r.nativeProbeId);
    return [r.start, r.end].every(
      (p) =>
        s.some((q) => BigInt(q.observedAtNanoseconds) <= BigInt(p.observedAtNanoseconds)) &&
        s.some((q) => BigInt(q.observedAtNanoseconds) >= BigInt(p.observedAtNanoseconds)),
    )
      ? [i]
      : [];
  });
  assert.deepEqual(result.coveredIntervalIndexes, covered);
  assert.deepEqual(covered, [1, 3, 4, 5, 6, 7, 8, 10, 11, 12]);
  assert.equal(result.deliveredPayloadBytesLowerBound, 8755348);
  assert.equal(result.receiverReadCoverageSeconds, 10.607891005);
  assert.equal(result.intervalCount, covered.length);
  assert.equal(result.unbracketedIntervalCount, 13 - covered.length);
  assert.equal(
    result.deliveredPayloadBytesLowerBound,
    covered.reduce((n, i) => n + Number(rows(f)[i].deliveredPayloadBytesLowerBound), 0),
  );
  assert.equal(
    result.receiverReadCoverageSeconds,
    Number(covered.reduce((n, i) => n + BigInt(rows(f)[i].durationNanoseconds), 0n)) / 1e9,
  );
  assert.deepEqual(
    result.independentReceiverClockOffsetBoundMilliseconds,
    native.clockOffsetBoundMilliseconds,
  );
  assert.deepEqual(result.clockOffsetBoundMilliseconds, [
    Math.max(
      ...rows(f).map(
        (r) =>
          r.requestStartedAt * 1000 -
          r.serverAgeUpperBoundMs -
          Number(r.end.observedAtNanoseconds) / 1e6,
      ),
    ),
    Math.min(
      ...rows(f).map(
        (r) => r.responseReceivedAt * 1000 - Number(r.end.observedAtNanoseconds) / 1e6,
      ),
    ),
  ]);
  for (const [i, attempt] of result.attempts.entries()) {
    for (const [key, value] of Object.entries(native.attempts[i])) {
      if (key !== 'stages') assert.deepEqual(attempt[key], value, key);
    }
    for (const [j, stage] of attempt.stages.entries()) {
      for (const [key, value] of Object.entries(native.attempts[i].stages[j]))
        assert.deepEqual(stage[key], value, key);
      const observed = rows(f).flatMap((r, k) => (r.nativeProbeId === stage.id ? [k] : []));
      assert.deepEqual(stage.observedIntervalIndexes, observed);
      assert.deepEqual(
        stage.coveredIntervalIndexes,
        observed.filter((k) => covered.includes(k)),
      );
      const request = f.rawOwned.events[stage.retirementRequestedEventIndex];
      assert.equal(request.kind, 'retirementRequested');
      assert.equal(request.snapshot.id.toLowerCase(), stage.id);
      assert.equal(stage.retirementRequestedAt, request.at);
    }
  }
  for (const flag of authorityFlags) assert.equal(result[flag], false, flag);
});
test('empty interval history honestly reports zero coverage while preserving every original stage', () => {
  const f = fixture();
  rows(f).length = 0;
  const result = qualify(f);
  assert.equal(result.observedIntervalCount, 0);
  assert.equal(result.intervalCount, 0);
  assert.equal(result.deliveredPayloadBytesLowerBound, 0);
  assert.equal(result.receiverReadCoverageSeconds, 0);
  assert.equal(result.minimumPayloadBitsPerSecondLowerBound, null);
  assert.equal(result.clockOffsetBoundMilliseconds, null);
  assert.deepEqual(
    result.attempts.map((a) => a.stages.length),
    [3, 2, 2, 3],
  );
  for (const flag of authorityFlags) assert.equal(result[flag], false, flag);
});
function unbracket(f) {
  const row = rows(f)[1];
  f.records = f.records.filter(
    (r) =>
      r.probe.id !== row.nativeProbeId ||
      BigInt(r.probe.observedAtNanoseconds) > BigInt(row.start.observedAtNanoseconds),
  );
}
test('unbracketed rows retain original indices and never contribute delivered load', () => {
  const f = fixture(),
    original = qualify(f);
  unbracket(f);
  const result = qualify(f);
  assert.ok(original.coveredIntervalIndexes.includes(1));
  assert.ok(!result.coveredIntervalIndexes.includes(1));
  assert.equal(result.intervalCount, original.intervalCount - 1);
  assert.equal(result.observedIntervalCount, 13);
  assert.ok(result.attempts[0].stages[1].observedIntervalIndexes.includes(1));
  assert.equal(
    result.deliveredPayloadBytesLowerBound,
    result.coveredIntervalIndexes.reduce(
      (n, i) => n + Number(rows(f)[i].deliveredPayloadBytesLowerBound),
      0,
    ),
  );
});
test('wholly unbracketed intervals retain clock validation with zero credited load', () => {
  const f = fixture();
  f.intervals.intervals = rows(f).slice(0, 1);
  const result = qualify(f);
  assert.equal(result.observedIntervalCount, 1);
  assert.equal(result.intervalCount, 0);
  assert.equal(result.deliveredPayloadBytesLowerBound, 0);
  assert.equal(result.receiverReadCoverageSeconds, 0);
  assert.equal(result.minimumPayloadBitsPerSecondLowerBound, null);
  assert.ok(result.clockOffsetBoundMilliseconds.every(Number.isFinite));
});
test('pending start packets reduce covered payload with exact packet accounting', () => {
  const f = fixture(),
    original = qualify(f),
    row = rows(f)[1];
  rows(f)[0].end.pendingPackets = row.start.pendingPackets = 3;
  row.deliveredPayloadBytesLowerBound = String(BigInt(row.deliveredPayloadBytesLowerBound) - 564n);
  row.payloadBitsPerSecondLowerBound =
    (Number(row.deliveredPayloadBytesLowerBound) * 8e9) / Number(row.durationNanoseconds);
  assert.equal(
    qualify(f).deliveredPayloadBytesLowerBound,
    original.deliveredPayloadBytesLowerBound - 564,
  );
});
test('accepts native interpolation without fabricating a raw renewal', () => {
  const f = fixture(),
    row = rows(f)[0];
  row.acceptedPayloadBytes = String(457968 + 10 * 1316);
  row.nativeLastAcceptedAt = 2025359.65;
  assert.equal(qualify(f).intervalCount, 10);
});
for (const [name, messages, acceptedAt] of [
  ['earlier', 3, 2025359.599928],
  ['later', 1, 2025359.699],
])
  test(`rejects native interpolation banking tokens against ${name} raw snapshot`, () => {
    const f = fixture(),
      row = rows(f)[0];
    row.acceptedPayloadBytes = String(457968 + messages * 1316);
    row.nativeLastAcceptedAt = acceptedAt;
    assert.throws(() => qualify(f), /one-message token allowance/);
  });
test('pending endpoint must reserve a complete native message', () => {
  const f = fixture(),
    row = rows(f)[5],
    stage = receiver(f).attempts[0].stages[2],
    p = row.end;
  const delta = BigInt(stage.acceptedPayloadBytes) - BigInt(p.deliveredPayloadBytes);
  for (const key of [
    'deliveredPayloadBytes',
    'campaignDeliveredPayloadBytes',
    'totalDeliveredPayloadBytes',
  ])
    p[key] = String(BigInt(p[key]) + delta);
  p.deliveredMessages = p.nextSequence = String(stage.acceptedPayloadBytes / 1316);
  p.pendingPackets = 1;
  assert.throws(() => qualify(f), /Endpoint exceeded native acceptance reservation/);
});
test('outer probe age stays at 1500ms under the 2000ms media timing profile', () => {
  const f = fixture();
  rows(f)[6].requestStartedAt -= 1.6;
  assert.equal(f.timingProfile, 'broadcast-reliability2000-v1');
  assert.throws(() => qualify(f), /Stale outer snapshot age/);
});
test('final campaign uses indexed retirement request despite acknowledged settlement and failed cleanup event', () => {
  const f = fixture(),
    result = qualify(f),
    last = result.attempts.at(-1),
    stage = last.stages.at(-1);
  assert.equal(last.terminal, 'settledAcknowledged');
  assert.equal(f.rawOwned.events[532].kind, 'failed');
  assert.equal(stage.retirementRequestedEventIndex, 534);
  rows(f).at(-1).evaluatedAt = stage.retirementRequestedAt;
  assert.throws(() => qualify(f), /Interval evaluated after retirement request/);
});
test('independent collector may use a different clock origin', () => {
  const f = fixture(),
    original = qualify(f);
  for (const r of f.records) {
    r.request.startedAtMilliseconds += 7000;
    r.request.receivedAtMilliseconds += 7000;
  }
  const result = qualify(f);
  assert.deepEqual(result.clockOffsetBoundMilliseconds, original.clockOffsetBoundMilliseconds);
  assert.deepEqual(
    result.independentReceiverClockOffsetBoundMilliseconds,
    original.independentReceiverClockOffsetBoundMilliseconds.map((n) => n + 7000),
  );
});
const mutations = {
  'oversized intervals': (f) => {
    f.intervals.intervals = Array(129).fill(rows(f)[0]);
  },
  'missing intervals': (f) => {
    delete f.intervals.intervals;
  },
  'open interval proof': (f) => {
    f.intervals.isClosed = false;
  },
  'invalid interval proof': (f) => {
    f.intervals.invalid = true;
  },
  'wrong interval version': (f) => {
    f.intervals.formatVersion = 2;
  },
  'foreign scope': (f) => {
    f.intervals.scope.matchID = 'foreign';
  },
  'missing trusted scope': (f) => {
    delete f.scope;
  },
  'missing trusted generation': (f) => {
    delete f.publishingGeneration;
  },
  'evidence-selected timing': (f) => {
    delete f.timingProfile;
  },
  'omitted failed native attempt': (f) => {
    f.rawOwned.events.splice(240, 1);
  },
  'missing failed receiver stage': (f) => {
    f.records = f.records.filter((r) => !(r.probe.campaign === '2' && r.probe.stage === 2));
  },
  'empty rows do not bypass whole history': (f) => {
    rows(f).length = 0;
    f.rawOwned.isClosed = false;
  },
  'missing workers': (f) => {
    f.workerRecords = [];
  },
  'foreign worker': (f) => {
    rows(f)[6].workerAttempt = 2;
  },
  'worker clock change': (f) => {
    rows(f)[6].publication.clock.originPTS = '1';
  },
  'worker identity restart': (f) => {
    const w = structuredClone(f.workerRecords[0]);
    w.attempt = 2;
    f.workerRecords.push(w);
    for (const r of rows(f).slice(6)) r.workerAttempt = 2;
  },
  'decoded windows from other worker': (f) => {
    const w = structuredClone(f.workerRecords[0]);
    w.attempt = 2;
    f.workerRecords.push(w);
    f.workerRecords[0].completedWindows = [];
  },
  'foreign native UUID': (f) => {
    rows(f)[6].nativeProbeId = rows(f)[0].nativeProbeId;
  },
  'foreign campaign': (f) => {
    rows(f)[6].nativeProbeCampaign = '1';
  },
  'malformed campaign': (f) => {
    rows(f)[6].nativeProbeCampaign = '04';
  },
  'foreign stage': (f) => {
    rows(f)[6].nativeProbeStage = 1;
  },
  'foreign generation': (f) => {
    rows(f)[6].nativePublishingGeneration = '2';
  },
  'endpoint version': (f) => {
    rows(f)[6].end.convention = 'mpegts-null-probe-v2';
  },
  'endpoint UUID': (f) => {
    rows(f)[6].end.id = rows(f)[0].end.id;
  },
  'endpoint stage': (f) => {
    rows(f)[6].start.stage = 1;
  },
  'endpoint rate': (f) => {
    rows(f)[6].end.bitRate = 500000;
  },
  'publication carry reset': (f) => {
    rows(f)[6].end.totalDeliveredPayloadBytes = rows(f)[6].end.campaignDeliveredPayloadBytes;
  },
  'campaign carry reset': (f) => {
    rows(f)[6].end.campaignDeliveredPayloadBytes = rows(f)[6].end.deliveredPayloadBytes;
  },
  'wrong duration': (f) => {
    rows(f)[6].durationNanoseconds = '1000000000';
  },
  'wrong message count': (f) => {
    rows(f)[6].deliveredMessages = '1';
  },
  'wrong lower bytes': (f) => {
    rows(f)[6].deliveredPayloadBytesLowerBound = '1';
  },
  'wrong rate': (f) => {
    rows(f)[6].payloadBitsPerSecondLowerBound += 1;
  },
  'short interval': (f) => {
    rows(f)[6].start.observedAtNanoseconds = String(
      BigInt(rows(f)[6].end.observedAtNanoseconds) - 999999999n,
    );
  },
  'long interval': (f) => {
    rows(f)[6].start.observedAtNanoseconds = String(
      BigInt(rows(f)[6].end.observedAtNanoseconds) - 5000000001n,
    );
  },
  'native start': (f) => {
    rows(f)[6].nativeStartedAt += 0.01;
  },
  'unobserved lease': (f) => {
    rows(f)[6].nativeLeaseDeadline += 0.01;
  },
  'unaligned acceptance': (f) => {
    rows(f)[6].acceptedPayloadBytes = '1317';
  },
  'acceptance beyond terminal': (f) => {
    rows(f)[6].acceptedPayloadBytes = '16776536';
  },
  'native future acceptance': (f) => {
    rows(f)[6].nativeLastAcceptedAt = rows(f)[6].nativeReadFinishedAt + 1;
  },
  'native stable bytes changed time': (f) => {
    rows(f)[6].nativeLastAcceptedAt += 0.001;
  },
  'after retirement request': (f) => {
    const r = rows(f)[0];
    r.evaluatedAt = f.rawOwned.events.find(
      (e) => e.kind === 'retirementRequested' && e.snapshot?.id.toLowerCase() === r.nativeProbeId,
    ).at;
  },
  'reordered rows': (f) => {
    rows(f).reverse();
  },
  'duplicate overlapping row': (f) => {
    rows(f).splice(1, 0, structuredClone(rows(f)[0]));
  },
  'native clock rebased': (f) => {
    for (const r of rows(f).slice(6))
      for (const k of [
        'requestStartedAt',
        'responseReceivedAt',
        'nativeReadStartedAt',
        'nativeReadFinishedAt',
        'evaluatedAt',
      ])
        r[k] += 0.1;
  },
  'HTTP clock rebased': (f) => {
    for (const r of f.records.filter((p) => p.probe.campaign === '4')) {
      r.request.startedAtMilliseconds += 1000;
      r.request.receivedAtMilliseconds += 1000;
    }
  },
  'request reversal': (f) => {
    rows(f)[6].responseReceivedAt = rows(f)[6].requestStartedAt - 1;
  },
  'read reversal': (f) => {
    rows(f)[6].nativeReadStartedAt = rows(f)[6].nativeReadFinishedAt + 1;
  },
  'understated age': (f) => {
    rows(f)[6].snapshotAgeUpperBoundMs -= 1;
  },
  'understated delivery age': (f) => {
    rows(f)[6].lastDeliveryAgeUpperBoundMs -= 1;
  },
  'noninteger server age': (f) => {
    rows(f)[6].serverAgeUpperBoundMs = 1.5;
  },
  'stale outer age under media budget': (f) => {
    rows(f)[6].requestStartedAt -= 1.6;
  },
  'excess request duration': (f) => {
    rows(f)[6].requestDurationMs = 1000;
  },
  'understated residence': (f) => {
    rows(f)[6].residenceDurationMs = 0;
  },
  'stale declared probe age': (f) => {
    rows(f)[6].snapshotAgeUpperBoundMs = 1600;
  },
  'future first delivery': (f) => {
    rows(f)[6].end.firstDeliveredAtNanoseconds = rows(f)[6].end.observedAtNanoseconds;
  },
  'regressed last delivery': (f) => {
    rows(f)[6].end.lastDeliveredAtNanoseconds = rows(f)[6].start.firstDeliveredAtNanoseconds;
  },
  'nonfinite clock': (f) => {
    rows(f)[6].evaluatedAt = Infinity;
  },
  'unbracketed UUID corruption': (f) => {
    unbracket(f);
    rows(f)[0].nativeProbeId = rows(f)[2].nativeProbeId;
  },
  'unbracketed lease corruption': (f) => {
    unbracket(f);
    rows(f)[0].nativeLeaseDeadline += 0.01;
  },
  'unbracketed counter corruption': (f) => {
    unbracket(f);
    rows(f)[0].deliveredMessages = '1';
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    assert.equal(typeof implementation.qualifyOwnedNativeReceiverIntervals, 'function');
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });
