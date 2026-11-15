import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyIngressObservation } from '../ingress-observation-qualification.mjs';

const pts = (frame) => ({ value: String(7395 + frame * 2), timescale: 60, epoch: '0', flags: 1 });
const audioPTS = (sample) => ({
  value: String(5_916_000 + sample),
  timescale: 48000,
  epoch: '0',
  flags: 1,
});
const summary = (count, first, last = first) => ({
  count: String(count),
  invalidPTSCount: '0',
  firstSourcePTS: first,
  lastSourcePTS: last,
  minimumSourcePTS: first,
  maximumSourcePTS: last,
  invalidity: 0,
});
const occupancy = (duration, pressure = false) => ({
  knownDuration: duration,
  unknownDuration: 0,
  itemSeconds: pressure ? 2 : 0,
  byteSeconds: pressure ? 2 : 0,
  maxPressureSeconds: pressure ? 3 : 0,
  peakItems: pressure ? 4 : 0,
  peakBytes: pressure ? 100 : 0,
});
function fixture() {
  const scope = {
    recordingID: 'recording',
    matchID: 'match',
    broadcastGeneration: 1,
    publishingAttemptID: '4ab12a92-ef52-4f22-a142-94e2f2eaa983',
    appliedProfileRevision: '1',
  };
  const dispositions = {
    admitted: { video: summary(4, pts(0), pts(3)), audio: summary(3, audioPTS(1), audioPTS(4801)) },
    dequeued: { video: summary(2, pts(0), pts(1)), audio: summary(3, audioPTS(1), audioPTS(4801)) },
    overflowEvicted: { video: summary(1, pts(2)) },
    cancellationDiscarded: { video: summary(1, pts(3)) },
    'rejected.full': { video: summary(1, pts(10)) },
  };
  const completed = {
    monotonicStart: 0,
    monotonicEnd: 5,
    scheduledMonotonicEnd: 5,
    coveredWindowCount: '1',
    isCoalesced: false,
    isPartial: false,
    isClosed: false,
    occupancy: occupancy(5, true),
    occupancyByPhase: { startup: occupancy(1), admitting: occupancy(4, true) },
    dispositions: structuredClone(dispositions),
  };
  const current = {
    monotonicStart: 5,
    monotonicEnd: 6,
    scheduledMonotonicEnd: 10,
    coveredWindowCount: '1',
    isCoalesced: false,
    isPartial: true,
    isClosed: true,
    occupancy: occupancy(1),
    occupancyByPhase: { admitting: occupancy(1) },
    dispositions: {},
  };
  return {
    snapshot: {
      formatVersion: 1,
      scope,
      monotonicAnchor: 0,
      windowDuration: 5,
      captureDetachedAt: 5.5,
      current: { monotonicEnd: 7 },
      ingressObservation: {
        formatVersion: 1,
        scope: { ...scope },
        monotonicAnchor: 0,
        windowDuration: 5,
        maxItems: 4,
        maxBytes: 100,
        phase: 'closed',
        currentItems: 0,
        currentBytes: 0,
        current,
        completed: [completed],
        totalOccupancy: occupancy(6, true),
        totalDispositions: dispositions,
        omittedCompletedWindowCount: '0',
        omittedThroughMonotonicTime: null,
        rejectedClockOperationCount: '0',
        unassignedDispositionCount: '0',
        invalidity: 0,
        isClosed: true,
      },
    },
    archive: {
      firstSourceFrame: 0,
      lastSourceFrame: 299,
      frames: 300,
      coverage: { audioStartTime: 0, audioEndTime: 10, videoStartTime: 0, videoEndTime: 10 },
    },
  };
}
const ingress = (f) => f.snapshot.ingressObservation;
const reject = (mutate, pattern) => {
  const f = fixture();
  mutate(f);
  assert.throws(() => qualifyIngressObservation(f), pattern);
};

test('qualifies conserved buffer counts without equating dequeued to encoded frames', () => {
  const result = qualifyIngressObservation(fixture());
  assert.equal(result.totalOccupancy.meanItemOccupancy, 1 / 3);
  assert.equal(result.totalOccupancy.meanMaxPressure, 0.5);
  assert.equal(result.totalDispositions.dequeued.audio.count, '3');
  assert.equal(result.totalDispositions.overflowEvicted.video.count, '1');
  assert.equal(result.totalDispositions.cancellationDiscarded.video.count, '1');
  assert.equal(result.totalDispositions['rejected.full'].video.count, '1');
  assert.equal(result.windows.length, 2);
  assert.equal(result.closedAt, 6);
  assert.doesNotThrow(() => JSON.stringify(result));
});

