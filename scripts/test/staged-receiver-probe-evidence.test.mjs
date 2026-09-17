import assert from 'node:assert/strict';
import test from 'node:test';
import {
  qualifyReceiverProbeEvidence,
  validateReceiverProbeSnapshot,
} from '../receiver-probe-evidence.mjs';
import { stagedProbeEvidence } from './fixtures/staged-probe-evidence.mjs';
const qualify = (f) => qualifyReceiverProbeEvidence(f.records, f.scope, f.accepted);
test('combined headroom rates must match the explicitly qualified sender schedule', () => {
  const f = stagedProbeEvidence();
  f.accepted.schedule = 'candidate-headroom-v1';
  for (const stage of f.accepted.stages)
    stage.bitRate = [500000, 2000000, 12000000][stage.stage - 1];
  for (const record of f.records)
    record.probe.bitRate = [500000, 2000000, 12000000][record.probe.stage - 1];
  assert.equal(qualify(f).stageCount, 3);
  delete f.accepted.schedule;
  assert.throws(() => qualify(f));
  f.accepted.schedule = 'unknown';
  assert.throws(() => qualify(f));
});
test('staged receiver snapshots allow HD rates without widening legacy probes', () => {
  const p = stagedProbeEvidence().records[0].probe;
  for (const bitRate of [2000001, 6000000, 12000000])
    assert.equal(validateReceiverProbeSnapshot({ ...p, bitRate }).bitRate, bitRate);
  for (const bitRate of [0, 12000001, Infinity, 1.5])
    assert.throws(() => validateReceiverProbeSnapshot({ ...p, bitRate }));
  const { stage, totalDeliveredPayloadBytes, ...legacy } = p;
  legacy.convention = 'mpegts-null-probe-v1';
  assert.equal(validateReceiverProbeSnapshot({ ...legacy, bitRate: 2000000 }).bitRate, 2000000);
  for (const bitRate of [2000001, 12000000])
    assert.throws(() => validateReceiverProbeSnapshot({ ...legacy, bitRate }));
});
test('reconciles three authenticated stage histories with one cumulative budget', () => {
  const f = stagedProbeEvidence(),
    result = qualify(f);
  assert.equal(result.deliveredPayloadBytes, f.accepted.acceptedPayloadBytes);
  assert.equal(result.stageCount, 3);
  assert.equal(result.receiverCapacityQualified, false);
});
test('next stage cumulative base reconciles a missed terminal prior-stage poll', () => {
  const f = stagedProbeEvidence();
  f.records.splice(2, 1);
  f.records.splice(4, 1);
  assert.equal(qualify(f).deliveredPayloadBytes, f.accepted.acceptedPayloadBytes);
});
const faults = {
  stageRegression: (f) => {
    f.records[4] = structuredClone(f.records[1]);
  },
  unknownStage: (f) => {
    f.records[4].probe.stage = 4;
  },
  missingStage: (f) => {
    f.records = f.records.filter((r) => r.probe.stage !== 2);
  },
  id: (f) => {
    f.records[4].probe.id = f.records[0].probe.id;
  },
  rate: (f) => {
    f.records[4].probe.bitRate = 500000;
  },
  generation: (f) => {
    f.records[4].probe.publishingGeneration = '2';
  },
  publication: (f) => {
    f.records[4].publication.publicationId = '80000000-0000-4000-8000-000000000001';
  },
  resetBudget: (f) => {
    for (const r of f.records.filter((r) => r.probe.stage === 2))
      r.probe.totalDeliveredPayloadBytes = r.probe.deliveredPayloadBytes;
  },
  inflatedBase: (f) => {
    for (const r of f.records.filter((r) => r.probe.stage === 2))
      r.probe.totalDeliveredPayloadBytes = String(
        BigInt(r.probe.totalDeliveredPayloadBytes) + 1316n,
      );
  },
  changingBase: (f) => {
    f.records[4].probe.totalDeliveredPayloadBytes = String(
      BigInt(f.records[4].probe.totalDeliveredPayloadBytes) + 1316n,
    );
  },
  totalOverflow: (f) => {
    f.records[4].probe.totalDeliveredPayloadBytes = '16777217';
  },
  nonaligned: (f) => {
    f.records[4].probe.totalDeliveredPayloadBytes = '1317';
  },
  mixedVersion: (f) => {
    f.records[4].probe.convention = 'mpegts-null-probe-v1';
  },
  receiverClockReset: (f) => {
    for (const r of f.records.filter((r) => r.probe.stage === 2))
      r.probe.observedAtNanoseconds = String(BigInt(r.probe.observedAtNanoseconds) - 4000000000n);
  },
  crossStageClockJump: (f) => {
    for (const r of f.records.filter((r) => r.probe.stage === 2))
      r.request.startedAtMilliseconds += 100;
  },
  firstDeliveryBeforeStage: (f) => {
    f.records[3].probe.firstDeliveredAtNanoseconds = '2000000000';
  },
  timestampReversal: (f) => {
    f.records[4].probe.lastDeliveredAtNanoseconds = '4000000000';
  },
  partialFinal: (f) => {
    f.records.at(-1).probe.pendingPackets = 1;
  },
  missingFinalBytes: (f) => {
    f.records.pop();
  },
  invalidReason: (f) => {
    f.records[4].probe.invalidReason = 'mixedVersion';
  },
  nativeTotalSubstitution: (f) => {
    f.accepted.totalAcceptedPayloadBytes += 1316;
  },
};
for (const [name, mutate] of Object.entries(faults))
  test(`rejects staged receiver ${name}`, () => {
    const f = stagedProbeEvidence();
    mutate(f);
    assert.throws(() => qualify(f));
  });
