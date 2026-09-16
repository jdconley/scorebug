import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyNativeQuality } from '../native-quality-qualification.mjs';
function fixture() {
  const receipt = {
    generation: '1',
    configurationID: '11111111-1111-1111-1111-111111111111',
    encoderSessionID: '22222222-2222-2222-2222-222222222222',
    bitRate: 6000000,
    acceptedAt: 0,
  };
  const quality = {
    formatVersion: 1,
    overflow: false,
    events: [{ kind: 'bootstrap', at: 0.1, revision: '0', acknowledgedAt: 0.1, receipt }],
  };
  const snapshot = {
      scope: { publishingAttemptID: '33333333-3333-3333-3333-333333333333' },
      sourceIntervals: [],
    },
    sourceIntervalQualification = { intervals: [] };
  for (let i = 0; i < 6; i++) {
    const start = 1 + i * 5,
      end = start + 5,
      sequence = String(i + 2),
      source = {
        workerEpoch: 'epoch',
        workerAttempt: 1,
        sequence,
        start,
        end,
        attemptID: snapshot.scope.publishingAttemptID,
        workerID: 'mac',
        readerID: 'reader',
        processingScopeID: '55555555-5555-5555-5555-555555555555',
      };
    snapshot.sourceIntervals.push({
      sequence,
      workerEpoch: 'epoch',
      workerAttempt: 1,
      captureBoundaryStartTime: start,
      captureBoundaryEndTime: end,
      encodingConfiguration: {
        id: receipt.configurationID,
        encoderSessionID: receipt.encoderSessionID,
        bitRate: receipt.bitRate,
      },
    });
    sourceIntervalQualification.intervals.push({
      sequence: i + 2,
      capturedFrames: 150,
      encodedFrames: 150,
      decodedFrames: 150,
    });
    quality.events.push({
      kind: 'evaluated',
      at: end + 0.25,
      revision: '0',
      receipt,
      source,
      reasons: ['missingCapacity'],
      window: {
        sequence: String(i + 1),
        revision: '0',
        start,
        end,
        captured: 150,
        encoded: 150,
        received: 150,
        observedAt: end,
        expected: 150,
        lost: 0,
        queue: 0,
        capacity: null,
        thermal: 'nominal',
        worker: 'nominal',
        transport: 'nominal',
      },
    });
  }
  const next = {
    ...receipt,
    configurationID: '44444444-4444-4444-4444-444444444444',
    bitRate: 6600000,
    acceptedAt: 31.4,
  };
  quality.events.push({
    kind: 'applied',
    at: 31.5,
    acknowledgedAt: 31.5,
    revision: '1',
    receipt: next,
    action: { kind: 'trial', bitRate: 6600000, fromRevision: '0', validUntil: 33 },
  });
  quality.events.push({ kind: 'stopped', at: 32, revision: '1', receipt: next, closed: true });
  return evidence({ quality, snapshot, sourceIntervalQualification });
}
test('qualifies verified native trial after30 seconds of matched strong source evidence', () =>
  assert.equal(qualifyNativeQuality(fixture()).trials, 1));
for (const [name, mutate] of Object.entries({
  scope: (f) => (f.quality.events[1].source.attemptID = 'other'),
  receipt: (f) =>
    (f.quality.events[7].receipt.configurationID = f.quality.events[0].receipt.configurationID),
  stale: (f) => (f.quality.events[1].at = 100),
  source: (f) => (f.sourceIntervalQualification.intervals[0].decodedFrames = 149),
  config: (f) => (f.snapshot.sourceIntervals[0].encodingConfiguration.bitRate = 1),
  pressure: (f) => (f.quality.events[1].window.worker = 'unknown'),
  step: (f) => (f.quality.events[7].receipt.bitRate = 9000000),
  deadline: (f) => (f.quality.events[7].at = 34),
  stopped: (f) => (f.quality.events.at(-1).closed = false),
  overflow: (f) => (f.quality.overflow = true),
  trial: (f) => f.quality.events.splice(7, 1),
}))
  test(`rejects native quality ${name} mismatch`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualifyNativeQuality(f));
  });