test('requires ingress and exact scope, anchor, duration and bounded history configuration', () => {
  reject((f) => {
    delete f.snapshot.ingressObservation;
  }, /ingress/i);
  for (const key of Object.keys(fixture().snapshot.scope))
    reject((f) => {
      ingress(f).scope[key] = 'other';
    }, /scope/i);
  reject((f) => {
    ingress(f).monotonicAnchor = 1;
  }, /anchor/i);
  reject((f) => {
    ingress(f).windowDuration = 10;
  }, /duration/i);
  reject((f) => {
    ingress(f).formatVersion = 2;
  }, /format/i);
  reject((f) => {
    f.completedWindowLimit = 129;
  }, /history/i);
});

test('requires terminal zero queue and closure inside capture detach to video shutdown', () => {
  for (const key of ['currentItems', 'currentBytes'])
    reject((f) => {
      ingress(f)[key] = 1;
    }, /terminal|depth/i);
  reject((f) => {
    ingress(f).phase = 'admitting';
  }, /closed/i);
  reject((f) => {
    ingress(f).isClosed = false;
  }, /closed/i);
  reject((f) => {
    f.snapshot.captureDetachedAt = 6.1;
  }, /closure/i);
  reject((f) => {
    f.snapshot.current.monotonicEnd = 5.9;
  }, /closure/i);
});

test('rejects incomplete history, unknown timing, invalidity and saturated counters', () => {
  for (const key of [
    'omittedCompletedWindowCount',
    'rejectedClockOperationCount',
    'unassignedDispositionCount',
  ])
    reject((f) => {
      ingress(f)[key] = '1';
    }, /omitted|clock|unassigned/i);
  reject((f) => {
    ingress(f).omittedThroughMonotonicTime = 0;
  }, /omitted/i);
  reject((f) => {
    ingress(f).invalidity = 2;
  }, /invalidity/i);
  reject((f) => {
    ingress(f).current.occupancy.unknownDuration = 0.5;
  }, /unknown/i);
  reject((f) => {
    ingress(f).totalDispositions.admitted.video.count = '18446744073709551616';
  }, /counter|64/i);
});

test('rejects malformed numeric and counter fields without coercion', () => {
  for (const value of [NaN, Infinity, -1, '4'])
    reject((f) => {
      ingress(f).maxItems = value;
    }, /items|integer/i);
  for (const value of [1, '-0', '01', '-1', '1.0', '9007199254740992'])
    reject((f) => {
      ingress(f).totalDispositions.admitted.video.count = value;
    }, /counter|integer/i);
  for (const value of [NaN, Infinity, -1, '0'])
    reject((f) => {
      ingress(f).current.occupancy.itemSeconds = value;
    }, /finite|area/i);
});

test('rejects illegal areas, pressure relationships, peaks and phase attribution', () => {
  reject((f) => {
    ingress(f).completed[0].occupancy.itemSeconds = 6;
  }, /area/i);
  reject((f) => {
    ingress(f).completed[0].occupancy.maxPressureSeconds = 1;
  }, /maximum|pressure/i);
  reject((f) => {
    ingress(f).completed[0].occupancy.maxPressureSeconds = 4.5;
  }, /maximum|pressure/i);
  reject((f) => {
    ingress(f).completed[0].occupancy.peakItems = 0;
  }, /peak|area/i);
  reject((f) => {
    ingress(f).completed[0].occupancyByPhase.admitting.knownDuration = 3;
  }, /phase/i);
  reject((f) => {
    ingress(f).completed[0].occupancyByPhase.closed = occupancy(0);
  }, /phase/i);
});

test('rejects window geometry gaps, forged full intervals and invalid terminal flags', () => {
  reject((f) => {
    ingress(f).current.monotonicStart = 5.1;
  }, /contiguous/i);
  reject((f) => {
    ingress(f).completed[0].monotonicEnd = 4;
  }, /complete|duration/i);
  reject((f) => {
    ingress(f).current.isClosed = false;
  }, /closed/i);
  reject((f) => {
    ingress(f).current.isPartial = false;
  }, /partial/i);
  reject((f) => {
    ingress(f).current.coveredWindowCount = '2';
  }, /scheduled|partial/i);
});

