import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { deliverySnapshot } from '../../packages/protocol/dist/index.js';

// Synthetic scalar evidence only: these tests do not qualify capture or relay hardware.
const id = (n) => `${String(n).padStart(8, '0')}-1111-4111-8111-111111111111`;
const time = (i) => ({ value: String(270000 + i * 1000), timescale: 30000, epoch: '0', flags: 1 });
function fixture() {
  const scope = {
    recordingID: 'recording',
    matchID: 'match',
    broadcastGeneration: 2,
    publishingAttemptID: id(1),
    appliedProfileRevision: '0',
  };
  const configuration = { id: id(2), encoderSessionID: id(3), bitRate: 500000 };
  const receipt = { generation: '7', configuration, acceptedAt: 9, lastSubmittedPTS: time(0) };
  const clock = { generation: '7', sourceOrigin: time(0) };
  const publication = {
    readerId: id(4),
    publisherId: id(5),
    publishingAttemptId: id(1),
    clock: { convention: 'mpegts-ingress-origin-90k-v1', originPTS: '9000' },
  };
  const context = {
    gameId: 'match',
    generation: 2,
    workerId: 'worker',
    workerEpoch: id(6),
    attempt: 1,
    publication,
  };
  const capture = Array.from({ length: 91 }, (_, i) => ({
    sourcePTS: time(i),
    observedAt: 9 + i / 30,
    encoding: null,
  }));
  const encoded = capture
    .filter((_, i) => i !== 32)
    .map((f) => ({
      ...structuredClone(f),
      observedAt: f.observedAt + 0.002,
      encoding: {
        encoderSessionID: id(3),
        configuration: structuredClone(configuration),
        submittedAt: f.observedAt + 0.001,
        completedAt: f.observedAt + 0.002,
      },
    }));
  const arrivals = capture
    .slice(0, 90)
    .flatMap((f, i) =>
      i === 32
        ? []
        : [[i * 3000, (f.observedAt + (i === 31 ? 1.1 : i === 33 ? 0.98 : 0.1)) * 1000]],
    )
    .sort((a, b) => a[1] - b[1]);
  const packet = {
    formatVersion: 1,
    scopeID: id(7),
    sampledAtMs: 12450,
    coverageAtMs: 0,
    afterOrdinal: 0,
    lastOrdinal: arrivals.length,
    arrivals,
    invalidReason: null,
    ended: false,
  };
  const row = {
    phase: 1,
    start: 10,
    end: 11,
    evaluatedAt: 12.5,
    appliedRevision: '0',
    acknowledgedAt: 9.01,
    profileID: '240p30',
    videoBitrate: 500000,
    attemptID: id(1),
    receipt,
    deliveryReceiptID: id(8),
    sampleAgeSeconds: 0.05,
    clock,
    clockClosed: false,
    clockScope: scope,
    history: {
      scope,
      closed: false,
      invalidity: null,
      omittedCaptureFrames: '0',
      omittedEncodedFrames: '0',
      trimmedCaptureFrames: 0,
      trimmedEncodedFrames: 0,
      capture,
      encoded,
    },
    timeline: deliverySnapshot(packet),
    context,
    diagnostics: { isPublishing: true, clock, receipt, ingressScope: scope, ingressClosed: false },
    anchorSourcePTS: time(89),
    frames: capture.slice(30, 60).map((f, i) => ({
      pts: String((i + 30) * 3000),
      sourcePTS: f.sourcePTS,
      capturedAt: f.observedAt,
      wasEncoded: i !== 2,
    })),
    reason: null,
    result: {
      expectedFrames: 30,
      onTimeFrames: 27,
      lateFrames: 1,
      missingFrames: 1,
      uncertainFrames: 1,
      onTimeFPS: null,
      failureFraction: null,
    },
  };
  const response = {
    serverTime: '2040-01-01T00:00:01.000Z',
    status: {
      ...context,
      state: 'producing_output',
      expiresAt: '2040-01-01T00:00:05.000Z',
      decoderDeliveryAgeUpperBoundMs: 20,
      observation: {
        gameId: 'match',
        generation: 2,
        state: 'producing_output',
        attempt: 1,
        decodedVideo: { clock: 'mpegts-pts-90k-v1' },
        decoderDelivery: packet,
      },
    },
  };
  return {
    scope,
    audit: {
      formatVersion: 1,
      closed: true,
      overflow: false,
      invalid: false,
      latencyBudget: 1,
      maximumSampleAge: 0.25,
      rows: [row],
    },
    reports: {
      formatVersion: 1,
      closed: true,
      overflow: false,
      invalid: false,
      rows: [
        {
          response,
          expectedAttempt: id(1),
          receivedUptime: 12.48,
          evaluatedUptime: 12.49,
          requestSeconds: 0.01,
          residenceSeconds: 0.01,
          deliveryReceiptID: id(8),
          deliverySampleAgeSeconds: 0.04,
        },
      ],
    },
  };
}
let qualify;
test('independent verifier exists and reconciles Swift-shaped scalar evidence', async () => {
  const module = await import('../native-delivery-deadlines.mjs').catch(() => null);
  assert.equal(
    typeof module?.qualifyNativeDeliveryDeadlines,
    'function',
    'independent verifier must exist',
  );
  qualify = module.qualifyNativeDeliveryDeadlines;
  const result = qualify(fixture());
  assert.equal(result.actualNativeDeadlineEvidenceQualified, true);
  assert.equal(result.successfulRows, 1);
  assert.equal(result.counts.onTimeFrames, 27);
  assert.equal(result.counts.lateFrames, 1);
  assert.equal(result.counts.missingFrames, 1);
  assert.equal(result.counts.uncertainFrames, 1);
});

