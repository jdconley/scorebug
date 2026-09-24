import { qualifyDeliveryAuditEnvelope } from './delivery-audit-envelope.mjs';
import { qualifyCadenceAuditEnvelope } from './cadence-audit-envelope.mjs';
import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { advanceDelivery, deliverySnapshot } from '../packages/protocol/dist/index.js';

const MAX = BigInt(Number.MAX_SAFE_INTEGER),
  INT64 = (1n << 63n) - 1n,
  MOD = 1n << 33n;
const AGE_TOLERANCE = 0.002; // Two native monotonic clocks are sampled separately; never use Node's epoch.
const finite = (n, max = 1e12) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= max;
const uuid = (s) =>
  typeof s === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(s);
const same = (a, b, why) => assert.deepEqual(a, b, why);
const modulo = (n) => ((n % MOD) + MOD) % MOD;
function integer(s, min = 0n, max = (1n << 64n) - 1n) {
  assert(typeof s === 'string' && /^(?:0|-?[1-9][0-9]*)$/.test(s), 'Noncanonical scalar integer');
  const n = BigInt(s);
  assert(n >= min && n <= max, 'Scalar integer outside bounds');
  return n;
}
function cm(t) {
  assert(
    t &&
      Number.isInteger(t.timescale) &&
      t.timescale > 0 &&
      t.timescale <= 2147483647 &&
      t.epoch === '0' &&
      [1, 3].includes(t.flags),
    'Invalid numeric CMTime',
  );
  return { n: integer(t.value, -INT64 - 1n, INT64), d: BigInt(t.timescale) };
}
function compare(a, b) {
  const x = cm(a),
    y = cm(b);
  return x.n * y.d - y.n * x.d;
}
function ticks(source, origin) {
  const a = cm(source),
    b = cm(origin),
    numerator = a.n * b.d - b.n * a.d;
  assert(numerator >= 0n, 'Source precedes transport origin');
  const result = (numerator * 90000n) / (a.d * b.d) + 9000n;
  assert(result <= INT64, 'Transport clock overflow');
  return result;
}
function config(c) {
  assert(
    c &&
      uuid(c.id) &&
      uuid(c.encoderSessionID) &&
      Number.isInteger(c.bitRate) &&
      c.bitRate > 0 &&
      c.bitRate <= 2147483647,
    'Invalid encoder configuration',
  );
}
function publication(p) {
  assert(
    p &&
      uuid(p.readerId) &&
      uuid(p.publisherId) &&
      p.readerId !== p.publisherId &&
      uuid(p.publishingAttemptId) &&
      p.clock?.convention === 'mpegts-ingress-origin-90k-v1',
    'Invalid publication',
  );
  integer(p.clock.originPTS, 0n, MOD - 1n);
}
function binding(status, scope, expectedAttempt) {
  const o = status.observation;
  assert(
    typeof status.gameId === 'string' &&
      /^[A-Za-z0-9_-]{1,128}$/.test(status.gameId) &&
      Number.isSafeInteger(status.generation) &&
      status.generation > 0,
    'Invalid publication scope',
  );
  assert(
    status.state === 'producing_output' &&
      o?.state === 'producing_output' &&
      o.decodedVideo?.clock === 'mpegts-pts-90k-v1',
    'Unavailable decoder owner',
  );
  assert(
    status.gameId === scope.matchID &&
      status.generation === scope.broadcastGeneration &&
      o.gameId === status.gameId &&
      o.generation === status.generation,
    'Wrong report scope',
  );
  assert(
    typeof status.workerId === 'string' &&
      /^[A-Za-z0-9_-]{1,128}$/.test(status.workerId) &&
      uuid(status.workerEpoch) &&
      Number.isSafeInteger(o.attempt) &&
      o.attempt > 0,
    'Invalid worker identity',
  );
  publication(status.publication);
  assert.equal(
    status.publication.publishingAttemptId,
    expectedAttempt,
    'Wrong publication attempt',
  );
  return {
    gameId: status.gameId,
    generation: status.generation,
    workerId: status.workerId,
    workerEpoch: status.workerEpoch,
    attempt: o.attempt,
    publication: status.publication,
  };
}