test('rejects count conservation failures and window totals that hide dispositions', () => {
  reject((f) => {
    ingress(f).totalDispositions.dequeued.video.count = '3';
  }, /sum|total|conserv/i);
  reject((f) => {
    delete ingress(f).completed[0].dispositions.overflowEvicted;
  }, /sum|total|conserv/i);
  reject((f) => {
    ingress(f).completed[0].dispositions.admitted.video.count = '5';
    ingress(f).totalDispositions.admitted.video.count = '5';
  }, /conserv/i);
  reject((f) => {
    ingress(f).totalOccupancy.byteSeconds = 2.5;
  }, /sum|total/i);
});

test('rejects unknown schema keys and unrecognized kind or disposition', () => {
  reject((f) => {
    ingress(f).meanPressure = 0;
  }, /schema|key/i);
  reject((f) => {
    ingress(f).totalDispositions.dropped = {};
  }, /disposition/i);
  reject((f) => {
    ingress(f).totalDispositions.admitted.other = summary(1, pts(1));
  }, /kind/i);
  reject((f) => {
    ingress(f).current.occupancy.meanMaxPressure = 0;
  }, /schema|key/i);
});

test('rejects invalid PTS, epoch changes, malformed rational values and archive escape', () => {
  for (const mutate of [
    (s) => {
      s.invalidPTSCount = '1';
    },
    (s) => {
      s.invalidity = 8;
    },
    (s) => {
      s.minimumSourcePTS = null;
    },
    (s) => {
      s.minimumSourcePTS.epoch = '1';
    },
    (s) => {
      s.minimumSourcePTS.value = 7395;
    },
    (s) => {
      s.minimumSourcePTS.flags = 3;
    },
    (s) => {
      s.minimumSourcePTS.timescale = 0;
    },
    (s) => {
      s.maximumSourcePTS = pts(300);
    },
    (s) => {
      s.minimumSourcePTS = pts(5);
    },
  ])
    reject(
      (f) => mutate(ingress(f).totalDispositions.admitted.video),
      /PTS|epoch|rational|bounds|extrema|invalidity|decimal/i,
    );
});

test('audio rational timestamps need not align with video frames but must lie inside audio coverage', () => {
  assert.doesNotThrow(() => qualifyIngressObservation(fixture()));
  reject((f) => {
    ingress(f).totalDispositions.admitted.audio.maximumSourcePTS = audioPTS(480000);
  }, /audio.*bounds/i);
  reject((f) => {
    delete f.archive.coverage;
  }, /coverage/i);
  reject((f) => {
    f.archive.firstSourceFrame = 1;
  }, /archive/i);
});

test('coalesced occupied gaps retain all duration and pressure without pretending to be policy windows', () => {
  const f = fixture(),
    q = ingress(f);
  q.completed = [
    {
      ...q.completed[0],
      monotonicEnd: 10,
      scheduledMonotonicEnd: 10,
      coveredWindowCount: '2',
      isCoalesced: true,
      occupancy: {
        ...occupancy(10),
        itemSeconds: 10,
        byteSeconds: 10,
        maxPressureSeconds: 10,
        peakItems: 4,
        peakBytes: 100,
      },
      dispositions: {},
    },
  ];
  q.completed[0].occupancyByPhase = { admitting: structuredClone(q.completed[0].occupancy) };
  q.current = {
    ...q.current,
    monotonicStart: 10,
    monotonicEnd: 10,
    scheduledMonotonicEnd: 15,
    occupancy: occupancy(0),
    occupancyByPhase: {},
    dispositions: structuredClone(q.totalDispositions),
  };
  q.totalOccupancy = structuredClone(q.completed[0].occupancy);
  f.snapshot.captureDetachedAt = 9;
  f.snapshot.current.monotonicEnd = 11;
  // Empty coalesced history cannot be occupied without any earlier admission.
  assert.throws(() => qualifyIngressObservation(f), /occupancy|admi|conserv/i);
});