function probation(f, { bad, rejected, scope, gap, jitter, firstStart = 32 } = {}) {
  const trial = f.quality.events.at(-2);
  f.quality.events.pop();
  if (rejected) f.quality.events.push({ kind: 'rejected', at: 31.6 });
  let start = firstStart;
  for (let index = 0; index < (bad || jitter ? 3 : 2); index++) {
    const row = structuredClone(f.quality.events[6]);
    const duration = bad && index === 0 ? 1 : jitter && index === 0 ? 4.99997975 : 5;
    if (gap && index === 1) start += 0.1;
    const end = start + duration;
    row.at = end + 0.25;
    row.revision = '1';
    row.receipt = trial.receipt;
    row.window = {
      ...row.window,
      start,
      end,
      sequence: String(7 + index),
      revision: '1',
      captured: Math.round(duration * 30),
      encoded: Math.round(duration * 30),
      received: Math.round(duration * 30),
      expected: Math.round(duration * 30),
    };
    row.window.observedAt = end;
    if (bad && index === 0) row.window.worker = 'unknown';
    row.source = {
      ...row.source,
      start,
      end,
      sequence: String(8 + index),
      workerEpoch: scope ? 'new-epoch' : 'epoch',
    };
    row.reasons = index === (bad || jitter ? 2 : 1) ? ['trialConfirmed'] : [];
    const source = {
      ...structuredClone(f.snapshot.sourceIntervals[5]),
      ...row.source,
      captureBoundaryStartTime: start,
      captureBoundaryEndTime: end,
      encodingConfiguration: {
        id: trial.receipt.configurationID,
        encoderSessionID: trial.receipt.encoderSessionID,
        bitRate: trial.receipt.bitRate,
      },
    };
    f.snapshot.sourceIntervals.push(source);
    f.sourceIntervalQualification.intervals.push({
      sequence: Number(row.source.sequence),
      capturedFrames: Math.round(duration * 30),
      encodedFrames: Math.round(duration * 30),
      decodedFrames: Math.round(duration * 30),
    });
    f.quality.events.push(row);
    start = end;
  }
  f.quality.events.push({
    kind: 'stopped',
    at: start + 0.5,
    revision: '1',
    receipt: trial.receipt,
    closed: true,
  });
  return evidence(f);
}
test('confirms uninterrupted post-acknowledgment probation', () =>
  assert.equal(qualifyNativeQuality(probation(fixture())).confirmed, 1));
for (const cause of ['bad', 'rejected', 'scope', 'gap'])
  test(`never confirms after probation ${cause}`, () => {
    assert.throws(() => qualifyNativeQuality(probation(fixture(), { [cause]: true })));
  });
test('rejects advice with an invented extended deadline', () => {
  const f = fixture();
  f.quality.events[7].action.validUntil = 60;
  f.quality.events[7].at = f.quality.events[7].acknowledgedAt = 50;
  f.quality.events.at(-1).at = 51;
  assert.throws(() => qualifyNativeQuality(f));
});