// Reconstruct the bounded wire history independently of the native exported snapshot.
function reconstructReports(reports, scope, cadenceAuditMode) {
  qualifyCadenceAuditEnvelope(reports, { cadenceAuditMode });
  assert(
    reports.deliveryTiming === undefined || reports.deliveryTiming === 'request-uptime-v1',
    'Unknown delivery timing mode',
  );
  const anchored = reports.deliveryTiming === 'request-uptime-v1';
  let acceptedRequestTiming;
  let priorTime = -1,
    priorReceived = -1,
    history,
    owner,
    priorProof,
    exhausted = false,
    needsFull = true;
  const retired = [],
    ids = new Set(),
    result = [];
  for (const row of reports.rows) {
    for (const key of ['receivedUptime', 'evaluatedUptime', 'requestSeconds', 'residenceSeconds'])
      assert(finite(row[key]), `Invalid report ${key}`);
    assert(
      row.evaluatedUptime >= row.receivedUptime &&
        row.evaluatedUptime >= priorTime &&
        row.receivedUptime >= priorReceived,
      'Report clock reversal',
    );
    assert(
      Math.abs(row.evaluatedUptime - row.receivedUptime - row.residenceSeconds) <= AGE_TOLERANCE,
      'Report residence does not reconcile',
    );
    priorTime = row.evaluatedUptime;
    priorReceived = row.receivedUptime;
    assert.equal(
      row.expectedAttempt,
      scope.publishingAttemptID.toLowerCase(),
      'Wrong expected attempt',
    );
    const status = row.response?.status;
    assert(
      status && status.gameId === scope.matchID && status.generation === scope.broadcastGeneration,
      'Wrong raw report scope',
    );
    let requestTiming;
    if (anchored) {
      requestTiming = row.timing;
      assert(
        requestTiming &&
          finite(requestTiming.statusRequestStartedUptime) &&
          finite(requestTiming.responseReceivedUptime) &&
          requestTiming.statusRequestStartedUptime <= requestTiming.responseReceivedUptime &&
          requestTiming.responseReceivedUptime === row.receivedUptime,
        'Invalid request uptime bracket',
      );
      // Native uptime endpoints surround the separately sampled ContinuousClock
      // endpoints. Permit subtraction roundoff only, never the freshness tolerance.
      const rounding = 2 * Number.EPSILON * Math.max(1, requestTiming.responseReceivedUptime);
      assert(
        requestTiming.responseReceivedUptime -
          requestTiming.statusRequestStartedUptime +
          rounding >=
          row.requestSeconds,
        'Request uptime bracket does not contain measured duration',
      );
    } else
      assert(
        !Object.hasOwn(row, 'deliverySampleTimeBounds'),
        'Legacy report carries timing bounds',
      );
    const item = { row, proof: null };
    result.push(item);
    let nextOwner, packet, nextHistory, ttl;
    try {
      assert(!exhausted, 'Delivery tracker exhausted');
      nextOwner = binding(status, scope, row.expectedAttempt);
      ttl = Math.max(
        0,
        Math.min(5, (Date.parse(status.expiresAt) - Date.parse(row.response.serverTime)) / 1000),
      );
      assert(
        Number.isFinite(ttl) && row.requestSeconds + row.residenceSeconds < ttl,
        'Expired worker status',
      );
      packet = status.observation.decoderDelivery;
      assert(packet, 'Missing delivery packet');
      if (!isDeepStrictEqual(owner, nextOwner)) {
        assert(!retired.some((x) => isDeepStrictEqual(x, nextOwner)), 'Retired delivery owner');
        if (retired.length >= 64) {
          exhausted = true;
          assert.fail('Delivery tracker exhausted');
        }
        if (owner) retired.push(owner);
        owner = nextOwner;
        history = undefined;
        needsFull = true;
      }
      if (needsFull)
        assert.equal(
          packet.afterOrdinal,
          Math.max(0, packet.lastOrdinal - 256),
          'Full delivery resync required',
        );
      nextHistory = advanceDelivery(history, packet);
    } catch (error) {
      assert(
        row.deliveryReceiptID === null && row.deliverySampleAgeSeconds === null,
        `Native receipt claims unusable report: ${error.message}`,
      );
      if (anchored)
        same(row.deliverySampleTimeBounds, null, 'Unusable report carries sample bounds');
      priorProof = undefined;
      needsFull = true;
      continue;
    }
    const previousSample = history?.sampledAtMs;
    history = nextHistory;
    if (row.deliveryReceiptID === null) {
      assert.equal(row.deliverySampleAgeSeconds, null, 'Age without delivery receipt');
      if (anchored)
        same(row.deliverySampleTimeBounds, null, 'Unusable report carries sample bounds');
      priorProof = undefined;
      needsFull = true;
      continue;
    }
    assert(
      uuid(row.deliveryReceiptID) && !ids.has(row.deliveryReceiptID),
      'Invalid or reused delivery receipt',
    );
    ids.add(row.deliveryReceiptID);
    assert(packet.invalidReason === null && packet.ended === false, 'Invalid delivery history');
    assert(
      Number.isSafeInteger(status.decoderDeliveryAgeUpperBoundMs) &&
        status.decoderDeliveryAgeUpperBoundMs >= 0,
      'Missing server age bound',
    );
    let expected =
      status.decoderDeliveryAgeUpperBoundMs / 1000 + row.requestSeconds + row.residenceSeconds;
    if (previousSample === packet.sampledAtMs) {
      assert(
        priorProof && isDeepStrictEqual(priorProof.context, nextOwner),
        'Frozen sample without prior freshness proof',
      );
      assert(row.receivedUptime < priorProof.expiresAt, 'Frozen prior proof expired');
      expected = Math.max(expected, priorProof.age + row.evaluatedUptime - priorProof.at);
    }
    assert(
      finite(row.deliverySampleAgeSeconds, Number.MAX_SAFE_INTEGER) &&
        Math.abs(row.deliverySampleAgeSeconds - expected) <= AGE_TOLERANCE,
      'Report delivery age does not reconcile',
    );
    let sampleTimeBounds;
    if (anchored) {
      assert(
        !acceptedRequestTiming ||
          (requestTiming.statusRequestStartedUptime >=
            acceptedRequestTiming.statusRequestStartedUptime &&
            requestTiming.responseReceivedUptime >= acceptedRequestTiming.responseReceivedUptime),
        'Accepted request timing regressed',
      );
      sampleTimeBounds =
        previousSample === packet.sampledAtMs
          ? priorProof.sampleTimeBounds
          : {
              lower: Math.max(
                0,
                requestTiming.statusRequestStartedUptime -
                  status.decoderDeliveryAgeUpperBoundMs / 1000,
              ),
              upper: requestTiming.responseReceivedUptime,
            };
      same(
        row.deliverySampleTimeBounds,
        sampleTimeBounds,
        'Report sample bounds differ from request history',
      );
      acceptedRequestTiming = requestTiming;
    }
    // Carry the independently reconstructed bound, so a sampling tolerance cannot
    // be repeatedly subtracted on a long sequence of frozen reports.
    item.proof = {
      sampleTimeBounds,
      context: nextOwner,
      snapshot: deliverySnapshot(nextHistory),
      age: expected,
      at: row.evaluatedUptime,
      expiresAt: row.receivedUptime + ttl - row.requestSeconds,
    };
    priorProof = item.proof;
    needsFull = false;
  }
  return result;
}

