import assert from 'node:assert/strict';
import test from 'node:test';
import { repeatedReceiverIntervalFixture } from './fixtures/repeated-receiver-interval-evidence.mjs';
import { qualifyRepeatedNativeCandidateMeasurements } from '../repeated-native-candidate-measurement.mjs';
import { qualifyMeasuredNativeLifecycle } from '../measured-native-lifecycle.mjs';
import { qualifyRepeatedProbeRetirements } from '../repeated-probe-retirement.mjs';
import { qualifyRepeatedReceiverProbeEvidence } from '../repeated-receiver-probe-evidence.mjs';
const implementation = await import('../repeated-native-receiver-intervals.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
const fixture = repeatedReceiverIntervalFixture;
function qualify(f) {
  assert.equal(
    typeof implementation.qualifyRepeatedNativeReceiverIntervals,
    'function',
    'repeated interval replay must be implemented',
  );
  return implementation.qualifyRepeatedNativeReceiverIntervals({ ...f, nativeProbe: f.probe });
}
test('raw interval fixture still passes candidate, media, lifecycle, retirement, and receiver replay', () => {
  const f = fixture();
  assert.equal(
    qualifyRepeatedNativeCandidateMeasurements(f.candidateProof, { ...f, nativeProbe: f.probe })
      .campaigns.length,
    2,
  );
  assert.equal(
    qualifyMeasuredNativeLifecycle({ ...f, sequence: 'repeated240' }).applications.length,
    4,
  );
  assert.equal(qualifyRepeatedProbeRetirements(f.probe, f).campaigns.length, 2);
  assert.equal(
    qualifyRepeatedReceiverProbeEvidence(f.records, f.scope, f.probe).deliveredPayloadBytes,
    30478560,
  );
});
test('replays raw v3 intervals across all six stages with original identities and covered indexes', () => {
  const f = fixture(),
    before = structuredClone(f),
    result = qualify(f);
  assert.deepEqual(f, before);
  assert.deepEqual(result.coveredIntervalIndexes, [0, 1, 2, 3, 4, 5, 6, 7]);
  assert.equal(result.intervalCount, 8);
  assert.equal(result.observedIntervalCount, 8);
  assert.equal(result.unbracketedIntervalCount, 0);
  assert.ok(Math.abs(result.receiverReadCoverageSeconds - 9.6) < 1e-6);
  assert.deepEqual(
    result.campaigns.map((c) => [c.campaign, c.appliedRevision, c.coveredIntervalIndexes]),
    [
      ['1', '0', [0, 1, 2, 3]],
      ['2', '2', [4, 5, 6, 7]],
    ],
  );
  for (const key of [
    'receiverCapacityQualified',
    'admissionQualified',
    'repeatedPolicyQualified',
    'upgradeAuthorized',
  ])
    assert.equal(result[key], false);
});

test('unbracketed stage3 edge remains validated but contributes no load or coverage', () => {
  const f = fixture();
  f.records = f.records.filter(
    (r) =>
      !(
        r.probe.campaign === '1' &&
        r.probe.stage === 3 &&
        r.probe.observedAtNanoseconds === '127200000000'
      ),
  );
  const result = qualify(f);
  assert.deepEqual(result.coveredIntervalIndexes, [0, 1, 3, 4, 5, 6, 7]);
  assert.equal(result.unbracketedIntervalCount, 1);
  assert.equal(result.intervalCount, 7);
  assert.equal(
    result.deliveredPayloadBytesLowerBound,
    f.intervals.intervals.reduce(
      (n, r, i) => n + (i === 2 ? 0 : Number(r.deliveredPayloadBytesLowerBound)),
      0,
    ),
  );
});
test('pending start packets reduce the exact conservative delivered payload', () => {
  const f = fixture(),
    r = f.intervals.intervals[2];
  r.start.pendingPackets = 3;
  r.deliveredPayloadBytesLowerBound = String(BigInt(r.deliveredPayloadBytesLowerBound) - 564n);
  r.payloadBitsPerSecondLowerBound =
    (Number(r.deliveredPayloadBytesLowerBound) * 8e9) / Number(r.durationNanoseconds);
  assert.equal(qualify(f).intervalCount, 8);
});
const rows = (f) => f.intervals.intervals;
const candidate = (f) => f.quality.events.findLast((e) => e.kind === 'candidate');
const mutateNativeTimes = (row, amount) => {
  for (const k of [
    'requestStartedAt',
    'responseReceivedAt',
    'nativeReadStartedAt',
    'nativeReadFinishedAt',
    'evaluatedAt',
  ])
    row[k] += amount;
};
const mutations = {
  missingRows: (f) => {
    rows(f).length = 0;
  },
  excessRows: (f) => {
    f.intervals.intervals = Array(129).fill(rows(f)[0]);
  },
  wrongVersion: (f) => {
    f.intervals.formatVersion = 2;
  },
  openProof: (f) => {
    f.intervals.isClosed = false;
  },
  invalidProof: (f) => {
    f.intervals.invalid = true;
  },
  intervalScope: (f) => {
    f.intervals.scope = { ...f.scope, matchID: 'other' };
  },
  nativeScope: (f) => {
    f.probe.scope = { ...f.scope, matchID: 'other' };
  },
  unjoinedNative: (f) => {
    f.probe.campaigns[1].isJoined = false;
  },
  retirementRequestSubstitution: (f) => {
    f.lifecycle.profileRequests[2].requestID = f.lifecycle.profileRequests[0].requestID;
  },
  unboundRetirement: (f) => {
    candidate(f).candidateAdmission.probe.acceptedPayloadBytes = '0';
  },
  lifecycleScope: (f) => {
    f.lifecycle.scope = { ...f.scope, matchID: 'other' };
  },
  missingReceiverStage: (f) => {
    f.records = f.records.filter((r) => !(r.probe.campaign === '2' && r.probe.stage === 2));
  },
  wrongReceiverPublication: (f) => {
    f.records[0].publication.publishingAttemptId = 'dddddddd-dddd-4ddd-8ddd-000000000004';
  },
  missingWorker: (f) => {
    f.workerRecords = [];
  },
  crossedWorker: (f) => {
    rows(f)[6].workerAttempt = 2;
  },
  workerClock: (f) => {
    rows(f)[6].publication.clock.originPTS = '1';
  },
  workerIdentityRestart: (f) => {
    const w = structuredClone(f.workerRecords[0]);
    w.attempt = 2;
    f.workerRecords.push(w);
    rows(f)[6].workerAttempt = 2;
    rows(f)[7].workerAttempt = 2;
  },
  nativeCampaignMissing: (f) => {
    delete rows(f)[6].nativeProbeCampaign;
  },
  nativeCampaignCrossed: (f) => {
    rows(f)[6].nativeProbeCampaign = '1';
  },
  nativeCampaignMalformed: (f) => {
    rows(f)[6].nativeProbeCampaign = '02';
  },
  nativeStageCrossed: (f) => {
    rows(f)[6].nativeProbeStage = 2;
  },
  nativeIdCrossed: (f) => {
    rows(f)[6].nativeProbeId = rows(f)[2].nativeProbeId;
  },
  nativeGenerationCrossed: (f) => {
    rows(f)[6].nativePublishingGeneration = '3';
  },
  endpointV2: (f) => {
    rows(f)[6].end.convention = 'mpegts-null-probe-v2';
  },
  endpointCampaignCrossed: (f) => {
    rows(f)[6].end.campaign = '1';
  },
  endpointStageCrossed: (f) => {
    rows(f)[6].start.stage = 2;
  },
  endpointIdCrossed: (f) => {
    rows(f)[6].end.id = rows(f)[2].end.id;
  },
  endpointRate: (f) => {
    rows(f)[6].end.bitRate = 2000000;
  },
  campaignCounterCarry: (f) => {
    rows(f)[6].end.campaignDeliveredPayloadBytes = rows(f)[6].end.totalDeliveredPayloadBytes;
  },
  publicationCounterReset: (f) => {
    rows(f)[6].end.totalDeliveredPayloadBytes = rows(f)[6].end.campaignDeliveredPayloadBytes;
  },
  wrongDuration: (f) => {
    rows(f)[6].durationNanoseconds = '1200000001';
  },
  wrongCount: (f) => {
    rows(f)[6].deliveredMessages = '1081';
  },
  wrongPayload: (f) => {
    rows(f)[6].deliveredPayloadBytesLowerBound = '1';
  },
  wrongRate: (f) => {
    rows(f)[6].payloadBitsPerSecondLowerBound += 0.01;
  },
  shortInterval: (f) => {
    rows(f)[6].start.observedAtNanoseconds = String(
      BigInt(rows(f)[6].end.observedAtNanoseconds) - 999999999n,
    );
  },
  longInterval: (f) => {
    rows(f)[6].start.observedAtNanoseconds = String(
      BigInt(rows(f)[6].end.observedAtNanoseconds) - 5000000001n,
    );
  },
  nativeStart: (f) => {
    rows(f)[6].nativeStartedAt += 0.01;
  },
  unobservedLease: (f) => {
    rows(f)[6].nativeLeaseDeadline += 0.01;
  },
  leaseNotYetRenewed: (f) => {
    rows(f)[6].nativeLeaseDeadline = f.probe.campaigns[1].events.at(-1).sample.leaseDeadline;
  },
  acceptedUnaligned: (f) => {
    rows(f)[6].acceptedPayloadBytes = '1317';
  },
  acceptedAboveNative: (f) => {
    rows(f)[6].acceptedPayloadBytes = '16776536';
  },
  nativeAfterRead: (f) => {
    rows(f)[6].nativeLastAcceptedAt = rows(f)[6].nativeReadFinishedAt + 0.001;
  },
  nativeCountStableTimestampChanged: (f) => {
    rows(f)[6].nativeLastAcceptedAt += 0.001;
  },
  nativeReservedPending: (f) => {
    const r = rows(f)[0];
    r.end.deliveredMessages = String(BigInt(r.acceptedPayloadBytes) / 1316n);
    r.end.deliveredPayloadBytes = r.acceptedPayloadBytes;
    r.end.totalDeliveredPayloadBytes = r.end.campaignDeliveredPayloadBytes = r.acceptedPayloadBytes;
    r.end.nextSequence = r.end.deliveredMessages;
    r.end.pendingPackets = 1;
  },
  missingStageCoverage: (f) => {
    rows(f).splice(5, 1);
  },
  onlyUnbracketedStage: (f) => {
    f.records.splice(0, 1);
  },
  reorderedRows: (f) => {
    rows(f).reverse();
  },
  overlappingRows: (f) => {
    rows(f)[3].start.observedAtNanoseconds = String(
      BigInt(rows(f)[2].end.observedAtNanoseconds) - 1n,
    );
  },
  changedClockOffset: (f) => {
    mutateNativeTimes(rows(f)[6], 0.1);
  },
  requestReversal: (f) => {
    rows(f)[6].responseReceivedAt = rows(f)[6].requestStartedAt - 0.001;
  },
  readReversal: (f) => {
    rows(f)[6].nativeReadStartedAt = rows(f)[6].nativeReadFinishedAt + 0.001;
  },
  understatedSnapshot: (f) => {
    rows(f)[6].snapshotAgeUpperBoundMs -= 1;
  },
  understatedDelivery: (f) => {
    rows(f)[6].lastDeliveryAgeUpperBoundMs -= 1;
  },
  nonintegerServerAge: (f) => {
    rows(f)[6].serverAgeUpperBoundMs = 5.1;
  },
  overstatedRequestDuration: (f) => {
    rows(f)[6].requestDurationMs = 50;
  },
  understatedResidence: (f) => {
    rows(f)[6].residenceDurationMs = 0;
  },
  staleOuterSnapshot: (f) => {
    rows(f)[6].requestStartedAt -= 2;
  },
  endpointFutureFirstDelivery: (f) => {
    rows(f)[6].end.firstDeliveredAtNanoseconds = rows(f)[6].end.observedAtNanoseconds;
  },
  endpointLastDeliveryRegression: (f) => {
    rows(f)[6].end.lastDeliveredAtNanoseconds = rows(f)[6].start.firstDeliveredAtNanoseconds;
  },
  stableCountTimestampChanged: (f) => {
    rows(f)[6].end.lastDeliveredAtNanoseconds = String(
      BigInt(rows(f)[6].end.lastDeliveredAtNanoseconds) + 1n,
    );
  },
  conflictingSharedEndpoint: (f) => {
    rows(f)[3].start.pendingPackets = 1;
  },
  malformedTime: (f) => {
    rows(f)[6].evaluatedAt = Infinity;
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects repeated interval ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.equal(
      typeof implementation.qualifyRepeatedNativeReceiverIntervals,
      'function',
      'repeated interval replay must be implemented',
    );
    assert.throws(() => qualify(f));
  });
test('rejects interpolation that banks native tokens before the interval observation', () => {
  const f = fixture(),
    r = rows(f)[0];
  r.acceptedPayloadBytes = String(63 * 1316);
  r.nativeLastAcceptedAt = 114.5205;
  assert.throws(() => qualify(f), /token allowance/);
});
test('rejects interpolation that spends native tokens too fast toward a later raw observation', () => {
  const f = fixture(),
    r = rows(f)[0];
  r.acceptedPayloadBytes = String(61 * 1316);
  r.nativeLastAcceptedAt = 114.58999;
  r.nativeReadStartedAt = 114.595;
  r.nativeReadFinishedAt = 114.596;
  r.evaluatedAt = 114.597;
  r.residenceDurationMs = 77;
  r.snapshotAgeUpperBoundMs = 92;
  r.lastDeliveryAgeUpperBoundMs = 172;
  assert.throws(() => qualify(f), /token allowance/);
});
test('stage3 cannot use the final joined observation in place of the earlier profile request cutoff', () => {
  const f = fixture(),
    r = rows(f)[3],
    request = f.lifecycle.profileRequests[0];
  r.evaluatedAt = request.requestedAt;
  r.residenceDurationMs = (r.evaluatedAt - r.responseReceivedAt) * 1000;
  r.snapshotAgeUpperBoundMs = r.serverAgeUpperBoundMs + r.requestDurationMs + r.residenceDurationMs;
  r.lastDeliveryAgeUpperBoundMs = r.snapshotAgeUpperBoundMs + 80;
  assert.throws(() => qualify(f), /retirement request/);
});
for (const corruption of ['id', 'history', 'lease'])
  test(`unbracketed edge still rejects ${corruption} corruption`, () => {
    const f = fixture(),
      r = rows(f)[2];
    f.records = f.records.filter(
      (p) =>
        !(
          p.probe.campaign === '1' &&
          p.probe.stage === 3 &&
          p.probe.observedAtNanoseconds === '127200000000'
        ),
    );
    if (corruption === 'id') r.nativeProbeId = rows(f)[0].nativeProbeId;
    if (corruption === 'history') r.start.firstDeliveredAtNanoseconds = '117610000000';
    if (corruption === 'lease') r.nativeLeaseDeadline += 0.01;
    assert.throws(() => qualify(f));
  });
test('decoded worker windows must belong to the interval worker rather than a different attempt', () => {
  const f = fixture(),
    other = structuredClone(f.workerRecords[0]);
  other.attempt = 2;
  f.workerRecords[0].completedWindows = [];
  f.workerRecords.push(other);
  assert.throws(() => qualify(f), /decoded windows/);
});

test('accepts a paced native observation between raw renewal samples without inventing a raw event', () => {
  const f = fixture(),
    row = rows(f)[0];
  row.acceptedPayloadBytes = String(61 * 1316);
  row.nativeLastAcceptedAt = 114.515;
  assert.equal(qualify(f).intervalCount, 8);
});

test('keeps separate native and independent HTTP clock origins consistent across both campaigns', () => {
  const f = fixture();
  for (const record of f.records) {
    record.request.startedAtMilliseconds += 7000;
    record.request.receivedAtMilliseconds += 7000;
  }
  const result = qualify(f);
  assert.deepEqual(result.clockOffsetBoundMilliseconds.map(Math.round), [5, 20]);
  assert.deepEqual(
    result.independentReceiverClockOffsetBoundMilliseconds.map(Math.round),
    [7100, 7110],
  );
});