function evidence(f) {
  for (const row of f.quality.events.filter((e) => e.kind === 'evaluated')) {
    const w = row.window,
      s = f.snapshot.sourceIntervals.find((s) => s.sequence === row.source.sequence);
    s.workerId = row.source.workerID;
    s.publishingGeneration = row.receipt.generation;
    s.publication = { readerId: row.source.readerID };
    s.previousSequence = String(Number(s.sequence) - 1);
    s.previousDecodedPTS = String(Math.round(w.start * 90000));
    s.firstDecodedPTS = String(Math.round(w.start * 90000) + 3000);
    s.lastDecodedPTS = String(Math.round(w.end * 90000));
    const processing = {
      encoder: 'videotoolbox',
      scopeID: row.source.processingScopeID,
      sequence: Number(s.sequence),
      previousSequence: Number(s.previousSequence),
      firstPTS: Number(s.firstDecodedPTS),
      interval: {
        sourceStartExclusive: Number(s.previousDecodedPTS),
        sourceEndInclusive: Number(s.lastDecodedPTS),
        decodedFrames: w.received,
        submittedFrames: w.received,
        completedFrames: w.received,
        pendingFrames: 0,
        omittedBeforeEncoderFrames: 0,
        filterDuration: { meanMs: 1, maximumMs: 2 },
        processingDuration: { meanMs: 400, maximumMs: 450 },
      },
    };
    const thermal = [],
      transport = [];
    for (let t = w.start; t <= w.end; t += 0.5) {
      thermal.push({ sampledAt: t, state: 0 });
      transport.push({
        sampledAt: t,
        generation: '1',
        elapsedMilliseconds: String(Math.round(t * 1000)),
        sentBytes: String(Math.round(t * 100000)),
        retransmittedBytes: '0',
        droppedPackets: 0,
        rttMilliseconds: 2,
        senderBufferMilliseconds: 10,
      });
    }
    if (thermal.at(-1).sampledAt !== w.end) {
      thermal.push({ sampledAt: w.end, state: 0 });
      transport.push({ ...transport.at(-1), sampledAt: w.end });
    }
    row.evaluatedAt = row.at;
    row.evidence = {
      thermal: { isClosed: false, isQuarantined: false, samples: thermal },
      transport: { isClosed: false, isQuarantined: false, samples: transport },
      queue: {
        scope: f.snapshot.scope,
        isClosed: false,
        isQuarantined: false,
        coveredThrough: w.end,
        states: [{ at: w.start, itemFraction: 0, byteFraction: 0, phase: 'admitting' }],
      },
      processing: structuredClone(processing),
    };
    s.processing = processing;
    if (w.worker === 'unknown') {
      row.evidence.processing.interval.completedFrames--;
      row.evidence.processing.interval.pendingFrames++;
      delete row.evidence.processing.interval.processingDuration;
    }
  }
  return f;
}
for (const [name, corrupt] of Object.entries({
  missing: (r) => delete r.evidence,
  thermal: (r) => (r.evidence.thermal.samples[2].state = 2),
  transport: (r) => (r.evidence.transport.samples[2].senderBufferMilliseconds = 501),
  gap: (r) => r.evidence.thermal.samples.splice(1, 5),
  counter: (r) => (r.evidence.transport.samples[2].sentBytes = '0'),
  queue: (r) => (r.evidence.queue.states[0].itemFraction = 0.75),
  scope: (r) => (r.evidence.queue.scope = { ...r.evidence.queue.scope, recordingID: 'other' }),
  worker: (r) => r.evidence.processing.interval.completedFrames--,
}))
  test(`rejects fabricated nominal pressure: ${name}`, () => {
    const f = fixture();
    corrupt(f.quality.events[1]);
    assert.throws(() => qualifyNativeQuality(f));
  });