function sourceFrames(row, scope) {
  const h = row.history,
    c = row.clock,
    receipt = row.receipt,
    d = row.diagnostics;
  assert(
    h &&
      h.closed === false &&
      h.invalidity === null &&
      row.clockClosed === false &&
      d?.isPublishing === true &&
      d.ingressClosed === false,
    'Unavailable native ownership',
  );
  same(h.scope, row.clockScope, 'Clock scope mismatch');
  same(h.scope, d.ingressScope, 'Ingress scope mismatch');
  for (const key of ['recordingID', 'matchID', 'broadcastGeneration', 'publishingAttemptID'])
    if (scope[key] !== undefined)
      same(
        h.scope[key],
        key === 'publishingAttemptID' ? scope[key].toLowerCase() : scope[key],
        'Wrong capture scope',
      );
  assert(
    h.scope.publishingAttemptID === row.attemptID &&
      row.context.publication.publishingAttemptId === row.attemptID,
    'Attempt ownership mismatch',
  );
  assert(
    h.scope.matchID === row.context.gameId &&
      h.scope.broadcastGeneration === row.context.generation,
    'Context ownership mismatch',
  );
  integer(h.scope.appliedProfileRevision);
  integer(row.appliedRevision);
  same(c, d.clock, 'Current transport clock mismatch');
  same(receipt, d.receipt, 'Current encoder receipt mismatch');
  integer(c.generation);
  assert.equal(c.generation, receipt.generation, 'Publishing generation mismatch');
  cm(c.sourceOrigin);
  config(receipt.configuration);
  assert(
    receipt.configuration.bitRate === row.videoBitrate &&
      typeof row.profileID === 'string' &&
      row.profileID.length > 0,
    'Applied configuration mismatch',
  );
  assert(
    finite(receipt.acceptedAt) &&
      finite(row.acknowledgedAt) &&
      row.acknowledgedAt >= receipt.acceptedAt &&
      row.start >= row.acknowledgedAt,
    'Window predates acknowledgment',
  );
  for (const key of ['omittedCaptureFrames', 'omittedEncodedFrames']) integer(h[key]);
  for (const key of ['trimmedCaptureFrames', 'trimmedEncodedFrames'])
    assert(Number.isSafeInteger(h[key]) && h[key] >= 0 && h[key] <= 8192, 'Invalid export trim');
  for (const [name, frames] of [
    ['capture', h.capture],
    ['encoded', h.encoded],
  ]) {
    assert(
      Array.isArray(frames) && frames.length > 0 && frames.length <= 8192,
      'Unbounded source history',
    );
    let last;
    for (const frame of frames) {
      cm(frame.sourcePTS);
      assert(
        finite(frame.observedAt) &&
          frame.observedAt <= row.evaluatedAt &&
          (!last ||
            (frame.observedAt >= last.observedAt && compare(frame.sourcePTS, last.sourcePTS) > 0n)),
        'Invalid source history ordering',
      );
      if (name === 'capture') assert.equal(frame.encoding, null, 'Capture has encoder metadata');
      if (frame.encoding !== null) {
        const e = frame.encoding;
        assert(
          uuid(e.encoderSessionID) &&
            finite(e.submittedAt) &&
            finite(e.completedAt) &&
            e.completedAt >= e.submittedAt &&
            e.completedAt <= frame.observedAt,
          'Invalid encoder timing',
        );
        if (e.configuration !== null) {
          config(e.configuration);
          assert.equal(e.configuration.encoderSessionID, e.encoderSessionID);
        }
      }
      last = frame;
    }
  }
  const left = h.capture.findLastIndex((f) => f.observedAt < row.start),
    right = h.capture.findIndex((f) => f.observedAt >= row.end);
  assert(left >= 0 && right > left + 1 && right - left - 1 <= 240, 'Incomplete capture window');
  for (let i = left + 1; i <= right; i++)
    assert(h.capture[i].observedAt > h.capture[i - 1].observedAt, 'Non-strict capture clock');
  const captures = h.capture.slice(left + 1, right),
    first = captures[0].sourcePTS,
    rightSource = h.capture[right].sourcePTS;
  assert(
    receipt.lastSubmittedPTS === null || compare(first, receipt.lastSubmittedPTS) > 0n,
    'Window includes pre-configuration source',
  );
  assert(compare(h.encoded[0].sourcePTS, first) < 0n, 'Missing encoder predecessor');
  const boundary = h.encoded.find((f) => compare(f.sourcePTS, rightSource) >= 0n);
  assert(
    boundary && h.capture.some((f) => compare(f.sourcePTS, boundary.sourcePTS) === 0n),
    'Missing captured encoder completion bracket',
  );
  const encoded = new Set();
  for (const frame of h.encoded.filter(
    (f) => compare(f.sourcePTS, first) >= 0n && compare(f.sourcePTS, rightSource) < 0n,
  )) {
    const index = captures.findIndex((f) => compare(f.sourcePTS, frame.sourcePTS) === 0n);
    assert(index >= 0 && frame.encoding, 'Encoded source lacks captured provenance');
    same(frame.encoding.configuration, receipt.configuration, 'Unstable encoder configuration');
    assert(
      frame.encoding.submittedAt >= captures[index].observedAt,
      'Encoder submission predates capture',
    );
    encoded.add(index);
  }
  const origin = integer(row.context.publication.clock.originPTS, 0n, MOD - 1n),
    anchorPTS = BigInt(row.timeline.arrivals.at(-1)?.pts);
  let anchor, firstTicks, previousTicks;
  for (const frame of h.encoded) {
    if (compare(frame.sourcePTS, c.sourceOrigin) < 0n) continue;
    const value = ticks(frame.sourcePTS, c.sourceOrigin);
    assert(previousTicks === undefined || value > previousTicks, 'Quantized encoder PTS reversal');
    firstTicks ??= value;
    previousTicks = value;
    assert(value - firstTicks < MOD / 2n, 'Ambiguous source history wrap');
    if (modulo(value - origin) === modulo(anchorPTS)) {
      assert(!anchor, 'Ambiguous decoder anchor');
      anchor = { frame, ticks: value };
    }
  }
  assert(
    anchor && h.capture.some((f) => compare(f.sourcePTS, anchor.frame.sourcePTS) === 0n),
    'Decoder anchor lacks captured/encoded provenance',
  );
  same(
    row.anchorSourcePTS,
    anchor.frame.sourcePTS,
    'Exported anchor differs from actual decoder anchor',
  );
  let previous;
  const frames = captures.map((frame, index) => {
    const delta = ticks(frame.sourcePTS, c.sourceOrigin) - anchor.ticks,
      pts = anchorPTS + delta;
    assert(
      delta > -MOD / 2n &&
        delta < MOD / 2n &&
        pts >= -MAX &&
        pts <= MAX &&
        (previous === undefined || pts > previous),
      'Invalid unwrapped source PTS',
    );
    previous = pts;
    return {
      pts: String(pts),
      sourcePTS: frame.sourcePTS,
      capturedAt: frame.observedAt,
      wasEncoded: encoded.has(index),
    };
  });
  same(row.frames, frames, 'Exported source projection differs');
  return frames;
}

