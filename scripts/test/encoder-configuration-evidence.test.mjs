import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyEncoderConfiguration } from '../encoder-configuration-evidence.mjs';

const session = '11111111-1111-4111-8111-111111111111';
const id = '22222222-2222-4222-8222-222222222222';
const time = (i) => ({ value: String(i), timescale: 30, epoch: '0', flags: 1 });
function fixture() {
  const configuration = { id, encoderSessionID: session, bitRate: 2000000 };
  return {
    clock: { publishingGeneration: '18446744073709551615', sourceOrigin: time(0) },
    receipt: {
      publishingGeneration: '18446744073709551615',
      configuration,
      acceptedAt: 105,
      lastSubmittedSourcePTS: time(149),
    },
    evidence: {
      overflow: false,
      frames: Array.from({ length: 420 }, (_, i) => ({
        sourcePTS: time(i),
        outputPTS: time(i),
        encoderSessionID: session,
        configuration: i <= 149 ? null : structuredClone(configuration),
        submittedAt: 100 + i / 30,
        completedAt: 106 + i / 30,
      })),
    },
    decodedSourceFrames: Array.from({ length: 420 }, (_, i) => i),
  };
}
test('binds exact receipt to submitted configurations and decoded source identities', () => {
  const result = qualifyEncoderConfiguration(fixture());
  assert.equal(result.lastUnverifiedSourceFrame, 149);
  assert.equal(result.firstVerifiedSourceFrame, 150);
  assert.equal(result.frames, 420);
});
test('delayed completion order does not change source membership', () => {
  const value = fixture();
  value.evidence.frames.reverse();
  assert.equal(qualifyEncoderConfiguration(value).firstVerifiedSourceFrame, 150);
});
test('accepts fixture nanosecond rounding at nonzero origin', () => {
  const value = fixture();
  value.clock.sourceOrigin = { ...time(493), timescale: 4 };
  const shifted = (i) => ({
    ...time(0),
    value: String(123250000000n + (BigInt(i) * 1000000000n + 15n) / 30n),
    timescale: 1000000000,
    flags: 3,
  });
  value.receipt.lastSubmittedSourcePTS = shifted(149);
  value.evidence.frames.forEach((f, i) => {
    f.sourcePTS = shifted(i);
    f.outputPTS = shifted(i);
  });
  assert.equal(qualifyEncoderConfiguration(value).frames, 420);
});
const corruptions = {
  overflow: (v) => {
    v.evidence.overflow = true;
  },
  missingFrame: (v) => {
    v.evidence.frames.pop();
  },
  duplicateFrame: (v) => {
    v.evidence.frames[1] = structuredClone(v.evidence.frames[0]);
  },
  missingDecodedFrame: (v) => {
    v.decodedSourceFrames.pop();
  },
  differentGeneration: (v) => {
    v.receipt.publishingGeneration = '1';
  },
  impreciseGeneration: (v) => {
    v.receipt.publishingGeneration = Number(v.receipt.publishingGeneration);
  },
  outOfRangeGeneration: (v) => {
    v.receipt.publishingGeneration = '18446744073709551616';
    v.clock.publishingGeneration = v.receipt.publishingGeneration;
  },
  invalidUUID: (v) => {
    v.receipt.configuration.id = 'bad';
  },
  wrongSession: (v) => {
    v.evidence.frames[0].encoderSessionID = id;
  },
  wrongConfiguration: (v) => {
    v.evidence.frames[160].configuration.id = session;
  },
  oldRelabeled: (v) => {
    v.evidence.frames[149].configuration = v.receipt.configuration;
  },
  newUnlabeled: (v) => {
    v.evidence.frames[150].configuration = null;
  },
  wrongBoundary: (v) => {
    v.receipt.lastSubmittedSourcePTS = time(150);
  },
  differentBoundaryRational: (v) => {
    v.receipt.lastSubmittedSourcePTS.value = '4966666667';
    v.receipt.lastSubmittedSourcePTS.timescale = 1000000000;
  },
  offCadence: (v) => {
    v.evidence.frames[8].sourcePTS.value = '9';
  },
  changedOutput: (v) => {
    v.evidence.frames[8].outputPTS.value = '9';
  },
  invalidTime: (v) => {
    v.evidence.frames[8].sourcePTS.flags = 5;
  },
  wrongEpoch: (v) => {
    v.evidence.frames[8].sourcePTS.epoch = '1';
  },
  lateOldSubmission: (v) => {
    v.evidence.frames[0].submittedAt = 105.1;
  },
  earlyNewSubmission: (v) => {
    v.evidence.frames[150].submittedAt = 104;
  },
  backwardsCompletion: (v) => {
    v.evidence.frames[0].completedAt = 99;
  },
  nonfiniteAcceptance: (v) => {
    v.receipt.acceptedAt = Infinity;
  },
  wrongBitrate: (v) => {
    v.receipt.configuration.bitRate = 3000000;
  },
};
for (const [name, corrupt] of Object.entries(corruptions))
  test(`rejects ${name}`, () => {
    const value = fixture();
    corrupt(value);
    assert.throws(() => qualifyEncoderConfiguration(value));
  });