for (const [name, damage] of Object.entries({
  'source PTS': (f, r) => (r.frames[0].sourcePTS.value = '999'),
  'projected PTS': (f, r) => (r.frames[0].pts = '999'),
  'frame count': (f, r) => r.result.expectedFrames++,
  classification: (f, r) => r.result.onTimeFrames++,
  'encoder metadata': (f, r) => r.history.encoded[31].encoding.configuration.bitRate++,
  'anchor provenance': (f, r) => (r.anchorSourcePTS = time(88)),
  'timeline tuple': (f, r) => r.timeline.arrivals[0].ageMs++,
  scope: (f, r) => (r.context.workerId = 'foreign'),
  'current receipt': (f, r) => (r.diagnostics.receipt = { ...r.receipt, acceptedAt: 8 }),
  'freshened sample': (f, r) => (r.sampleAgeSeconds = 0.01),
  'freshened report': (f) => (f.reports.rows[0].deliverySampleAgeSeconds = 0.001),
  'stale sample': (f, r) => (r.sampleAgeSeconds = 0.3),
  'receipt identity': (f, r) => (r.deliveryReceiptID = id(99)),
  'capture predecessor': (f, r) => (r.history.capture = r.history.capture.slice(30)),
  'capture completion bracket': (f, r) => (r.history.capture = r.history.capture.slice(0, 60)),
  'encoder completion bracket': (f, r) =>
    (r.history.encoded = r.history.encoded.filter((x) => BigInt(x.sourcePTS.value) < 330000n)),
  'unencoded arrival': (f, r) =>
    (r.history.encoded = r.history.encoded.filter((x) => x.sourcePTS.value !== time(30).value)),
  'overlapping lane': (f, r) => f.audit.rows.push(structuredClone(r)),
  'unbounded rows': (f, r) => (f.audit.rows = Array(257).fill(r)),
  'open audit': (f) => (f.audit.closed = false),
  'missing history closure': (f, r) => delete r.history.closed,
  'invalid counter scope': (f, r) => {
    f.scope.broadcastGeneration = 0;
    f.reports.rows[0].response.status.generation = 0;
    f.reports.rows[0].response.status.observation.generation = 0;
    r.context.generation = 0;
  },
}))
  test(`rejects ${name}`, async () => {
    const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
    const f = fixture();
    damage(f, f.audit.rows[0]);
    assert.throws(() => qualifyNativeDeliveryDeadlines(f));
  });

