import { expect, it } from 'vitest';
import { decoderCadenceSchema, advanceCadence } from '../src/decoder-cadence.js';
export const cadence = () => ({
  formatVersion: 1 as const,
  scopeID: '11111111-1111-4111-8111-111111111111',
  oneSecond: {
    sequence: 2,
    durationMs: 1000 as const,
    ageMs: 100,
    firstPTS: 90000,
    lastPTS: 177000,
    freshFrames: 30,
    duplicateFrames: 0,
    reorderedFrames: 0,
    valid: true,
  },
  twoSeconds: {
    sequence: 1,
    durationMs: 2000 as const,
    ageMs: 100,
    firstPTS: 0,
    lastPTS: 177000,
    freshFrames: 60,
    duplicateFrames: 0,
    reorderedFrames: 0,
    valid: true,
  },
  progress: { lastFreshPTS: 180000, ageMs: 50, stalled: false },
  invalidReason: null,
  ended: false,
});
it('validates exact bounded cadence shape without inventing delivery claims', () => {
  expect(decoderCadenceSchema.parse(cadence())).toEqual(cadence());
  for (const mutate of [
    (c: any) => (c.formatVersion = 2),
    (c: any) => (c.scopeID = 'old'),
    (c: any) => (c.oneSecond.durationMs = 5000),
    (c: any) => (c.oneSecond.freshFrames = -1),
    (c: any) => (c.oneSecond.firstPTS = null),
    (c: any) => (c.oneSecond.valid = false),
    (c: any) => (c.progress.stalled = true),
    (c: any) => (c.progress.lastFreshPTS = 0),
    (c: any) => (c.oneSecond.sequence = 5),
    (c: any) => (c.twoSeconds.ageMs = 500),
    (c: any) => (c.capacity = 1000000),
    (c: any) => {
      c.oneSecond.freshFrames = Number.MAX_SAFE_INTEGER;
      c.oneSecond.duplicateFrames = 1;
    },
  ]) {
    const c = cadence();
    mutate(c);
    expect(decoderCadenceSchema.safeParse(c).success).toBe(false);
  }
});
it('retains windows and progress across omissions while rejecting changed content and regressions', () => {
  const before = advanceCadence(undefined, cadence());
  expect(advanceCadence(before, undefined)).toBe(before);
  for (const mutate of [
    (c: any) => (c.scopeID = '22222222-2222-4222-8222-222222222222'),
    (c: any) => (c.oneSecond.freshFrames = 29),
    (c: any) => (c.progress.lastFreshPTS = 177000),
    (c: any) => (c.progress.ageMs = 49),
    (c: any) => {
      c.oneSecond.ageMs = 99;
      c.twoSeconds.ageMs = 99;
    },
  ]) {
    const c = cadence();
    mutate(c);
    expect(() => advanceCadence(before, c)).toThrow();
  }
});
it('latches closed and invalid telemetry and cannot reuse source identities after empty windows', () => {
  let c: any = cadence();
  c.ended = true;
  expect(() => advanceCadence(advanceCadence(undefined, c), cadence())).toThrow();
  c = cadence();
  c.invalidReason = 'clock';
  c.oneSecond.valid = false;
  c.twoSeconds.valid = false;
  expect(() => advanceCadence(advanceCadence(undefined, c), cadence())).toThrow();
  const first = advanceCadence(undefined, cadence());
  c = cadence();
  c.oneSecond = {
    ...c.oneSecond,
    sequence: 3,
    firstPTS: null,
    lastPTS: null,
    freshFrames: 0,
    ageMs: 100,
  };
  c.twoSeconds.ageMs = 1100;
  c.progress.ageMs = 1050;
  c.progress.stalled = true;
  const empty = advanceCadence(first, c);
  c = cadence();
  c.oneSecond.sequence = 4;
  c.twoSeconds.sequence = 2;
  expect(() => advanceCadence(empty, c)).toThrow();
});