function occupiedGapFixture() {
  const f = fixture(),
    q = ingress(f);
  for (const row of Object.values(q.totalDispositions)) delete row.audio;
  delete q.totalDispositions['rejected.full'];
  const full = (duration) => ({
    ...occupancy(duration),
    itemSeconds: duration,
    byteSeconds: duration,
    maxPressureSeconds: duration,
    peakItems: 4,
    peakBytes: 100,
  });
  q.completed[0].occupancy = full(5);
  q.completed[0].occupancyByPhase = { admitting: full(5) };
  q.completed[0].dispositions = { admitted: structuredClone(q.totalDispositions.admitted) };
  q.completed.push({
    ...structuredClone(q.completed[0]),
    monotonicStart: 5,
    monotonicEnd: 15,
    scheduledMonotonicEnd: 15,
    coveredWindowCount: '2',
    isCoalesced: true,
    occupancy: full(10),
    occupancyByPhase: { admitting: full(10) },
    dispositions: {},
  });
  q.current = {
    ...q.current,
    monotonicStart: 15,
    monotonicEnd: 16,
    scheduledMonotonicEnd: 20,
    dispositions: structuredClone(q.totalDispositions),
  };
  delete q.current.dispositions.admitted;
  q.totalOccupancy = { ...full(15), knownDuration: 16 };
  f.snapshot.captureDetachedAt = 15.5;
  f.snapshot.current.monotonicEnd = 17;
  return f;
}

test('qualifies constant occupied coalescing and preserves its full duration', () => {
  const result = qualifyIngressObservation(occupiedGapFixture());
  assert.equal(result.windows[1].isCoalesced, true);
  assert.equal(result.windows[1].coveredWindowCount, 2);
  assert.equal(result.windows[1].occupancy.maxPressureSeconds, 10);
  assert.equal(result.totalOccupancy.meanMaxPressure, 15 / 16);
});

test('coalesced intervals cannot falsify changing or underintegrated item occupancy', () => {
  const f = occupiedGapFixture(),
    q = ingress(f);
  q.completed[1].occupancy.itemSeconds = 9;
  q.completed[1].occupancyByPhase.admitting.itemSeconds = 9;
  q.totalOccupancy.itemSeconds = 14;
  assert.throws(() => qualifyIngressObservation(f), /coalesced/i);
});

test('window summary extrema must agree with total rational extrema', () => {
  reject((f) => {
    ingress(f).totalDispositions.admitted.video.maximumSourcePTS = pts(4);
  }, /sum|total/i);
});

test('audio coverage boundary is strict and rationally precise', () => {
  const f = fixture(),
    q = ingress(f);
  for (const rows of [q.totalDispositions, q.completed[0].dispositions]) {
    rows.admitted.audio = summary(3, audioPTS(1), audioPTS(479999));
    rows.dequeued.audio = structuredClone(rows.admitted.audio);
  }
  assert.doesNotThrow(() => qualifyIngressObservation(f));
  for (const rows of [q.totalDispositions, q.completed[0].dispositions]) {
    rows.admitted.audio.maximumSourcePTS = audioPTS(480000);
    rows.dequeued.audio.maximumSourcePTS = audioPTS(480000);
  }
  assert.throws(() => qualifyIngressObservation(f), /audio.*bounds/i);
});

test('ordinary rejection-only windows cannot underreport unchanged occupied depth', () => {
  const f = occupiedGapFixture(),
    q = ingress(f);
  const row = structuredClone(q.completed[1]);
  row.coveredWindowCount = '1';
  row.isCoalesced = false;
  row.monotonicEnd = 10;
  row.scheduledMonotonicEnd = 10;
  row.occupancy = {
    ...occupancy(5),
    itemSeconds: 5,
    byteSeconds: 5,
    maxPressureSeconds: 5,
    peakItems: 4,
    peakBytes: 100,
  };
  row.occupancyByPhase = { admitting: structuredClone(row.occupancy) };
  const second = {
    ...structuredClone(row),
    monotonicStart: 10,
    monotonicEnd: 15,
    scheduledMonotonicEnd: 15,
  };
  row.dispositions = { 'rejected.full': { video: summary(1, pts(10)) } };
  q.totalDispositions['rejected.full'] = structuredClone(row.dispositions['rejected.full']);
  q.completed.splice(1, 1, row, second);
  assert.doesNotThrow(() => qualifyIngressObservation(f));
  for (const key of ['itemSeconds', 'byteSeconds']) {
    const bad = structuredClone(f),
      altered = ingress(bad);
    for (const window of altered.completed.slice(1)) {
      window.occupancy[key] = 0;
      window.occupancyByPhase.admitting = structuredClone(window.occupancy);
    }
    altered.totalOccupancy[key] = 5;
    assert.throws(() => qualifyIngressObservation(bad), /unchanged|constant/i);
  }
});
