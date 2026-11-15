import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyEncoderSourceHistory } from '../encoder-configuration-evidence.mjs';
const session = '11111111-1111-4111-8111-111111111111';
const configuration = {
  id: '22222222-2222-4222-8222-222222222222',
  encoderSessionID: session,
  bitRate: 2000000,
};
const time = (i) => ({ value: String(i), timescale: 30, epoch: '0', flags: 1 });
function fixture() {
  const frames = Array.from({ length: 420 }, (_, i) => ({
    sourcePTS: time(i),
    outputPTS: time(i),
    encoderSessionID: session,
    configuration: i < 150 ? null : structuredClone(configuration),
    submittedAt: 100 + i / 30,
    completedAt: 100.01 + i / 30,
  }));
  return {
    clock: { publishingGeneration: '7', sourceOrigin: time(0) },
    receipt: {
      publishingGeneration: '7',
      configuration,
      acceptedAt: 105,
      lastSubmittedSourcePTS: time(149),
    },
    evidence: { overflow: false, frames },
    decodedSourceFrames: Array.from({ length: 420 }, (_, i) => i),
    history: {
      isClosed: true,
      invalidity: null,
      omittedCaptureFrames: '0',
      omittedEncodedFrames: '0',
      captureFrameCount: 420,
      aggregateValid: true,
      aggregateCaptureCallbacks: '420',
      aggregateEncodedCallbacks: '420',
      encoded: frames.map((f) => ({
        sourcePTS: f.sourcePTS,
        observedAt: f.completedAt + 0.001,
        encoding: {
          encoderSessionID: f.encoderSessionID,
          configuration: f.configuration,
          submittedAt: f.submittedAt,
          completedAt: f.completedAt,
        },
      })),
      intervalProbes: [
        ['before', 0, 149, { state: 'unverified' }],
        ['after', 149, 299, { state: 'verified', configuration }],
        ['crossing', 148, 299, { state: 'mixed' }],
      ].map(([name, start, end, coverage]) => ({
        name,
        sourceStartExclusive: time(start),
        sourceEndInclusive: time(end),
        capturedFrames: end - start,
        encodedFrames: end - start,
        decodedFrames: end - start,
        leadingMissingEncodedFrames: 0,
        coverage,
      })),
    },
  };
}
test('joins all scalar metadata and classifies exact interval probes', () => {
  const result = qualifyEncoderSourceHistory(fixture());
  assert.equal(result.frames, 420);
  assert.deepEqual(result.coverageStates, ['unverified', 'verified', 'mixed']);
});
test('native callback arrival order does not relabel source history', () => {
  const value = fixture();
  value.evidence.frames.reverse();
  assert.equal(qualifyEncoderSourceHistory(value).frames, 420);
});
test('source history accepts rationally equivalent PTS representations', () => {
  const value = fixture();
  value.history.encoded.forEach((frame) => {
    frame.sourcePTS = {
      ...frame.sourcePTS,
      value: String(BigInt(frame.sourcePTS.value) * 2n),
      timescale: 60,
    };
  });
  assert.equal(qualifyEncoderSourceHistory(value).frames, 420);
});
const corruptions = {
  missing: (v) => {
    v.history.encoded.pop();
  },
  unavailable: (v) => {
    v.history.encoded[160].encoding = null;
  },
  relabeled: (v) => {
    v.history.encoded[140].encoding.configuration = configuration;
  },
  wrongSession: (v) => {
    v.history.encoded[160].encoding.encoderSessionID = configuration.id;
  },
  futureCompletion: (v) => {
    v.history.encoded[160].observedAt = 0;
  },
  reversedAdmission: (v) => {
    v.history.encoded[159].observedAt += 1;
  },
  wrongSubmission: (v) => {
    v.history.encoded[160].encoding.submittedAt += 0.001;
  },
  reordered: (v) => {
    [v.history.encoded[1], v.history.encoded[2]] = [v.history.encoded[2], v.history.encoded[1]];
  },
  wrongPTS: (v) => {
    v.history.encoded[160].sourcePTS = time(159);
  },
  wrongConfiguration: (v) => {
    v.history.encoded[160].encoding.configuration = { ...configuration, bitRate: 3000000 };
  },
  openHistory: (v) => {
    v.history.isClosed = false;
  },
  invalidHistory: (v) => {
    v.history.invalidity = 'sourceOrder';
  },
  omittedHistory: (v) => {
    v.history.omittedEncodedFrames = '1';
  },
  duplicateNotification: (v) => {
    v.history.aggregateEncodedCallbacks = '421';
  },
  missingAggregate: (v) => {
    v.history.aggregateValid = false;
  },
  wrongProbeCoverage: (v) => {
    v.history.intervalProbes[2].coverage = { state: 'verified', configuration };
  },
  wrongProbeBoundary: (v) => {
    v.history.intervalProbes[1].sourceStartExclusive = time(148);
  },
  inclusiveAnchor: (v) => {
    v.history.intervalProbes[1].encodedFrames = 151;
  },
  missingProbe: (v) => {
    v.history.intervalProbes.pop();
  },
  wrongLoss: (v) => {
    v.history.intervalProbes[1].leadingMissingEncodedFrames = 1;
  },
};
for (const [name, corrupt] of Object.entries(corruptions))
  test(`rejects history ${name}`, () => {
    const value = fixture();
    corrupt(value);
    assert.throws(() => qualifyEncoderSourceHistory(value));
  });
