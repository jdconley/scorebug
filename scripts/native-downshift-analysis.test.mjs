import { test } from 'node:test';
import assert from 'node:assert/strict';
import { analyzeDownshift, compareDownshifts } from './native-downshift-analysis.mjs';
function fixture(mode = 'resize', { mutationFrame = 180 } = {}) {
  const offset = mutationFrame / 30 - 6;
  const events = [];
  const add = (kind, at, fields = {}) => events.push({ kind, at, fields });
  add('started', 0, {
    generation: '1',
    selectedStart: '0/30:0:1',
    mutationFrame: String(mutationFrame),
  });
  add('baseline', 1.001, {
    generation: '1',
    encoder: 'old',
    configuration: 'base',
    bitrate: '3000000',
    lastPTS: '30/30:0:1',
  });
  add('mutation-requested', 6.009 + offset);
  add('mutation-started', 6.01 + offset);
  if (mode !== 'resize')
    add('rate-receipt', 6.012 + offset, {
      encoder: 'old',
      configuration: 'rate',
      bitrate: '600000',
      generation: '1',
      lastPTS: `${mutationFrame}/30:0:1`,
    });
  if (mode !== 'rate') {
    add('resize-requested', 6.013 + offset);
    add('resize-receipt', 6.037 + offset, {
      generation: '1',
      oldPTS: `${mutationFrame}/30:0:1`,
      newPTS: `${mutationFrame + 1}/30:0:1`,
      previousEncoder: 'old',
      encoder: 'new',
      width: '640',
      height: '360',
      rawDropped: '0',
    });
    add('final-rate-receipt', 6.038 + offset, {
      encoder: 'new',
      configuration: 'final',
      bitrate: '600000',
      generation: '1',
      lastPTS: `${mutationFrame + 1}/30:0:1`,
    });
  }
  add('mutation-finished', mode === 'rate' ? 6.013 + offset : 6.039 + offset);
  for (let i = 0; i < 360; i++) {
    const t = i / 30,
      pts = `${i}/30:0:1`,
      old = mode === 'rate' || i <= mutationFrame;
    let configuration = i >= 31 ? 'base' : undefined,
      bitrate = '3000000';
    if (i > mutationFrame) {
      configuration = mode === 'rate' ? 'rate' : i === mutationFrame + 1 ? undefined : 'final';
      bitrate = '600000';
    }
    add('input', t, { index: String(i), pts });
    add('submitted', t + 0.0005, {
      pts,
      encoder: old ? 'old' : 'new',
      returnedAt: String(t + 0.001),
      status: '0',
      selection: 'hardware',
    });
    add('completed', t + 0.002, {
      pts,
      outputPTS: pts,
      encoder: old ? 'old' : 'new',
      submittedAt: String(t + 0.0005),
      completedAt: String(t + 0.002),
      ...(configuration ? { configuration, bitrate } : {}),
    });
    add('compressed', t + 0.003, {
      pts,
      generation: '1',
      width: old ? '1280' : '640',
      height: old ? '720' : '360',
      bytes: i <= mutationFrame ? '12500' : '2500',
      codec: '1635148593',
      valid: 'true',
      encoded: 'true',
      paced: 'false',
      sync: i % 60 === 0 || (mode !== 'rate' && i === mutationFrame + 1) ? 'true' : 'false',
    });
    add('muxed', t + 0.004, { pts, generation: '1', media: 'video' });
  }
  add('finished', 12.1);
  return {
    mode,
    source: '/verified.mov',
    cleanupCallsCompleted: true,
    drainCompleted: true,
    overflow: false,
    events,
  };
}
test('compares matching native cases without pretending pre-rate has an output witness', () => {
  const reports = compareDownshifts(['resize', 'rate', 'rate-resize'].map((mode) => fixture(mode)));
  assert.equal(reports.length, 3);
  assert.equal(reports[2].rateOutputWitnessCounts.find((x) => x.kind === 'rate-receipt').frames, 0);
  assert.equal(
    reports[1].preMutationSubmittedTailFrames,
    0,
    'Future same-encoder frames are not pre-mutation tail',
  );
});
test('rejects missing drain, failure and overflow before analysis', () => {
  for (const patch of [{ drainCompleted: false }, { failure: 'count failed' }, { overflow: true }])
    assert.throws(() => analyzeDownshift({ ...fixture(), ...patch }));
});
test('rejects missing, duplicated and cross-source frames despite equal record counts', () => {
  for (const kind of ['submitted', 'completed', 'compressed', 'muxed']) {
    for (const pts of ['999/30:0:1', '0/30:0:1']) {
      const value = fixture(),
        rows = value.events.filter((e) => e.kind === kind);
      rows[20].fields.pts = pts;
      assert.throws(() => analyzeDownshift(value));
    }
  }
});
test('rejects stalled/catch-up input rather than attributing its burst to encoder', () => {
  const value = fixture();
  value.events.find((e) => e.kind === 'input' && e.fields.index === '190').at += 0.025;
  assert.throws(() => analyzeDownshift(value), /Input cadence/);
});
test('rejects foreign native configuration and final rate without matching output', () => {
  const value = fixture();
  value.events.find(
    (e) => e.kind === 'completed' && e.fields.configuration === 'final',
  ).fields.configuration = 'foreign';
  assert.throws(() => analyzeDownshift(value), /Unknown configuration/);
  const missing = fixture();
  missing.events.find((e) => e.kind === 'final-rate-receipt').fields.configuration = 'unwitnessed';
  assert.throws(() => analyzeDownshift(missing));
});
test('rejects unmatched source provenance across cases', () => {
  const reports = ['resize', 'rate', 'rate-resize'].map((mode) => fixture(mode));
  reports[1].source = '/different.mov';
  assert.throws(() => compareDownshifts(reports));
});

