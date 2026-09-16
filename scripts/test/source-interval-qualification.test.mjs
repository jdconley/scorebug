import test from 'node:test';
import assert from 'node:assert/strict';
import { qualifySourceIntervals } from '../source-interval-qualification.mjs';

const pts = (frame) => ({ value: String(7395 + frame * 2), timescale: 60, epoch: '0', flags: 1 });
function fixture() {
  const scope = {
    recordingID: 'recording',
    matchID: 'match',
    broadcastGeneration: 1,
    publishingAttemptID: 'D4A30CA1-2222-4444-8888-000000000001',
    appliedProfileRevision: '1',
  };
  const publication = {
    readerId: 'reader',
    publisherId: 'publisher',
    publishingAttemptId: scope.publishingAttemptID.toLowerCase(),
    clock: { convention: 'mpegts-ingress-origin-90k-v1', originPTS: '10919' },
  };
  const decoderPTS = (frame) => frame * 3000 - 1919;
  const decodedEvidence = [1, 2, 3].map((sequence) => ({
    gameId: 'match',
    generation: 1,
    workerId: 'mac',
    attempt: 1,
    clock: 'mpegts-pts-90k-v1',
    ended: false,
    invalidReason: null,
    completed: {
      sequence,
      durationMs: 5000,
      ageMs: 100,
      valid: true,
      duplicateFrames: 0,
      reorderedFrames: 0,
      freshFrames: 150,
      firstPTS: decoderPTS((sequence - 1) * 150),
      lastPTS: decoderPTS(sequence * 150 - 1),
    },
  }));
  const sourceIntervals = [2, 3].map((sequence) => {
    const start = (sequence - 1) * 150 - 1,
      end = sequence * 150 - 1;
    return {
      scope,
      workerId: 'mac',
      workerEpoch: 'epoch',
      workerAttempt: 1,
      publication,
      previousSequence: String(sequence - 1),
      sequence: String(sequence),
      previousDecodedPTS: String(decoderPTS(start)),
      firstDecodedPTS: String(decoderPTS(start + 1)),
      lastDecodedPTS: String(decoderPTS(end)),
      publishingGeneration: '1',
      sourceStartExclusive: pts(start),
      sourceEndInclusive: pts(end),
      captureBoundaryStartTime: 10 + start / 30,
      captureBoundaryEndTime: 10 + end / 30,
      capturedFrames: 150,
      encodedFrames: 150,
      decodedFrames: 150,
      captureNotEncodedFrames: 0,
      encodedNotDecodedFrames: 0,
      leadingMissingEncodedFrames: 0,
    };
  });
  return {
    snapshot: { scope, monotonicAnchor: 10, captureDetachedAt: 30, sourceIntervals },
    videoObservation: {
      scope,
      sourceRanges: Object.fromEntries(
        ['captureVideo', 'encodedVideo'].map((stage) => [
          stage,
          { firstSourceFrame: 0, lastSourceFrame: 599, sourceFrames: 600 },
        ]),
      ),
    },
    publishingClockObservation: {
      scope,
      publishingGeneration: '1',
      sourceOrigin: pts(0),
      timescale: 90000,
      presentationLead: '9000',
      wireModulus: '8589934592',
    },
    workerPublicationEvidence: [
      {
        gameId: 'match',
        generation: 1,
        recordingId: 'recording',
        workerId: 'mac',
        workerEpoch: 'epoch',
        attempt: 1,
        publication,
        completedWindows: [1, 2, 3],
      },
    ],
    decodedEvidence,
    archiveIDs: Array.from({ length: 600 }, (_, i) => i),
    liveIDs: Array.from({ length: 600 }, (_, i) => i),
  };
}
test('qualifies two runtime intervals with independently counted frame identities', () => {
  const result = qualifySourceIntervals(fixture());
  assert.equal(result.intervals.length, 2);
  assert.deepEqual(
    result.intervals.map((x) => [x.capturedFrames, x.encodedFrames, x.decodedFrames]),
    [
      [150, 150, 150],
      [150, 150, 150],
    ],
  );
});
test('counts five leading lost frames instead of narrowing the denominator', () => {
  const f = fixture(),
    row = f.snapshot.sourceIntervals[0],
    window = f.decodedEvidence[1].completed;
  row.firstDecodedPTS = String(Number(row.firstDecodedPTS) + 15000);
  row.decodedFrames = window.freshFrames = 145;
  window.firstPTS += 15000;
  row.encodedNotDecodedFrames = row.leadingMissingEncodedFrames = 5;
  f.liveIDs = f.liveIDs.filter((id) => id < 150 || id >= 155);
  const result = qualifySourceIntervals(f);
  assert.equal(result.intervals[0].encodedNotDecodedFrames, 5);
  assert.equal(result.intervals[0].encodedFrames, 150);
});
for (const [label, mutate] of Object.entries({
  'missing runtime evidence': (f) => {
    delete f.snapshot.sourceIntervals;
  },
  'only one interval': (f) => {
    f.snapshot.sourceIntervals.pop();
  },
  'duplicate interval': (f) => {
    f.snapshot.sourceIntervals.push(structuredClone(f.snapshot.sourceIntervals[1]));
  },
  'reversed intervals': (f) => {
    f.snapshot.sourceIntervals.reverse();
  },
  'scope mismatch': (f) => {
    f.snapshot.sourceIntervals[0].scope = { ...f.snapshot.scope, recordingID: 'other' };
  },
  'native generation mismatch': (f) => {
    f.snapshot.sourceIntervals[0].publishingGeneration = '2';
  },
  'wrong actual native origin': (f) => {
    f.publishingClockObservation.sourceOrigin = pts(1);
  },
  'wrong source endpoint': (f) => {
    f.snapshot.sourceIntervals[0].sourceEndInclusive = pts(298);
  },
  'wrong capture count': (f) => {
    f.snapshot.sourceIntervals[0].capturedFrames = 149;
  },
  'wrong encoder count': (f) => {
    f.snapshot.sourceIntervals[0].encodedFrames = 149;
  },
  'wrong decoder count': (f) => {
    f.snapshot.sourceIntervals[0].decodedFrames = 149;
  },
  'wrong leading loss': (f) => {
    f.snapshot.sourceIntervals[0].leadingMissingEncodedFrames = 1;
  },
  'wrong loss total': (f) => {
    f.snapshot.sourceIntervals[0].encodedNotDecodedFrames = 1;
  },
  'missing archive frame': (f) => {
    f.archiveIDs.splice(170, 1);
  },
  'missing live frame': (f) => {
    f.liveIDs.splice(170, 1);
  },
  'duplicate live frame': (f) => {
    f.liveIDs[170] = 169;
  },
  'missing association': (f) => {
    f.workerPublicationEvidence = [];
  },
  'ambiguous reporting epoch': (f) => {
    f.workerPublicationEvidence.push({ ...f.workerPublicationEvidence[0], workerEpoch: 'other' });
  },
  'unassociated window': (f) => {
    f.workerPublicationEvidence[0].completedWindows = [1, 3];
  },
  'missing decoder window': (f) => {
    f.decodedEvidence.splice(1, 1);
  },
  'contradictory decoder window': (f) => {
    const d = structuredClone(f.decodedEvidence[1]);
    d.completed.freshFrames--;
    f.decodedEvidence.push(d);
  },
  'unknown decoder clock': (f) => {
    f.decodedEvidence[1].clock = 'unknown';
  },
  'ended decoder': (f) => {
    f.decodedEvidence[1].ended = true;
  },
  'invalid decoder window': (f) => {
    f.decodedEvidence[1].completed.valid = false;
  },
  'reordered decoder frames': (f) => {
    f.decodedEvidence[1].completed.reorderedFrames = 1;
  },
  'skipped sequence': (f) => {
    f.snapshot.sourceIntervals[1].previousSequence = '1';
  },
  'noncanonical sequence': (f) => {
    f.snapshot.sourceIntervals[0].sequence = '02';
  },
  'loss of PTS precision': (f) => {
    f.snapshot.sourceIntervals[0].lastDecodedPTS = Number(
      f.snapshot.sourceIntervals[0].lastDecodedPTS,
    );
  },
  'callback outside recording': (f) => {
    f.snapshot.sourceIntervals[0].captureBoundaryStartTime = 0;
  },
  'missing source provenance': (f) => {
    f.videoObservation.sourceRanges.encodedVideo.firstSourceFrame = 150;
  },
}))
  test(`rejects ${label}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualifySourceIntervals(f));
  });

test('accepts signed decoder coordinates and 33-bit unwrapping with the actual origin', () => {
  const f = fixture();
  for (const sample of f.decodedEvidence) {
    sample.completed.firstPTS -= 2 ** 33;
    sample.completed.lastPTS -= 2 ** 33;
  }
  for (const row of f.snapshot.sourceIntervals)
    for (const key of ['previousDecodedPTS', 'firstDecodedPTS', 'lastDecodedPTS'])
      row[key] = String(BigInt(row[key]) - (1n << 33n));
  assert.equal(qualifySourceIntervals(f).intervals.length, 2);
});

test('duplicate status ages do not change immutable decoder evidence', () => {
  const f = fixture(),
    duplicate = structuredClone(f.decodedEvidence[1]);
  duplicate.completed.ageMs = 1900;
  f.decodedEvidence.push(duplicate);
  assert.equal(qualifySourceIntervals(f).intervals.length, 2);
});

test('counts interior losses separately from leading losses', () => {
  const f = fixture();
  f.liveIDs = f.liveIDs.filter((id) => id !== 200);
  f.decodedEvidence[1].completed.freshFrames--;
  f.snapshot.sourceIntervals[0].decodedFrames--;
  f.snapshot.sourceIntervals[0].encodedNotDecodedFrames++;
  const interval = qualifySourceIntervals(f).intervals[0];
  assert.equal(interval.encodedNotDecodedFrames, 1);
  assert.equal(interval.leadingMissingEncodedFrames, 0);
});