test('unknown rows remain unknown and do not establish qualification', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture();
  f.audit.rows[0].result = null;
  f.audit.rows[0].reason = 'freshness';
  delete f.audit.rows[0].frames;
  delete f.audit.rows[0].anchorSourcePTS;
  const result = qualifyNativeDeliveryDeadlines(f);
  assert.equal(result.unknownRows, 1);
  assert.equal(result.successfulRows, 0);
  assert.equal(result.actualNativeDeadlineEvidenceQualified, false);
});

test('reconciles actual Swift classifier export against synthetic wire packets', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const audit = JSON.parse(
    readFileSync(new URL('./fixtures/deadline-audit-swift.json', import.meta.url)),
  );
  const r = audit.rows[0],
    t = r.timeline,
    sampledAtMs = t.coverageAgeMs;
  const packet = {
    formatVersion: 1,
    scopeID: t.scopeID,
    sampledAtMs,
    coverageAtMs: 0,
    afterOrdinal: 0,
    lastOrdinal: t.lastOrdinal,
    arrivals: t.arrivals.map((a) => [a.pts, sampledAtMs - a.ageMs]),
    invalidReason: null,
    ended: false,
  };
  const f = fixture(),
    raw = f.reports.rows[0];
  raw.response.status = {
    ...r.context,
    state: 'producing_output',
    expiresAt: raw.response.status.expiresAt,
    decoderDeliveryAgeUpperBoundMs: 0,
    observation: {
      gameId: r.context.gameId,
      generation: r.context.generation,
      state: 'producing_output',
      attempt: r.context.attempt,
      decodedVideo: { clock: 'mpegts-pts-90k-v1' },
      decoderDelivery: packet,
    },
  };
  Object.assign(raw, {
    expectedAttempt: r.attemptID,
    receivedUptime: r.evaluatedAt,
    evaluatedUptime: r.evaluatedAt,
    requestSeconds: 0,
    residenceSeconds: 0,
    deliverySampleAgeSeconds: 0,
    deliveryReceiptID: r.deliveryReceiptID,
  });
  const result = qualifyNativeDeliveryDeadlines({
    audit,
    reports: f.reports,
    scope: r.history.scope,
  });
  assert.equal(result.successfulRows, 3);
  assert.equal(result.counts.expectedFrames, 120);
  assert.equal(result.observations.healthyRows, 1);
  assert.equal(result.observations.below24FPSRows, 0);
  assert.equal(result.lanes.length, 2);
});

function splitReports(f) {
  const current = f.reports.rows[0],
    earlier = structuredClone(current);
  earlier.deliveryReceiptID = id(9);
  earlier.receivedUptime -= 0.2;
  earlier.evaluatedUptime -= 0.2;
  const p = earlier.response.status.observation.decoderDelivery;
  p.arrivals = p.arrivals.slice(0, 60);
  p.lastOrdinal = p.arrivals.length;
  p.sampledAtMs = p.arrivals.at(-1)[1];
  const next = current.response.status.observation.decoderDelivery;
  next.afterOrdinal = p.lastOrdinal;
  next.arrivals = next.arrivals.slice(p.lastOrdinal);
  f.reports.rows.unshift(earlier);
  return f;
}
test('reconstructs incremental packet history and current receipt', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  assert.equal(qualifyNativeDeliveryDeadlines(splitReports(fixture())).successfulRows, 1);
});

test('does not borrow a future report within the clock sampling tolerance', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture();
  f.reports.rows[0].evaluatedUptime = 12.501;
  f.reports.rows[0].receivedUptime = 12.491;
  assert.throws(() => qualifyNativeDeliveryDeadlines(f));
});

test('frozen samples retain the older conservative bound', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    prior = structuredClone(f.reports.rows[0]);
  prior.deliveryReceiptID = id(9);
  prior.receivedUptime -= 0.09;
  prior.evaluatedUptime -= 0.09;
  f.reports.rows.unshift(prior);
  f.reports.rows[1].deliverySampleAgeSeconds = 0.13;
  f.audit.rows[0].sampleAgeSeconds = 0.14;
  assert.equal(qualifyNativeDeliveryDeadlines(f).successfulRows, 1);
  f.reports.rows[1].deliverySampleAgeSeconds = 0.04;
  f.audit.rows[0].sampleAgeSeconds = 0.05;
  assert.throws(() => qualifyNativeDeliveryDeadlines(f));
});

