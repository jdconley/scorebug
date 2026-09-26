import assert from 'node:assert/strict';

function timeKey(text) {
  const m = /^(-?\d+)\/(\d+):(-?\d+):(\d+)$/.exec(text ?? '');
  assert(m && m[2] !== '0' && m[3] === '0' && m[4] === '1', 'Invalid or rounded PTS');
  let a = BigInt(m[1]),
    b = BigInt(m[2]);
  let x = a < 0n ? -a : a,
    y = b;
  while (y) [x, y] = [y, x % y];
  return `${a / x}/${b / x}`;
}
function number(value) {
  const n = Number(value);
  assert(
    typeof value === 'string' && value !== '' && Number.isFinite(n),
    'Missing/nonfinite scalar',
  );
  return n;
}
function exactly(events, kind, count = 1) {
  const values = events.filter((e) => e.kind === kind);
  assert.equal(values.length, count, `Wrong ${kind} count`);
  return count === 1 ? values[0] : values;
}
function indexFrames(events, kind) {
  const rows = exactly(events, kind, 360),
    map = new Map();
  for (const row of rows) {
    const key = timeKey(row.fields.pts);
    assert(!map.has(key), `Duplicate ${kind} PTS`);
    map.set(key, row);
  }
  return map;
}
export function analyzeDownshift(report) {
  assert(['resize', 'rate', 'rate-resize'].includes(report.mode));
  assert.equal(report.cleanupCallsCompleted, true);
  assert.equal(report.drainCompleted, true, 'Native drain not proven');
  assert(!report.failure, 'Harness reported failure');
  assert.equal(report.overflow, false);
  const events = report.events;
  assert(Array.isArray(events) && events.length <= 20_000);
  for (const e of events) {
    assert(Number.isFinite(e.at) && e.at >= 0 && typeof e.kind === 'string');
    assert(e.fields && Object.values(e.fields).every((v) => typeof v === 'string'));
  }
  const start = exactly(events, 'started'),
    baseline = exactly(events, 'baseline');
  const mutation = exactly(events, 'mutation-started'),
    requested = exactly(events, 'mutation-requested');
  const end = exactly(events, 'mutation-finished'),
    finish = exactly(events, 'finished');
  assert(
    start.at <= baseline.at &&
      baseline.at < requested.at &&
      requested.at <= mutation.at &&
      mutation.at <= end.at &&
      end.at <= finish.at,
  );
  // Earlier traces used a fixed frame180 boundary. Preserve that exact contract.
  const phase = start.fields.mutationFrame ?? '180';
  assert(['180', '181'].includes(phase), 'Unsupported mutation frame');
  const mutationFrame = Number(phase);
  const generation = start.fields.generation,
    oldEncoder = baseline.fields.encoder;
  assert(generation && oldEncoder && baseline.fields.configuration);
  assert.equal(baseline.fields.generation, generation);
  assert.equal(baseline.fields.bitrate, '3000000');
  const input = indexFrames(events, 'input'),
    submitted = indexFrames(events, 'submitted');
  const completed = indexFrames(events, 'completed'),
    compressed = indexFrames(events, 'compressed'),
    muxed = indexFrames(events, 'muxed');
  const inputs = [...input.values()];
  assert.equal(
    timeKey(inputs[0].fields.pts),
    timeKey(start.fields.selectedStart),
    'Input starts outside selected interval',
  );
  for (let i = 0; i < inputs.length; i++) {
    assert.equal(inputs[i].fields.index, String(i));
    if (i) {
      const [a, b] = timeKey(inputs[i].fields.pts).split('/').map(BigInt);
      const [c, d] = timeKey(inputs[i - 1].fields.pts)
        .split('/')
        .map(BigInt);
      assert.equal((a * d - c * b) * 30n, b * d, 'Source PTS must advance exactly 1/30');
    }
  }
  assert(
    inputs[mutationFrame].at <= requested.at && requested.at < inputs[mutationFrame + 1].at,
    'Mutation request is not at declared frame',
  );
  // Exclude startup/baseline initialization. This 30fps harness tolerance is not
  // a product loss threshold: reject catch-up/stalls as a measurement confound.
  const inputGaps = inputs.slice(61).map((e, i) => e.at - inputs[i + 60].at);
  assert(
    inputGaps.every((d) => d >= 1 / 60 && d <= 1 / 20),
    'Input cadence is bursty/stalled',
  );
  const preRate = exactly(events, 'rate-receipt', report.mode === 'resize' ? 0 : 1);
  const resize = exactly(events, 'resize-receipt', report.mode === 'rate' ? 0 : 1);
  const finalRate = exactly(events, 'final-rate-receipt', report.mode === 'rate' ? 0 : 1);
  const resizeRequest = exactly(events, 'resize-requested', report.mode === 'rate' ? 0 : 1);
  const rates = [baseline];
  if (report.mode !== 'resize') {
    assert.equal(preRate.fields.encoder, oldEncoder);
    assert.equal(preRate.fields.bitrate, '600000');
    assert(mutation.at <= preRate.at && preRate.at <= end.at);
    rates.push(preRate);
  }
  if (report.mode !== 'rate') {
    assert.equal(resize.fields.generation, generation);
    assert(mutation.at <= resizeRequest.at && resizeRequest.at <= resize.at);
    if (report.mode === 'rate-resize')
      assert(preRate.at <= resizeRequest.at, 'Resize started before preliminary rate receipt');
    assert.equal(resize.fields.previousEncoder, oldEncoder);
    assert(resize.fields.encoder && resize.fields.encoder !== oldEncoder);
    assert.equal(resize.fields.rawDropped, '0');
    assert.equal(resize.fields.width, '640');
    assert.equal(resize.fields.height, '360');
    assert.equal(finalRate.fields.encoder, resize.fields.encoder);
    assert.equal(finalRate.fields.bitrate, '600000');
    assert(mutation.at <= resize.at && resize.at <= finalRate.at && finalRate.at <= end.at);
    rates.push(finalRate);
  }
  for (const rate of rates) {
    assert.equal(rate.fields.generation, generation);
    const last = submitted.get(timeKey(rate.fields.lastPTS));
    assert(
      last && last.fields.encoder === rate.fields.encoder && last.at <= rate.at,
      'Rate lastPTS is not an acknowledged encoder submission',
    );
  }
  let replacementTiming = null;
  if (report.mode !== 'rate') {
    const old = inputs.filter(
      (i) => completed.get(timeKey(i.fields.pts))?.fields.encoder === oldEncoder,
    );
    const fresh = inputs.filter(
      (i) => completed.get(timeKey(i.fields.pts))?.fields.encoder === resize.fields.encoder,
    );
    assert(old.length && fresh.length);
    const lastOld = old.at(-1),
      firstNew = fresh[0];
    assert.equal(timeKey(resize.fields.oldPTS), timeKey(lastOld.fields.pts));
    assert.equal(timeKey(resize.fields.newPTS), timeKey(firstNew.fields.pts));
    assert(
      Number(lastOld.fields.index) < Number(firstNew.fields.index),
      'Interleaved encoder boundary',
    );
    const firstOutput = compressed.get(timeKey(firstNew.fields.pts));
    assert(
      firstOutput && firstOutput.fields.sync === 'true' && firstOutput.at <= resize.at,
      'First new output must precede receipt and be sync',
    );
    const firstPTS = timeKey(firstNew.fields.pts);
    const firstSubmission = submitted.get(firstPTS);
    const firstCompletion = completed.get(firstPTS);
    assert(
      firstSubmission.at >= resizeRequest.at,
      'First new submission precedes replacement request',
    );
    // Per-frame validation below binds these native times and encoder identity.
    // Request-to-submission includes actor scheduling, old drain and new setup;
    // it does not identify the duration of any one of those operations.
    replacementTiming = {
      scope:
        'Matched native first-new-frame boundaries; not a direct drain measurement or network/media qualification',
      firstNewSourcePTS: firstPTS,
      requestToFirstSubmissionMs: (firstSubmission.at - resizeRequest.at) * 1000,
      firstSubmissionToCompletionMs: (firstCompletion.at - firstSubmission.at) * 1000,
      firstCompletionToCompressedMs: (firstOutput.at - firstCompletion.at) * 1000,
      compressedToReceiptMs: (resize.at - firstOutput.at) * 1000,
      requestToReceiptMs: (resize.at - resizeRequest.at) * 1000,
      newSubmissionsBeforeFirstCompletion: [...submitted.values()].filter(
        (e) => e.fields.encoder === resize.fields.encoder && e.at < firstCompletion.at,
      ).length,
    };
  }
  const configurations = new Map(rates.map((r) => [r.fields.configuration, r]));
  assert.equal(configurations.size, rates.length);
  const frames = [];
  for (const [pts, i] of input) {
    const s = submitted.get(pts),
      c = completed.get(pts),
      v = compressed.get(pts),
      m = muxed.get(pts);
    assert(s && c && v && m, 'Missing/cross-source frame evidence');
    assert.equal(s.fields.status, '0');
    assert.equal(s.fields.encoder, c.fields.encoder);
    assert.equal(timeKey(c.fields.outputPTS), pts);
    assert.equal(number(c.fields.submittedAt), s.at, 'Completion/submission timing mismatch');
    assert.equal(number(c.fields.completedAt), c.at, 'Completion timestamp mismatch');
    assert(s.at >= i.at && number(s.fields.returnedAt) >= s.at);
    assert(
      number(c.fields.submittedAt) <= c.at && c.at <= v.at && v.at <= m.at && m.at <= finish.at,
    );
    if (c.fields.configuration) {
      const rate = configurations.get(c.fields.configuration);
      assert(rate, 'Unknown configuration');
      assert.equal(c.fields.encoder, rate.fields.encoder);
      assert.equal(c.fields.bitrate, rate.fields.bitrate);
      assert(number(c.fields.submittedAt) >= rate.at);
    }
    const old = c.fields.encoder === oldEncoder;
    if (!old) assert.equal(c.fields.encoder, resize.fields.encoder);
    assert.equal(v.fields.width, old ? '1280' : '640');
    assert.equal(v.fields.height, old ? '720' : '360');
    assert.equal(v.fields.generation, generation);
    assert.equal(m.fields.generation, generation);
    assert.equal(v.fields.codec, '1635148593');
    assert.equal(v.fields.valid, 'true');
    assert.equal(v.fields.encoded, 'true');
    assert.equal(v.fields.paced, 'false');
    assert(['true', 'false'].includes(v.fields.sync));
    assert.equal(m.fields.media, 'video');
    const bytes = number(v.fields.bytes);
    assert(Number.isSafeInteger(bytes) && bytes > 0);
    frames.push({
      pts,
      at: v.at,
      bytes,
      old,
      submittedAt: number(c.fields.submittedAt),
      configuration: c.fields.configuration,
    });
  }
  const requiredRates = report.mode === 'rate-resize' ? [baseline, finalRate] : rates;
  for (const rate of requiredRates)
    assert(
      frames.some((f) => f.configuration === rate.fields.configuration),
      'No output witness for final rate',
    );
  const tail = frames.filter((f) => f.submittedAt < mutation.at && f.at >= mutation.at);
  const seconds = Array.from({ length: 9 }, (_, i) => {
    const from = i - 3,
      selected = frames.filter((f) => f.at >= mutation.at + from && f.at < mutation.at + from + 1);
    return {
      from,
      frames: selected.length,
      encodedBits: selected.reduce((s, f) => s + f.bytes * 8, 0),
    };
  });
  const buckets = new Map();
  for (const f of frames.filter((f) => f.at >= mutation.at && f.at < mutation.at + 3)) {
    const key = Math.floor((f.at - mutation.at) * 10);
    buckets.set(key, (buckets.get(key) ?? 0) + f.bytes);
  }
  return {
    mode: report.mode,
    source: report.source,
    sourcePTS: [...input.keys()],
    scope: 'Host native video encoder/mux only; mocked sink, no network/A/V qualification',
    mutationFrame,
    mutationMilliseconds: (end.at - mutation.at) * 1000,
    replacementTiming,
    preMutationSubmittedTailFrames: tail.length,
    preMutationSubmittedTailBytes: tail.reduce((s, f) => s + f.bytes, 0),
    rateOutputWitnessCounts: rates.map((r) => ({
      kind: r.kind,
      frames: frames.filter((f) => f.configuration === r.fields.configuration).length,
    })),
    peakEncodedBytesPer100msAfterMutation: Math.max(0, ...buckets.values()),
    inputGapRangeMs: [Math.min(...inputGaps) * 1000, Math.max(...inputGaps) * 1000],
    encoderSelections: [...new Set([...submitted.values()].map((e) => e.fields.selection))],
    outputBySecond: seconds,
  };
}
export function compareDownshifts(reports) {
  assert.deepEqual(reports.map((r) => r.mode).sort(), ['rate', 'rate-resize', 'resize']);
  const cases = reports.map(analyzeDownshift);
  for (const c of cases.slice(1)) {
    assert.equal(c.mutationFrame, cases[0].mutationFrame, 'Cases used different mutation frames');
    assert.equal(c.source, cases[0].source);
    assert.deepEqual(c.sourcePTS, cases[0].sourcePTS, 'Cases consumed different source frames');
  }
  return cases;
}
