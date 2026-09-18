import assert from 'node:assert/strict';
import test from 'node:test';
import * as implementation from '../repeated-native-admission.mjs';
import { replayCandidateTransportCost } from '../candidate-transport-cost.mjs';
import { repeatedReceiverIntervalFixture } from './fixtures/repeated-receiver-interval-evidence.mjs';
import { withRepeatedAdmissionWitnesses } from './fixtures/repeated-admission-witnesses.mjs';

const fixture = () => withRepeatedAdmissionWitnesses(repeatedReceiverIntervalFixture());
const qualify = (f) =>
  implementation.qualifyRepeatedNativeAdmissions({ ...f, nativeProbe: f.probe });
const decisions = (f) => f.quality.events.filter((e) => e.kind === 'candidate');

test('joins both admissions from raw evidence without mutating or reindexing it', () => {
  const f = fixture(),
    before = structuredClone(f),
    result = qualify(f);
  assert.deepEqual(f, before);
  assert.equal(result.admissionQualified, true);
  assert.deepEqual(
    result.campaigns.map((c) => c.campaign),
    ['1', '2'],
  );
  assert.deepEqual(
    result.campaigns.map((c) => c.appliedRevision),
    ['0', '2'],
  );
  assert.deepEqual(
    result.campaigns.map((c) => c.selectedIntervalIndexes),
    [
      [2, 3],
      [6, 7],
    ],
  );
  assert.deepEqual(
    result.campaigns.map((c) => c.qualityEventIndex),
    [2, 5],
  );
  assert.deepEqual(
    result.campaigns.map((c) => c.profileRequestID),
    [f.lifecycle.profileRequests[0].requestID, f.lifecycle.profileRequests[2].requestID],
  );
  for (const key of [
    'mediaHealthQualified',
    'recoveryQualified',
    'repeatedPolicyQualified',
    'upgradeAuthorized',
  ])
    assert.equal(result[key], false);
});