test('repeated frozen reports cannot accumulate freshness tolerance discounts', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    original = f.reports.rows[0];
  f.reports.rows = Array.from({ length: 10 }, (_, i) => ({
    ...structuredClone(original),
    deliveryReceiptID: id(20 + i),
    receivedUptime: 12.39 + i * 0.01,
    evaluatedUptime: 12.4 + i * 0.01,
    deliverySampleAgeSeconds: 0.04 + i * 0.0085,
  }));
  f.audit.rows[0].deliveryReceiptID = id(29);
  f.audit.rows[0].sampleAgeSeconds = 0.04 + 9 * 0.0085 + 0.01;
  assert.throws(() => qualifyNativeDeliveryDeadlines(f), /age/);
});

test('new worker/publication context requires a full packet and cannot reuse old receipt', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    prior = structuredClone(f.reports.rows[0]);
  prior.deliveryReceiptID = id(9);
  prior.receivedUptime -= 0.1;
  prior.evaluatedUptime -= 0.1;
  prior.response.status.workerEpoch = id(10);
  prior.response.status.observation.decoderDelivery.scopeID = id(11);
  f.reports.rows.unshift(prior);
  assert.equal(qualifyNativeDeliveryDeadlines(f).successfulRows, 1);
  f.reports.rows[1].response.status.observation.decoderDelivery.afterOrdinal = 1;
  f.reports.rows[1].response.status.observation.decoderDelivery.arrivals.shift();
  assert.throws(() => qualifyNativeDeliveryDeadlines(f));
});

test('expired prior frozen proof cannot regain freshness from a new response', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    prior = structuredClone(f.reports.rows[0]);
  prior.deliveryReceiptID = id(9);
  prior.receivedUptime -= 0.1;
  prior.evaluatedUptime -= 0.1;
  prior.response.status.expiresAt = '2040-01-01T00:00:01.050Z';
  f.reports.rows.unshift(prior);
  f.reports.rows[1].deliverySampleAgeSeconds = 0.14;
  f.audit.rows[0].sampleAgeSeconds = 0.15;
  assert.throws(() => qualifyNativeDeliveryDeadlines(f), /frozen|Frozen/);
});

test('exact rational projection survives values beyond Number precision and a transport wrap', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = JSON.parse(JSON.stringify(fixture()));
  function shift(value) {
    if (!value || typeof value !== 'object') return;
    if ('timescale' in value) {
      value.value = String(BigInt(value.value) + 9007199254740993n);
      return;
    }
    Object.values(value).forEach(shift);
  }
  shift(f.audit);
  // A negative decoder epoch is selected by a real anchor, never guessed modulo 2^33.
  const wrap = 2 ** 33;
  f.reports.rows[0].response.status.observation.decoderDelivery.arrivals.forEach(
    (a) => (a[0] -= wrap),
  );
  f.audit.rows[0].timeline.arrivals.forEach((a) => (a.pts -= wrap));
  f.audit.rows[0].frames.forEach((a) => (a.pts = String(BigInt(a.pts) - BigInt(wrap))));
  assert.equal(qualifyNativeDeliveryDeadlines(f).counts.expectedFrames, 30);
  f.audit.rows[0].frames[0].pts = String(BigInt(f.audit.rows[0].frames[0].pts) + 1n);
  assert.throws(() => qualifyNativeDeliveryDeadlines(f));
});

test('equivalent rational timescales retain exact floor projection', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = JSON.parse(JSON.stringify(fixture()));
  for (const frame of [
    ...f.audit.rows[0].history.capture,
    ...f.audit.rows[0].history.encoded,
    ...f.audit.rows[0].frames,
  ]) {
    frame.sourcePTS.value = String(BigInt(frame.sourcePTS.value) * 7n);
    frame.sourcePTS.timescale *= 7;
  }
  f.audit.rows[0].anchorSourcePTS.value = String(
    BigInt(f.audit.rows[0].anchorSourcePTS.value) * 7n,
  );
  f.audit.rows[0].anchorSourcePTS.timescale *= 7;
  assert.equal(qualifyNativeDeliveryDeadlines(f).successfulRows, 1);
});

