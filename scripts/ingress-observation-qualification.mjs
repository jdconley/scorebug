import assert from 'node:assert/strict';
import { fixtureFrameID } from './video-observation-qualification.mjs';

const kinds = ['audio', 'video', 'unknown'];
const phases = ['startup', 'admitting', 'draining'];
const dispositions = [
  'admitted',
  'dequeued',
  'overflowEvicted',
  'cancellationDiscarded',
  'rejected.invalidBytes',
  'rejected.oversize',
  'rejected.full',
  'rejected.finished',
  'rejected.cancelled',
];
const areaKeys = [
  'knownDuration',
  'unknownDuration',
  'itemSeconds',
  'byteSeconds',
  'maxPressureSeconds',
];
const ptsKeys = ['firstSourcePTS', 'lastSourcePTS', 'minimumSourcePTS', 'maximumSourcePTS'];
const scopeKeys = [
  'recordingID',
  'matchID',
  'broadcastGeneration',
  'publishingAttemptID',
  'appliedProfileRevision',
];
const object = (value, label) => {
  assert.ok(
    value && typeof value === 'object' && !Array.isArray(value),
    `${label} must be an object`,
  );
  return value;
};
function keys(value, expected, label) {
  object(value, label);
  assert.deepEqual(
    Object.keys(value).sort(),
    [...expected].sort(),
    `${label} schema keys mismatch`,
  );
}
function finite(value, label) {
  assert.ok(
    typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12,
    `${label} must be finite nonnegative bounded number`,
  );
  return value;
}
function integer(value, label, max = Number.MAX_SAFE_INTEGER) {
  assert.ok(
    Number.isSafeInteger(value) && value >= 0 && value <= max,
    `${label} must be a bounded integer`,
  );
  return value;
}
function decimal(value, signed, label) {
  assert.ok(
    typeof value === 'string' &&
      (signed ? /^(0|-?[1-9]\d{0,18})$/ : /^(0|[1-9]\d{0,19})$/).test(value),
    `${label} must be a canonical decimal string`,
  );
  const result = BigInt(value);
  assert.ok(
    result >= (signed ? -(1n << 63n) : 0n) &&
      result <= (signed ? (1n << 63n) - 1n : (1n << 64n) - 1n),
    `${label} exceeds 64-bit counter bounds`,
  );
  return result;
}
function count(value, label) {
  const result = decimal(value, false, `${label} counter`);
  assert.ok(
    result <= BigInt(Number.MAX_SAFE_INTEGER),
    `${label} counter exceeds exact integer qualification bound`,
  );
  return Number(result);
}
function near(actual, expected, label) {
  assert.ok(
    Math.abs(actual - expected) <=
      1e-6 + 32 * Number.EPSILON * Math.max(Math.abs(actual), Math.abs(expected)),
    `${label} sum/duration mismatch`,
  );
}
const compare = (a, b) => (a.n * b.d < b.n * a.d ? -1 : a.n * b.d > b.n * a.d ? 1 : 0);
function rational(pts) {
  keys(pts, ['value', 'timescale', 'epoch', 'flags'], 'PTS');
  const value = decimal(pts.value, true, 'PTS value');
  assert.equal(decimal(pts.epoch, true, 'PTS epoch'), 0n, 'Fixture PTS epoch must be zero');
  assert.equal(pts.flags, 1, 'PTS flags must be valid numeric without rounding');
  assert.ok(
    integer(pts.timescale, 'PTS timescale', 2147483647) > 0,
    'PTS timescale must be positive',
  );
  return { n: value * 60n - 7395n * BigInt(pts.timescale), d: 60n * BigInt(pts.timescale) };
}
// Compare source rationals to the reported decimal coverage endpoint without
// converting the original Int64 through Number. Audio START PTS only, not duration.
function endpoint(value, label) {
  finite(value, label);
  const [mantissa, exponent = '0'] = String(value).toLowerCase().split('e');
  const [whole, fraction = ''] = mantissa.split('.');
  const power = Number(exponent) - fraction.length;
  let n = BigInt(whole + fraction),
    d = 1n;
  if (power >= 0) n *= 10n ** BigInt(power);
  else d = 10n ** BigInt(-power);
  return { n, d };
}
function occupancy(value, duration, limits, label) {
  keys(value, [...areaKeys, 'peakItems', 'peakBytes'], `${label} occupancy`);
  for (const key of areaKeys) finite(value[key], `${label} area ${key}`);
  assert.equal(value.unknownDuration, 0, `${label} unknown occupancy duration`);
  near(value.knownDuration, duration, `${label} known duration`);
  const peakItems = integer(value.peakItems, `${label} peak items`, limits.maxItems);
  const peakBytes = integer(value.peakBytes, `${label} peak bytes`, limits.maxBytes);
  assert.ok(
    (peakItems === 0) === (peakBytes === 0) && peakBytes >= peakItems,
    `${label} impossible occupancy peaks`,
  );
  const tolerance = 1e-6 + 32 * Number.EPSILON * Math.max(1, duration);
  for (const key of ['itemSeconds', 'byteSeconds', 'maxPressureSeconds'])
    assert.ok(value[key] <= duration + tolerance, `${label} area exceeds duration`);
  assert.ok(
    value.maxPressureSeconds + tolerance >= Math.max(value.itemSeconds, value.byteSeconds) &&
      value.maxPressureSeconds <= value.itemSeconds + value.byteSeconds + tolerance,
    `${label} instantaneous maximum pressure integral inconsistent`,
  );
  assert.ok(
    value.itemSeconds <= (duration * peakItems) / limits.maxItems + tolerance &&
      value.byteSeconds <= (duration * peakBytes) / limits.maxBytes + tolerance,
    `${label} area exceeds peak bounds`,
  );
  return value;
}
function phaseOccupancy(value, combined, limits) {
  object(value, 'phase occupancy');
  const sum = Object.fromEntries(areaKeys.map((key) => [key, 0]));
  let peakItems = 0,
    peakBytes = 0;
  for (const [phase, raw] of Object.entries(value)) {
    assert.ok(phases.includes(phase), 'Unknown occupancy phase');
    const row = occupancy(raw, finite(raw.knownDuration, 'phase duration'), limits, 'phase');
    for (const key of areaKeys) sum[key] += row[key];
    peakItems = Math.max(peakItems, row.peakItems);
    peakBytes = Math.max(peakBytes, row.peakBytes);
  }
  for (const key of areaKeys) near(sum[key], combined[key], `phase ${key}`);
  assert.equal(peakItems, combined.peakItems, 'phase peak items mismatch');
  assert.equal(peakBytes, combined.peakBytes, 'phase peak bytes mismatch');
}
function validateDispositions(value, archive, audioBounds, unionBounds) {
  object(value, 'dispositions');
  for (const [disposition, byKind] of Object.entries(value)) {
    assert.ok(dispositions.includes(disposition), 'Unknown disposition');
    object(byKind, 'disposition kind map');
    for (const [kind, summary] of Object.entries(byKind)) {
      assert.ok(kinds.includes(kind), 'Unknown disposition kind');
      keys(summary, ['count', 'invalidPTSCount', ...ptsKeys, 'invalidity'], 'disposition summary');
      const samples = count(summary.count, 'disposition');
      assert.equal(count(summary.invalidPTSCount, 'invalid PTS'), 0, 'Invalid PTS count');
      assert.equal(summary.invalidity, 0, 'Disposition invalidity');
      if (!samples) {
        for (const key of ptsKeys) assert.equal(summary[key], null, 'Empty disposition has PTS');
        continue;
      }
      const mapped = {};
      for (const key of ptsKeys) {
        const pts = summary[key];
        mapped[key] = rational(pts);
        if (kind === 'video') {
          const frame = fixtureFrameID(pts);
          assert.ok(
            frame >= archive.firstSourceFrame && frame <= archive.lastSourceFrame,
            'Video PTS bounds outside archive',
          );
        } else {
          const bounds = kind === 'audio' ? audioBounds : unionBounds;
          assert.ok(
            compare(mapped[key], bounds.start) >= 0 && compare(mapped[key], bounds.end) < 0,
            `${kind} PTS bounds outside archive coverage`,
          );
        }
      }
      const lo = mapped.minimumSourcePTS,
        hi = mapped.maximumSourcePTS;
      assert.ok(
        compare(lo, hi) <= 0 &&
          ['firstSourcePTS', 'lastSourcePTS'].every(
            (key) => compare(mapped[key], lo) >= 0 && compare(mapped[key], hi) <= 0,
          ),
        'PTS extrema inconsistent',
      );
      if (samples <= 2) {
        const ends = [mapped.firstSourcePTS, mapped.lastSourcePTS].sort(compare);
        assert.ok(
          compare(lo, ends[0]) === 0 && compare(hi, ends[1]) === 0,
          'PTS extrema exceed observed count',
        );
        if (samples === 1) assert.equal(compare(lo, hi), 0, 'Singleton PTS extrema differ');
      }
    }
  }
}
function mergeDispositions(target, source) {
  for (const [disposition, byKind] of Object.entries(source)) {
    target[disposition] ??= {};
    for (const [kind, row] of Object.entries(byKind)) {
      const prior = target[disposition][kind];
      if (!prior) {
        target[disposition][kind] = structuredClone(row);
        continue;
      }
      const total = count(prior.count, 'sum') + count(row.count, 'sum');
      integer(total, 'sum counter');
      prior.count = String(total);
      if (!row.firstSourcePTS) continue;
      if (!prior.firstSourcePTS) {
        for (const key of ptsKeys) prior[key] = structuredClone(row[key]);
      } else {
        prior.lastSourcePTS = structuredClone(row.lastSourcePTS);
        for (const [key, direction] of [
          ['minimumSourcePTS', -1],
          ['maximumSourcePTS', 1],
        ])
          if (compare(rational(row[key]), rational(prior[key])) === direction)
            prior[key] = structuredClone(row[key]);
      }
    }
  }
}
const countsFor = (value, disposition, kind) =>
  count(value[disposition]?.[kind]?.count ?? '0', 'disposition');