test('qualifies a native rollback after probation evidence is rejected', () => {
  const f = fixture(),
    applied = f.quality.events.at(-2);
  f.quality.events.pop();
  f.quality.events.push({ kind: 'rejected', at: 32, reason: 'freshness' });
  const receipt = {
    ...applied.receipt,
    configurationID: '66666666-6666-6666-6666-666666666666',
    bitRate: 6000000,
    acceptedAt: 47.1,
  };
  f.quality.events.push({
    kind: 'applied',
    at: 47.2,
    acknowledgedAt: 47.2,
    revision: '2',
    receipt,
    action: { kind: 'rollback', bitRate: 6000000, fromRevision: '1', validUntil: 49 },
  });
  f.quality.events.push({ kind: 'stopped', at: 48, revision: '2', receipt, closed: true });
  assert.equal(qualifyNativeQuality(f).rollbacks, 1);
});
test('rejects a new trial during the rollback cooldown', () => {
  const f = fixture();
  f.quality.events.pop();
  const rollback = {
    ...f.quality.events[7].receipt,
    bitRate: 6000000,
    acceptedAt: 47.1,
    configurationID: '66666666-6666-6666-6666-666666666666',
  };
  f.quality.events.push({
    kind: 'applied',
    at: 47.2,
    acknowledgedAt: 47.2,
    revision: '2',
    receipt: rollback,
    action: { kind: 'rollback', bitRate: 6000000, fromRevision: '1', validUntil: 49 },
  });
  for (let i = 0; i < 6; i++) {
    const row = structuredClone(f.quality.events[i + 1]);
    row.at += 47;
    row.evaluatedAt += 47;
    row.revision = '2';
    row.receipt = rollback;
    row.source.start += 47;
    row.source.end += 47;
    row.source.sequence = String(20 + i);
    row.window.start += 47;
    row.window.end += 47;
    row.window.observedAt += 47;
    row.window.revision = '2';
    row.window.sequence = String(7 + i);
    f.quality.events.push(row);
    const source = structuredClone(f.snapshot.sourceIntervals[i]);
    source.sequence = row.source.sequence;
    source.captureBoundaryStartTime += 47;
    source.captureBoundaryEndTime += 47;
    source.encodingConfiguration.id = rollback.configurationID;
    f.snapshot.sourceIntervals.push(source);
    f.sourceIntervalQualification.intervals.push({
      ...f.sourceIntervalQualification.intervals[i],
      sequence: Number(source.sequence),
    });
  }
  const next = {
    ...rollback,
    bitRate: 6600000,
    acceptedAt: 78.4,
    configurationID: '77777777-7777-7777-7777-777777777777',
  };
  f.quality.events.push({
    kind: 'applied',
    at: 78.5,
    acknowledgedAt: 78.5,
    revision: '3',
    receipt: next,
    action: { kind: 'trial', bitRate: 6600000, fromRevision: '2', validUntil: 80 },
  });
  f.quality.events.push({ kind: 'stopped', at: 79, revision: '3', receipt: next, closed: true });
  evidence(f);
  assert.throws(() => qualifyNativeQuality(f));
});
test('allows a late log entry when its evaluation was fresh', () => {
  const f = fixture();
  f.quality.events[1].at = 8.5;
  assert.equal(qualifyNativeQuality(f).trials, 1);
});
test('rejects receiver timestamps newer than evaluation', () => {
  const f = fixture();
  f.quality.events[1].window.observedAt = 6.4;
  f.quality.events[1].at = 6.5;
  assert.throws(() => qualifyNativeQuality(f));
});
for (const history of ['thermal', 'transport', 'queue'])
  for (const flag of ['isClosed', 'isQuarantined'])
    test(`requires explicit ${history} ${flag}`, () => {
      const f = fixture();
      delete f.quality.events[1].evidence[history][flag];
      assert.throws(() => qualifyNativeQuality(f));
    });
test('permits a confirmation evaluated before deadline but logged later', () => {
  const f = probation(fixture());
  f.quality.events.at(-2).at = 46.6;
  f.quality.events.at(-1).at = 46.7;
  assert.equal(qualifyNativeQuality(f).confirmed, 1);
});

test('rejects a receipt from another publishing generation', () => {
  const f = fixture();
  f.snapshot.sourceIntervals[0].publishingGeneration = '2';
  assert.throws(() => qualifyNativeQuality(f));
});

test('confirms a jittered trial with a third window beyond the former deadline', () => {
  const f = probation(fixture(), { jitter: true, firstStart: 36 });
  assert.equal(qualifyNativeQuality(f).confirmed, 1);
});
test('never rounds two short probation windows up to ten seconds', () => {
  const f = probation(fixture(), { jitter: true, firstStart: 36 });
  f.quality.events.splice(-2, 1);
  f.quality.events.at(-2).reasons = ['trialConfirmed'];
  assert.throws(() => qualifyNativeQuality(f));
});
test('rejects confirmation following an excessively late first probation window', () => {
  assert.throws(() => qualifyNativeQuality(probation(fixture(), { firstStart: 36.750001 })));
});
test('requires a confirmed trial when the fixture requests confirmation', () => {
  assert.throws(() => qualifyNativeQuality({ ...fixture(), requireConfirmation: true }));
  assert.equal(
    qualifyNativeQuality({ ...probation(fixture()), requireConfirmation: true }).confirmed,
    1,
  );
});