test('duplicate arrivals classify using the first arrival only', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    packet = f.reports.rows[0].response.status.observation.decoderDelivery;
  packet.arrivals.push([90000, 11500]);
  packet.arrivals.sort((a, b) => a[1] - b[1]);
  packet.lastOrdinal++;
  f.audit.rows[0].timeline = deliverySnapshot(packet);
  assert.equal(qualifyNativeDeliveryDeadlines(f).counts.onTimeFrames, 27);
});

test('unknown evidence is still bounded', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    row = f.audit.rows[0];
  row.result = null;
  row.reason = 'source';
  delete row.frames;
  delete row.anchorSourcePTS;
  row.history.capture = Array(8193).fill(row.history.capture[0]);
  assert.throws(() => qualifyNativeDeliveryDeadlines(f), /bounded|Bounded/);
});

test('a newly unavailable response invalidates a retained old receipt', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    latest = structuredClone(f.reports.rows[0]);
  latest.evaluatedUptime += 0.005;
  latest.receivedUptime += 0.005;
  latest.deliveryReceiptID = null;
  latest.deliverySampleAgeSeconds = null;
  delete latest.response.status.observation.decoderDelivery;
  f.reports.rows.push(latest);
  assert.throws(() => qualifyNativeDeliveryDeadlines(f), /current report/);
});

test('reports measured below-24 FPS without requiring healthy media', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    p = f.reports.rows[0].response.status.observation.decoderDelivery,
    r = f.audit.rows[0];
  p.arrivals = p.arrivals.filter(([pts]) => pts < 33 * 3000 || pts > 38 * 3000);
  p.lastOrdinal = p.arrivals.length;
  r.timeline = deliverySnapshot(p);
  r.result = {
    expectedFrames: 30,
    onTimeFrames: 22,
    lateFrames: 1,
    missingFrames: 7,
    uncertainFrames: 0,
    onTimeFPS: 22,
    failureFraction: 8 / 30,
  };
  const result = qualifyNativeDeliveryDeadlines(f);
  assert.equal(result.observations.below24FPSRows, 1);
  assert.equal(result.observations.healthyRows, 0);
  assert.equal(result.actualNativeDeadlineEvidenceQualified, true);
  assert.equal(result.automaticAdaptationQualified, false);
  assert.equal(result.recoveryQualified, false);
});

test('tracker exhaustion remains sticky when the last accepted owner returns', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    original = f.reports.rows[0],
    native = f.audit.rows[0];
  f.reports.rows = Array.from({ length: 65 }, (_, index) => {
    const row = structuredClone(original);
    row.receivedUptime -= (64 - index) * 0.01;
    row.evaluatedUptime -= (64 - index) * 0.01;
    row.deliveryReceiptID = id(1000 + index);
    if (index < 64) row.response.status.workerEpoch = id(2000 + index);
    return row;
  });
  native.deliveryReceiptID = f.reports.rows.at(-1).deliveryReceiptID;
  assert.equal(
    qualifyNativeDeliveryDeadlines(f).successfulRows,
    1,
    '65 distinct owners fill the retirement bound',
  );

  const exhausted = structuredClone(original);
  exhausted.response.status.workerEpoch = id(3000);
  exhausted.receivedUptime += 0.002;
  exhausted.evaluatedUptime += 0.002;
  exhausted.deliveryReceiptID = null;
  exhausted.deliverySampleAgeSeconds = null;
  f.reports.rows.push(exhausted);

  const returning = structuredClone(original);
  returning.receivedUptime += 0.004;
  returning.evaluatedUptime += 0.004;
  returning.deliveryReceiptID = id(3001);
  returning.response.status.observation.decoderDelivery.sampledAtMs += 1;
  f.reports.rows.push(returning);
  native.deliveryReceiptID = returning.deliveryReceiptID;
  native.timeline = deliverySnapshot(returning.response.status.observation.decoderDelivery);
  native.sampleAgeSeconds = 0.046;
  assert.throws(
    () => qualifyNativeDeliveryDeadlines(f),
    /exhausted/i,
    'A fresh full packet cannot resurrect proof after the 66th owner exhausted the tracker',
  );

  returning.deliveryReceiptID = null;
  returning.deliverySampleAgeSeconds = null;
  native.result = null;
  native.reason = 'freshness';
  delete native.frames;
  delete native.anchorSourcePTS;
  const unknown = qualifyNativeDeliveryDeadlines(f);
  assert.equal(unknown.unknownRows, 1);
  assert.equal(unknown.actualNativeDeadlineEvidenceQualified, false);
});

