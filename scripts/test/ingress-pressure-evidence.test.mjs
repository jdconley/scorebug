import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyIngressPressure } from '../ingress-pressure-evidence.mjs';
const pts = (i) => ({ value: String(i), timescale: 30, epoch: '0', flags: 1 });
function fixture() {
  const scope = {
    recordingID: 'r',
    matchID: 'm',
    broadcastGeneration: 1,
    publishingAttemptID: '11111111-1111-4111-8111-111111111111',
    appliedProfileRevision: '1',
  };
  const capture = Array.from({ length: 420 }, (_, i) => ({
    sourcePTS: pts(i),
    observedAt: 100 + i / 30,
  }));
  return {
    pressure: {
      scope,
      isClosed: true,
      isQuarantined: false,
      omittedStates: '0',
      coveredThrough: 114,
      states: [
        { at: 100, itemFraction: 0, byteFraction: 0, phase: 'startup' },
        { at: 100.1, itemFraction: 1, byteFraction: 0.1, phase: 'admitting' },
        { at: 105, itemFraction: 0.25, byteFraction: 1, phase: 'admitting' },
      ],
    },
    source: {
      scope: structuredClone(scope),
      capture,
      encoded: capture.map((x) => ({ sourcePTS: x.sourcePTS })),
      intervalProbes: [
        {
          name: 'before',
          sourceStartExclusive: pts(0),
          sourceEndInclusive: pts(120),
          captureBoundaryStartTime: 100,
          captureBoundaryEndTime: 104,
          ingressPressure: null,
        },
        {
          name: 'after',
          sourceStartExclusive: pts(150),
          sourceEndInclusive: pts(300),
          captureBoundaryStartTime: 105,
          captureBoundaryEndTime: 110,
          ingressPressure: {
            start: 105,
            end: 110,
            itemSeconds: 1.25,
            byteSeconds: 5,
            maxPressureSeconds: 5,
            meanMaxPressure: 1,
          },
        },
        {
          name: 'crossing',
          sourceStartExclusive: pts(120),
          sourceEndInclusive: pts(300),
          captureBoundaryStartTime: 104,
          captureBoundaryEndTime: 110,
          ingressPressure: {
            start: 104,
            end: 110,
            itemSeconds: 2.25,
            byteSeconds: 5.1,
            maxPressureSeconds: 6,
            meanMaxPressure: 1,
          },
        },
      ],
    },
  };
}
test('replays piecewise max occupancy over exact source boundaries', () => {
  assert.deepEqual(qualifyIngressPressure(fixture()), {
    retainedStates: 3,
    verifiedIntervals: 2,
    unknownIntervals: 1,
    scope: 'Historical queue pressure over exact capture boundaries; not current health',
  });
});
for (const [name, change] of [
  ['fabricated mean', (x) => (x.source.intervalProbes[1].ingressPressure.meanMaxPressure = 0)],
  [
    'max of separate means',
    (x) => (x.source.intervalProbes[2].ingressPressure.maxPressureSeconds = 5.1),
  ],
  ['changed scope', (x) => (x.pressure.scope.recordingID = 'other')],
  ['truncated coverage', (x) => (x.pressure.coveredThrough = 109)],
  ['quarantined history', (x) => (x.pressure.isQuarantined = true)],
  ['evicted fixture states', (x) => (x.pressure.omittedStates = '1')],
  ['reversed transitions', (x) => x.pressure.states.reverse()],
  ['invalid depth', (x) => (x.pressure.states[1].itemFraction = 2)],
  ['draining phase relabeled as admission', (x) => (x.pressure.states[2].phase = 'draining')],
  [
    'source boundary detached from capture',
    (x) => (x.source.intervalProbes[1].captureBoundaryStartTime = 104),
  ],
  ['capture PTS detached from encoder', (x) => (x.source.capture[1].sourcePTS = pts(8))],
  ['unjustified unknown interval', (x) => (x.source.intervalProbes[1].ingressPressure = null)],
  [
    'duplicate probes',
    (x) => (x.source.intervalProbes[2] = structuredClone(x.source.intervalProbes[1])),
  ],
])
  test(`rejects ${name}`, () => {
    const x = fixture();
    change(x);
    assert.throws(() => qualifyIngressPressure(x));
  });