// Call only after qualifyNativeDeliveryDeadlines has reconciled this row with raw reports.
export function qualifiedDeliverySampleBounds(row, age) {
  return row.sampleTimeBounds ?? { lower: row.evaluatedAt - age, upper: row.evaluatedAt };
}

function classify(row, frames, budget, age) {
  const t = row.timeline,
    sample = qualifiedDeliverySampleBounds(row, age);
  assert(
    t.invalidReason == null && t.ended === false && t.arrivals.length > 0,
    'Unavailable decoder timeline',
  );
  assert(
    sample.upper - t.coverageAgeMs / 1000 < frames[0].capturedAt &&
      sample.lower > frames.at(-1).capturedAt + budget,
    'Incomplete deadline history coverage',
  );
  const first = new Map();
  for (const a of t.arrivals)
    if (!first.has(String(a.pts))) first.set(String(a.pts), a.ageMs / 1000);
  const counts = {
    expectedFrames: frames.length,
    onTimeFrames: 0,
    lateFrames: 0,
    missingFrames: 0,
    uncertainFrames: 0,
  };
  for (const frame of frames) {
    const arrivalAge = first.get(frame.pts);
    if (arrivalAge === undefined) {
      counts.missingFrames++;
      continue;
    }
    assert(frame.wasEncoded, 'Decoded arrival for locally unencoded capture');
    const upper = sample.upper - arrivalAge,
      lower = row.sampleTimeBounds ? sample.lower - arrivalAge : upper - age,
      deadline = frame.capturedAt + budget;
    assert(upper >= frame.capturedAt, 'Impossible arrival before capture');
    if (upper <= deadline) counts.onTimeFrames++;
    else if (lower > deadline) counts.lateFrames++;
    else counts.uncertainFrames++;
  }
  for (const [key, n] of Object.entries(counts))
    assert.equal(row.result[key], n, `Deadline ${key} differs`);
  for (const [key, expected] of Object.entries({
    onTimeFPS: counts.uncertainFrames ? null : counts.onTimeFrames / (row.end - row.start),
    failureFraction: counts.uncertainFrames
      ? null
      : (counts.lateFrames + counts.missingFrames) / frames.length,
  })) {
    if (expected === null)
      assert.equal(row.result[key], null, 'Unknown frames cannot assert health');
    else
      assert(
        typeof row.result[key] === 'number' && Math.abs(row.result[key] - expected) <= 1e-12,
        `Deadline ${key} differs`,
      );
  }
  return counts;
}