test('clock reconciliation tolerance cannot turn an uncertain arrival into a late one', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    row = f.audit.rows[0],
    packet = f.reports.rows[0].response.status.observation.decoderDelivery;
  packet.arrivals.find(([pts]) => pts === 99000)[1] =
    (row.history.capture[33].observedAt + 0.9995) * 1000;
  packet.arrivals.sort((a, b) => a[1] - b[1]);
  row.timeline = deliverySnapshot(packet);
  row.sampleAgeSeconds = 0.049; // Independently reconstructed age remains .05.
  row.result = {
    expectedFrames: 30,
    onTimeFrames: 27,
    lateFrames: 2,
    missingFrames: 1,
    uncertainFrames: 0,
    onTimeFPS: 27,
    failureFraction: 0.1,
  };
  assert.throws(() => qualifyNativeDeliveryDeadlines(f), /Deadline lateFrames differs/);
  row.result = {
    expectedFrames: 30,
    onTimeFrames: 27,
    lateFrames: 1,
    missingFrames: 1,
    uncertainFrames: 1,
    onTimeFPS: null,
    failureFraction: null,
  };
  assert.equal(qualifyNativeDeliveryDeadlines(f).counts.uncertainFrames, 1);

  // The exported bound wins when it is the larger of the two measurements.
  row.sampleAgeSeconds = 0.051;
  packet.arrivals.find(([pts]) => pts === 99000)[1] =
    (row.history.capture[33].observedAt + 1.0005) * 1000;
  packet.arrivals.sort((a, b) => a[1] - b[1]);
  row.timeline = deliverySnapshot(packet);
  assert.equal(qualifyNativeDeliveryDeadlines(f).counts.uncertainFrames, 1);
});

test('clock reconciliation tolerance cannot bring an independently stale sample within budget', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    raw = f.reports.rows[0],
    row = f.audit.rows[0];
  raw.response.status.decoderDeliveryAgeUpperBoundMs = 221;
  raw.deliverySampleAgeSeconds = 0.241;
  row.sampleAgeSeconds = 0.25; // Independent bound is .251, outside the .25 freshness budget.
  row.result.lateFrames = 0;
  row.result.uncertainFrames = 2;
  assert.throws(() => qualifyNativeDeliveryDeadlines(f), /sample age.*stale/);
});

test('clock reconciliation tolerance cannot claim completed deadline coverage', async () => {
  const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
  const f = fixture(),
    raw = f.reports.rows[0],
    row = f.audit.rows[0],
    packet = raw.response.status.observation.decoderDelivery;
  row.evaluatedAt = row.frames.at(-1).capturedAt + 1 + 0.0495;
  row.sampleAgeSeconds = 0.049;
  raw.evaluatedUptime = row.evaluatedAt - 0.01;
  raw.receivedUptime = raw.evaluatedUptime - 0.01;
  packet.sampledAtMs = (row.evaluatedAt - 0.05) * 1000;
  packet.arrivals = packet.arrivals.filter(([pts]) => pts < 180000);
  packet.lastOrdinal = packet.arrivals.length;
  row.timeline = deliverySnapshot(packet);
  row.anchorSourcePTS = time(packet.arrivals.at(-1)[0] / 3000);
  assert.throws(() => qualifyNativeDeliveryDeadlines(f), /Incomplete deadline history coverage/);
});