const means = (value) => ({
  ...value,
  meanItemOccupancy: value.knownDuration ? value.itemSeconds / value.knownDuration : null,
  meanByteOccupancy: value.knownDuration ? value.byteSeconds / value.knownDuration : null,
  meanMaxPressure: value.knownDuration ? value.maxPressureSeconds / value.knownDuration : null,
});

/** Known local fixture only. Counts describe mailbox buffer dispositions, never
 * fresh/encoded frames, downstream loss, or sustainable capacity. The already
 * analyzed archive establishes bounds; this function performs no media decode. */
export function qualifyIngressObservation({ snapshot, archive, completedWindowLimit = 8 }) {
  assert.ok([8, 64, 128].includes(completedWindowLimit), 'Unsupported ingress history limit');
  object(snapshot, 'observation snapshot');
  assert.equal(snapshot.formatVersion, 1, 'Unsupported observation format');
  const value = object(snapshot.ingressObservation, 'ingress observation');
  keys(
    value,
    [
      'formatVersion',
      'scope',
      'monotonicAnchor',
      'windowDuration',
      'maxItems',
      'maxBytes',
      'phase',
      'currentItems',
      'currentBytes',
      'current',
      'completed',
      'totalOccupancy',
      'totalDispositions',
      'omittedCompletedWindowCount',
      'omittedThroughMonotonicTime',
      'rejectedClockOperationCount',
      'unassignedDispositionCount',
      'invalidity',
      'isClosed',
    ],
    'ingress',
  );
  assert.equal(value.formatVersion, 1, 'Unsupported ingress format');
  keys(value.scope, scopeKeys, 'ingress scope');
  assert.deepEqual(value.scope, snapshot.scope, 'Ingress scope mismatch');
  assert.equal(value.monotonicAnchor, snapshot.monotonicAnchor, 'Ingress anchor mismatch');
  assert.equal(value.windowDuration, snapshot.windowDuration, 'Ingress duration mismatch');
  assert.equal(value.windowDuration, 5, 'Expected five-second duration');
  const anchor = finite(value.monotonicAnchor, 'anchor');
  assert.equal(value.isClosed, true, 'Ingress must be closed');
  assert.equal(value.phase, 'closed', 'Ingress phase must be closed');
  assert.equal(value.currentItems, 0, 'Terminal queue item depth must be zero');
  assert.equal(value.currentBytes, 0, 'Terminal queue byte depth must be zero');
  assert.equal(value.invalidity, 0, 'Ingress invalidity');
  for (const key of [
    'omittedCompletedWindowCount',
    'rejectedClockOperationCount',
    'unassignedDispositionCount',
  ])
    assert.equal(count(value[key], key), 0, `Ingress ${key}`);
  assert.equal(value.omittedThroughMonotonicTime, null, 'Ingress omitted history');
  const limits = {
    maxItems: integer(value.maxItems, 'max items'),
    maxBytes: integer(value.maxBytes, 'max bytes'),
  };
  assert.ok(limits.maxItems > 0 && limits.maxBytes > 0, 'Positive occupancy limits required');
  object(archive, 'archive');
  assert.equal(archive.firstSourceFrame, 0, 'Complete fixture archive must start at zero');
  integer(archive.lastSourceFrame, 'last archive frame', 65535);
  const coverage = object(archive.coverage, 'archive coverage');
  const audioBounds = {
    start: endpoint(coverage.audioStartTime, 'audio coverage start'),
    end: endpoint(coverage.audioEndTime, 'audio coverage end'),
  };
  assert.ok(compare(audioBounds.start, audioBounds.end) < 0, 'Invalid audio coverage bounds');
  const unionBounds = {
    start: endpoint(
      Math.min(coverage.audioStartTime, finite(coverage.videoStartTime, 'video coverage start')),
      'coverage start',
    ),
    end: endpoint(
      Math.max(coverage.audioEndTime, finite(coverage.videoEndTime, 'video coverage end')),
      'coverage end',
    ),
  };
  const closedAt = finite(value.current?.monotonicEnd, 'ingress closure');
  assert.ok(
    closedAt >= finite(snapshot.captureDetachedAt, 'capture detach') &&
      closedAt <= finite(snapshot.current?.monotonicEnd, 'video closure') &&
      closedAt >= anchor,
    'Ingress closure must lie between capture detach and video closure',
  );
  assert.ok(
    Array.isArray(value.completed) && value.completed.length <= completedWindowLimit,
    'Bounded ingress history required',
  );
  const all = [...value.completed, value.current];
  const sums = Object.fromEntries(areaKeys.map((key) => [key, 0]));
  let intervalIndex = 0,
    previousEnd = anchor,
    peakItems = 0,
    peakBytes = 0;
  const summedDispositions = {},
    queued = { audio: 0, video: 0, unknown: 0 };
  const windows = all.map((window, index) => {
    keys(
      window,
      [
        'monotonicStart',
        'monotonicEnd',
        'scheduledMonotonicEnd',
        'coveredWindowCount',
        'isCoalesced',
        'isPartial',
        'isClosed',
        'occupancy',
        'occupancyByPhase',
        'dispositions',
      ],
      'window',
    );
    const terminal = index === value.completed.length;
    const start = finite(window.monotonicStart, 'window start'),
      end = finite(window.monotonicEnd, 'window end');
    assert.equal(start, previousEnd, 'Ingress windows must be contiguous from anchor');
    assert.equal(start, anchor + intervalIndex * 5, 'Window is not anchored');
    assert.ok(end >= start, 'Invalid window duration');
    const covered = count(window.coveredWindowCount, 'covered windows');
    assert.ok(covered > 0, 'Empty covered window count');
    assert.equal(
      window.scheduledMonotonicEnd,
      anchor + (intervalIndex + covered) * 5,
      'Invalid scheduled window end',
    );
    assert.equal(typeof window.isCoalesced, 'boolean', 'Missing coalesced flag');
    assert.equal(window.isPartial, terminal, 'Only terminal window may be partial');
    assert.equal(window.isClosed, terminal, 'Only terminal window must be closed');
    if (terminal)
      assert.ok(
        covered === 1 && !window.isCoalesced && end < window.scheduledMonotonicEnd,
        'Invalid terminal partial window',
      );
    else assert.equal(end, window.scheduledMonotonicEnd, 'Completed window duration mismatch');
    if (!window.isCoalesced) assert.equal(covered, 1, 'Multiple intervals require coalesced flag');
    const row = occupancy(window.occupancy, end - start, limits, 'window');
    phaseOccupancy(window.occupancyByPhase, row, limits);
    validateDispositions(window.dispositions, archive, audioBounds, unionBounds);
    const priorQueued = Object.values(queued).reduce((a, b) => a + b, 0);
    let admitted = 0,
      queueMutations = 0;
    for (const kind of kinds) {
      const accepted = countsFor(window.dispositions, 'admitted', kind);
      admitted += accepted;
      queueMutations +=
        accepted +
        countsFor(window.dispositions, 'dequeued', kind) +
        countsFor(window.dispositions, 'overflowEvicted', kind) +
        countsFor(window.dispositions, 'cancellationDiscarded', kind);
      queued[kind] +=
        accepted -
        countsFor(window.dispositions, 'dequeued', kind) -
        countsFor(window.dispositions, 'overflowEvicted', kind) -
        countsFor(window.dispositions, 'cancellationDiscarded', kind);
      assert.ok(
        Number.isSafeInteger(queued[kind]) && queued[kind] >= 0,
        'Per-kind count conservation failed',
      );
    }
    assert.ok(
      Object.values(queued).reduce((a, b) => a + b, 0) <= limits.maxItems,
      'Queued count conservation exceeds limit',
    );
    assert.ok(
      row.peakItems <= priorQueued + admitted,
      'Occupancy peak has no supporting admission',
    );
    if (window.isCoalesced) {
      assert.ok(
        Object.values(window.dispositions).every((byKind) =>
          Object.values(byKind).every((summary) => summary.count === '0'),
        ),
        'Coalesced interval cannot contain dispositions',
      );
      assert.equal(
        Object.keys(window.occupancyByPhase).length,
        1,
        'Coalesced occupied phase must be unchanged',
      );
    }
    // Ordinary intervals can also contain an unchanged queue. Rejects and phase
    // transitions do not mutate depth; polling frequency cannot erase its area.
    if (end > start && queueMutations === 0) {
      const label = window.isCoalesced ? 'Coalesced unchanged' : 'Unchanged';
      assert.equal(
        row.peakItems,
        priorQueued,
        `${label} occupancy depth conservation failed without a disposition`,
      );
      near(
        row.itemSeconds,
        ((end - start) * priorQueued) / limits.maxItems,
        `${label} item occupancy`,
      );
      near(
        row.byteSeconds,
        ((end - start) * row.peakBytes) / limits.maxBytes,
        `${label} byte occupancy`,
      );
      near(
        row.maxPressureSeconds,
        Math.max(row.itemSeconds, row.byteSeconds),
        `${label} maximum pressure`,
      );
    }
    mergeDispositions(summedDispositions, window.dispositions);
    for (const key of areaKeys) sums[key] += row[key];
    peakItems = Math.max(peakItems, row.peakItems);
    peakBytes = Math.max(peakBytes, row.peakBytes);
    intervalIndex += covered;
    previousEnd = end;
    return {
      index,
      monotonicStart: start,
      monotonicEnd: end,
      coveredWindowCount: covered,
      isCoalesced: window.isCoalesced,
      isPartial: terminal,
      occupancy: means(row),
      occupancyByPhase: Object.fromEntries(
        Object.entries(window.occupancyByPhase).map(([phase, area]) => [phase, means(area)]),
      ),
      dispositionCounts: Object.fromEntries(
        Object.entries(window.dispositions).map(([key, byKind]) => [
          key,
          Object.fromEntries(
            Object.entries(byKind).map(([kind, summary]) => [kind, summary.count]),
          ),
        ]),
      ),
    };
  });
  assert.ok(
    Object.values(queued).every((count) => count === 0),
    'Terminal per-kind count conservation failed',
  );
  const total = occupancy(value.totalOccupancy, closedAt - anchor, limits, 'total');
  for (const key of areaKeys) near(sums[key], total[key], `Window to total ${key}`);
  assert.equal(peakItems, total.peakItems, 'Window to total peak items mismatch');
  assert.equal(peakBytes, total.peakBytes, 'Window to total peak bytes mismatch');
  validateDispositions(value.totalDispositions, archive, audioBounds, unionBounds);
  assert.deepEqual(
    summedDispositions,
    value.totalDispositions,
    'Window to total disposition/PTS sum mismatch',
  );
  return {
    formatVersion: 1,
    scope: value.scope,
    monotonicAnchor: anchor,
    closedAt,
    ...limits,
    totalOccupancy: means(total),
    totalDispositions: value.totalDispositions,
    windows,
    evidenceMeaning:
      'Queued buffer occupancy and dispositions only; excludes in-flight, encoder, network and remote loss',
  };
}