test('binds both completion timestamps to actual native submission/completion', () => {
  for (const key of ['submittedAt', 'completedAt']) {
    const r = fixture(),
      c = r.events.find((e) => e.kind === 'completed' && e.fields.configuration === 'base');
    c.fields[key] = String(Number(c.fields[key]) - 0.0001);
    assert.throws(() => analyzeDownshift(r));
  }
});
test('rejects changed receipt generations and unrelated receipt PTS', () => {
  for (const [kind, field, value] of [
    ['rate-receipt', 'generation', '2'],
    ['resize-receipt', 'generation', '2'],
    ['final-rate-receipt', 'generation', '2'],
    ['baseline', 'lastPTS', '999/30:0:1'],
    ['rate-receipt', 'lastPTS', '200/30:0:1'],
    ['resize-receipt', 'oldPTS', '179/30:0:1'],
    ['resize-receipt', 'newPTS', '182/30:0:1'],
    ['final-rate-receipt', 'lastPTS', '180/30:0:1'],
  ]) {
    const r = fixture('rate-resize');
    r.events.find((e) => e.kind === kind).fields[field] = value;
    assert.throws(() => analyzeDownshift(r), `${kind}.${field}`);
  }
});
test('rejects a nonsync new encoder boundary and reordered mutation operations', () => {
  const r = fixture();
  r.events.find((e) => e.kind === 'compressed' && e.fields.pts === '181/30:0:1').fields.sync =
    'false';
  assert.throws(() => analyzeDownshift(r));
  const reordered = fixture('rate-resize');
  reordered.events.find((e) => e.kind === 'resize-requested').at = 6.011;
  assert.throws(() => analyzeDownshift(reordered));
});
test('requires exact30fps source PTS and request at frame180', () => {
  const r = fixture();
  for (const e of r.events) {
    if (e.fields.pts === '100/30:0:1') e.fields.pts = '2001/600:0:1';
    if (e.fields.outputPTS === '100/30:0:1') e.fields.outputPTS = '2001/600:0:1';
  }
  assert.throws(() => analyzeDownshift(r));
  const early = fixture();
  early.events.find((e) => e.kind === 'mutation-requested').at = 5.9;
  assert.throws(() => analyzeDownshift(early));
});

test('rejects first input outside recorded selected interval', () => {
  const r = fixture();
  r.events.find((e) => e.kind === 'started').fields.selectedStart = '1/30:0:1';
  assert.throws(() => analyzeDownshift(r), /Input starts outside/);
});

test('accepts adjacent phase and binds comparisons to the same mutation frame', () => {
  const reports = ['resize', 'rate', 'rate-resize'].map((mode) =>
    fixture(mode, { mutationFrame: 181 }),
  );
  assert.equal(analyzeDownshift(reports[0]).mutationFrame, 181);
  assert.equal(compareDownshifts(reports).length, 3);
  reports[0] = fixture('resize');
  assert.throws(() => compareDownshifts(reports), /different mutation frames/);
});
test('rejects unsupported or falsely labelled mutation phases', () => {
  for (const phase of ['0', '180.5', '182', 'garbage']) {
    const r = fixture();
    r.events.find((e) => e.kind === 'started').fields.mutationFrame = phase;
    assert.throws(() => analyzeDownshift(r), /mutation frame/);
  }
  const r = fixture();
  r.events.find((e) => e.kind === 'started').fields.mutationFrame = '181';
  assert.throws(() => analyzeDownshift(r), /Mutation request/);
});
test('legacy trace without explicit mutation phase remains bound to frame180', () => {
  const r = fixture();
  delete r.events.find((e) => e.kind === 'started').fields.mutationFrame;
  assert.equal(analyzeDownshift(r).mutationFrame, 180);
});