const faults = {
  'unclosed candidate measurement': (f) => {
    f.candidateProof.isClosed = false;
  },
  'unclosed native history': (f) => {
    f.probe.isClosed = false;
  },
  'undecoded candidate frame': (f) => {
    f.liveIDs = f.liveIDs.filter((id) => id !== 2600);
  },
  'missing decoded live frames': (f) => {
    f.liveIDs = [];
  },
  'unclosed lifecycle': (f) => {
    f.lifecycle.isClosed = false;
  },
  'crossed second candidate': (f) => {
    decisions(f)[1].candidate = structuredClone(decisions(f)[0].candidate);
  },
  'missing witness': (f) => {
    delete decisions(f)[1].candidateAdmission;
  },
  'crossed witness': (f) => {
    decisions(f)[1].candidateAdmission = structuredClone(decisions(f)[0].candidateAdmission);
  },
  'wrong scalar measurement start': (f) => {
    decisions(f)[1].candidate.measuredStart += 0.01;
  },
  'wrong scalar measurement end': (f) => {
    decisions(f)[1].candidate.measuredEnd -= 0.01;
  },
  'wrong scalar evaluation': (f) => {
    decisions(f)[1].candidate.evaluatedAt -= 0.01;
  },
  'wrong scalar deadline': (f) => {
    decisions(f)[1].candidate.validUntil += 0.01;
  },
  'wrong scalar transport cost': (f) => {
    decisions(f)[1].candidate.candidateTransportBitsPerSecond++;
  },
  'wrong scalar delivered load': (f) => {
    decisions(f)[1].candidate.deliveredPaddingBitsPerSecond++;
  },
  'invalid baseline bitrate': (f) => {
    decisions(f)[1].candidate.baselineVideoBitrate++;
  },
  'invalid target bitrate': (f) => {
    decisions(f)[1].candidate.videoBitrate++;
  },
  'late dispatch': (f) => {
    f.lifecycle.profileRequests[2].requestedAt = 190.3;
  },
  'deadline exceeds witness': (f) => {
    for (const e of f.quality.events.filter((e) => e.revision === '3'))
      e.action.validUntil = 190.25;
  },
  'missing independent records': (f) => {
    f.records = [];
  },
  'missing worker records': (f) => {
    f.workerRecords = [];
  },
  'wrong receiver row campaign': (f) => {
    f.intervals.intervals[6].nativeProbeCampaign = '1';
  },
  'uncovered last interval': (f) => {
    f.records = f.records.slice(0, -5);
  },
  'missing receiver interval': (f) => {
    f.intervals.intervals.pop();
  },
  'partial native profile sequence': (f) => {
    f.format.receipts.pop();
  },
};
for (const [name, mutate] of Object.entries(faults))
  test(`rejects combined admission ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

for (const index of [0, 1])
  test(`requires actual headroom for campaign ${index + 1}`, () => {
    const raw = repeatedReceiverIntervalFixture();
    const m = raw.candidateProof.campaigns[index].measurement.measurement;
    for (const frame of m.encoding.frames) frame.byteCount *= 40;
    for (const input of m.transport.mux.inputs) if (input.media === 'video') input.byteCount *= 40;
    const { writes, programWrites, pcrCount, ...totals } = replayCandidateTransportCost(
      m.transport.mux.inputs,
    );
    Object.assign(m.transport.mux, totals);
    const f = withRepeatedAdmissionWitnesses(raw);
    assert.throws(() => qualify(f), /25% measured padding headroom/);
  });

function crossProofAcceptanceFixture(intervalMessages, intervalAt, currentMessages, currentAt) {
  const f = repeatedReceiverIntervalFixture(),
    index = 1;
  for (const event of f.probe.campaigns[index].events.filter(
    (e) => e.sample.stage === 3 && e.sample.reason !== null,
  )) {
    event.sample.acceptedPayloadBytes = String(11220 * 1316);
    event.sample.totalAcceptedPayloadBytes = String(552720 + 11220 * 1316);
    event.sample.lastAcceptedAt = 189.99;
  }
  for (const request of f.lifecycle.profileRequests.slice(2)) {
    request.terminalProbeRead.observation.acceptedPayloadBytes = String(11220 * 1316);
    request.terminalProbeRead.observation.lastAcceptedAt = 189.99;
  }
  for (const sample of [
    f.lifecycle.profileRequests[2].currentProbe,
    decisions(f)[1].candidateAdmission.probe,
  ]) {
    sample.acceptedPayloadBytes = String(currentMessages * 1316);
    sample.lastAcceptedAt = currentAt;
  }
  const record = f.records.at(-1);
  for (const key of ['deliveredMessages', 'nextSequence'])
    record.probe[key] = String(Number(record.probe[key]) + 60);
  for (const key of [
    'deliveredPayloadBytes',
    'campaignDeliveredPayloadBytes',
    'totalDeliveredPayloadBytes',
  ])
    record.probe[key] = String(Number(record.probe[key]) + 60 * 1316);
  record.probe.observedAtNanoseconds = '190060000000';
  record.probe.lastDeliveredAtNanoseconds = '190020000000';
  record.request = { startedAtMilliseconds: 190160, receivedAtMilliseconds: 190170 };
  const row = f.intervals.intervals.at(-1);
  Object.assign(row, {
    acceptedPayloadBytes: String(intervalMessages * 1316),
    nativeLastAcceptedAt: intervalAt,
    nativeLeaseDeadline: f.lifecycle.profileRequests[2].currentProbe.leaseDeadline,
    nativeReadStartedAt: 189.939991,
    nativeReadFinishedAt: 189.939992,
    evaluatedAt: 189.94,
  });
  row.residenceDurationMs = (row.evaluatedAt - row.responseReceivedAt) * 1000;
  row.snapshotAgeUpperBoundMs = 15 + row.residenceDurationMs;
  row.lastDeliveryAgeUpperBoundMs = row.snapshotAgeUpperBoundMs + 80;
  return withRepeatedAdmissionWitnesses(f);
}

test('rejects an impossible acceptance burst between independently valid interval and admission reads', () => {
  const f = crossProofAcceptanceFixture(11170, 189.93999, 11180, 189.94);
  assert.throws(() => qualify(f), /one-message token allowance/);
});

test('rejects unchanged acceptance counts with contradictory cross-proof timestamps', () => {
  const f = crossProofAcceptanceFixture(11170, 189.93999, 11170, 189.94);
  assert.throws(() => qualify(f), /acceptance timestamp changed without bytes/);
});

test('accepts a consistent bounded interpolation between interval and cached admission', () => {
  const f = crossProofAcceptanceFixture(11170, 189.92999, 11180, 189.94);
  assert.equal(qualify(f).admissionQualified, true);
});

test('rejects a cached admission that regresses the completed candidate observation', () => {
  let f = crossProofAcceptanceFixture(11170, 189.92999, 11180, 189.94);
  const proof = f.candidateProof.campaigns[1].measurement;
  Object.assign(proof.probeBinding.final, {
    acceptedPayloadBytes: String(11185 * 1316),
    lastAcceptedAt: 189.945,
    leaseDeadline: 190.20000000000002,
    observedAt: 189.946,
  });
  proof.probeBinding.completedAt = 189.947;
  proof.closedAt = 189.948;
  f.lifecycle.profileRequests[2].probeBinding.candidateCompletedAt = 189.947;
  f = withRepeatedAdmissionWitnesses(f);
  assert.throws(() => qualify(f), /Admission regressed completed candidate/);
});

test('rejects a later interval read that regresses the completed candidate observation', () => {
  const raw = repeatedReceiverIntervalFixture();
  const proof = raw.candidateProof.campaigns[1].measurement;
  Object.assign(proof.probeBinding.final, {
    acceptedPayloadBytes: String(10981 * 1316),
    lastAcceptedAt: 189.702,
    observedAt: 189.705,
    leaseDeadline: 190,
  });
  proof.probeBinding.completedAt = 189.706;
  proof.closedAt = 189.707;
  raw.lifecycle.profileRequests[2].probeBinding.candidateCompletedAt = 189.706;
  const f = withRepeatedAdmissionWitnesses(raw);
  assert.throws(() => qualify(f), /Known-order native observation regressed/);
});