/** Reconciles scalar evidence from the actual native/report exports. Synthetic inputs
 * can test this verifier, but do not themselves qualify a real capture/relay run.
 * Lane totals intentionally overlap: never sum them into recovery or adaptation credit. */
export function qualifyNativeDeliveryDeadlines({
  audit,
  reports,
  scope,
  expectedLatencyBudget = 1,
  cadenceAuditMode = 'legacy',
  deliveryAuditMode = 'legacy',
}) {
  qualifyDeliveryAuditEnvelope(audit, { deliveryAuditMode });
  assert(
    expectedLatencyBudget === 1 || expectedLatencyBudget === 1.5,
    'Unsupported expected deadline budget',
  );
  assert(
    audit.latencyBudget === expectedLatencyBudget && audit.maximumSampleAge === 0.25,
    'Unexpected experiment deadline budgets',
  );
  same(audit.deliveryTiming, reports.deliveryTiming, 'Delivery timing modes differ');
  const anchored = audit.deliveryTiming === 'request-uptime-v1';
  const reconstructed = reconstructReports(reports, scope, cadenceAuditMode),
    lanes = new Map(),
    phases = new Map();
  const counts = {
    expectedFrames: 0,
    onTimeFrames: 0,
    lateFrames: 0,
    missingFrames: 0,
    uncertainFrames: 0,
  };
  const observations = {
    healthyRows: 0,
    lateRows: 0,
    missingRows: 0,
    uncertainRows: 0,
    below24FPSRows: 0,
    below30FPSRows: 0,
  };
  let successfulRows = 0,
    unknownRows = 0,
    previousTime = -1,
    previousPhase = 0;
  for (const row of audit.rows) {
    if (!anchored)
      assert(!Object.hasOwn(row, 'sampleTimeBounds'), 'Legacy deadline carries timing bounds');
    assert(
      Array.isArray(row.history?.capture) &&
        row.history.capture.length <= 8192 &&
        Array.isArray(row.history?.encoded) &&
        row.history.encoded.length <= 8192 &&
        Array.isArray(row.timeline?.arrivals) &&
        row.timeline.arrivals.length <= 256,
      'Unbounded native evidence row',
    );
    assert(
      Number.isSafeInteger(row.phase) &&
        row.phase > 0 &&
        row.phase <= 256 &&
        row.phase >= previousPhase,
      'Invalid deadline phase',
    );
    previousPhase = row.phase;
    assert(
      finite(row.start) &&
        finite(row.end) &&
        [1, 2].includes(row.end - row.start) &&
        finite(row.evaluatedAt) &&
        row.evaluatedAt >= row.end &&
        row.evaluatedAt >= previousTime,
      'Invalid deadline window time',
    );
    previousTime = row.evaluatedAt;
    const laneKey = `${row.phase}:${row.end - row.start}`,
      lane = lanes.get(laneKey) ?? {
        phase: row.phase,
        duration: row.end - row.start,
        rows: 0,
        successfulRows: 0,
        unknownRows: 0,
        coverageSeconds: 0,
        observations: {
          healthyRows: 0,
          lateRows: 0,
          missingRows: 0,
          uncertainRows: 0,
          below24FPSRows: 0,
          below30FPSRows: 0,
        },
        start: row.start,
        end: row.start,
      };
    assert(row.start >= lane.end, 'Repeated or overlapping deadline lane');
    lane.end = row.end;
    lane.rows++;
    lanes.set(laneKey, lane);
    if (row.result === null) {
      assert(
        typeof row.reason === 'string' &&
          row.reason.length > 0 &&
          row.frames === undefined &&
          row.anchorSourcePTS === undefined,
        'Unknown row carries positive evidence',
      );
      unknownRows++;
      lane.unknownRows++;
      continue;
    }
    assert(row.reason === null, 'Successful row also has a failure reason');
    const report = reconstructed.findLast((r) => r.row.evaluatedUptime <= row.evaluatedAt);
    assert(
      report?.proof && report.row.deliveryReceiptID === row.deliveryReceiptID,
      'Deadline row does not own current report receipt',
    );
    if (anchored) {
      same(
        row.sampleTimeBounds,
        report.proof.sampleTimeBounds,
        'Deadline sample bounds differ from report',
      );
      assert(
        row.sampleTimeBounds &&
          finite(row.sampleTimeBounds.lower) &&
          finite(row.sampleTimeBounds.upper) &&
          row.sampleTimeBounds.lower <= row.sampleTimeBounds.upper &&
          row.sampleTimeBounds.upper <= row.evaluatedAt &&
          row.evaluatedAt - row.sampleTimeBounds.lower <= audit.maximumSampleAge,
        'Deadline sample bounds are future or stale',
      );
    }
    same(row.context, report.proof.context, 'Deadline context differs from authenticated report');
    same(
      { ...row.timeline, invalidReason: row.timeline?.invalidReason ?? null },
      report.proof.snapshot,
      'Timeline differs from reconstructed raw packets',
    );
    const expectedAge = report.proof.age + row.evaluatedAt - report.proof.at,
      conservativeAge = Math.max(row.sampleAgeSeconds, expectedAge);
    // Paired-clock tolerance reconciles measurements only. It must never freshen
    // evidence, complete coverage early, or narrow an arrival uncertainty interval.
    assert(
      finite(row.sampleAgeSeconds) &&
        conservativeAge <= audit.maximumSampleAge &&
        conservativeAge <= row.evaluatedAt &&
        Math.abs(row.sampleAgeSeconds - expectedAge) <= AGE_TOLERANCE &&
        row.evaluatedAt < report.proof.expiresAt,
      'Deadline sample age does not reconcile or is stale',
    );
    const identity = {
      scope: row.history?.scope,
      clock: row.clock,
      context: row.context,
      deliveryScope: row.timeline.scopeID,
      attempt: row.attemptID,
      revision: row.appliedRevision,
      receipt: row.receipt,
      acknowledgedAt: row.acknowledgedAt,
    };
    if (phases.has(row.phase))
      same(identity, phases.get(row.phase), 'Configuration changed within phase');
    else phases.set(row.phase, identity);
    const frames = sourceFrames(row, scope),
      result = classify(row, frames, audit.latencyBudget, conservativeAge);
    for (const key of Object.keys(counts)) counts[key] += result[key];
    for (const observed of [observations, lane.observations]) {
      if (result.lateFrames) observed.lateRows++;
      if (result.missingFrames) observed.missingRows++;
      if (result.uncertainFrames) observed.uncertainRows++;
      else {
        const fps = result.onTimeFrames / (row.end - row.start);
        if (fps < 24) observed.below24FPSRows++;
        if (fps < 30) observed.below30FPSRows++;
        if (result.lateFrames === 0 && result.missingFrames === 0 && fps >= 30)
          observed.healthyRows++;
      }
    }
    successfulRows++;
    lane.successfulRows++;
    lane.coverageSeconds += lane.duration;
  }
  return {
    latencyBudget: audit.latencyBudget,
    maximumSampleAge: audit.maximumSampleAge,
    rowCount: audit.rows.length,
    reportCount: reports.rows.length,
    successfulRows,
    unknownRows,
    counts,
    observations,
    lanes: [...lanes.values()],
    actualNativeDeadlineEvidenceQualified: successfulRows > 0,
    automaticAdaptationQualified: false,
    recoveryQualified: false,
  };
}
