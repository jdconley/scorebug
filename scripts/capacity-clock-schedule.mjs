import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { capacityClockScope } from './capacity-clock-brackets.mjs';
import { sampleCapacityClock } from './capacity-clock-exchange.mjs';
import { measuredCapacityUplinkConfiguration } from './measured-capacity-uplink.mjs';

const time = (n) =>
  assert(typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1e12, 'Invalid host clock');

/** Observe the owned proxy; never control or delay its rate changes. This returns
 * raw exchanges only. Final native audit and transport/media replay are required. */
export async function collectCapacityClockExchanges({
  scope,
  snapshot,
  write,
  read,
  signal,
  now = () => performance.now(),
  wait = (ms) => delay(ms, undefined, { signal }),
}) {
  const expectedScope = capacityClockScope(scope);
  assert(signal instanceof AbortSignal);
  assert([snapshot, write, read, now, wait].every((f) => typeof f === 'function'));
  const requested = measuredCapacityUplinkConfiguration('capacity550k').forwardRateSchedule;
  let previousTime = -1,
    origin,
    previousPhases = [];
  const check = () => {
    signal.throwIfAborted();
    const at = now();
    time(at);
    assert(at >= previousTime, 'Host clock regressed');
    previousTime = at;
    return at;
  };
  function observe() {
    check();
    const schedule = snapshot()?.forwardRateSchedule;
    const at = check();
    assert(schedule, 'Missing owned rate schedule');
    assert.deepEqual(schedule.requested, requested);
    assert.equal(schedule.stoppedAt, null, 'Proxy closed before clock collection');
    time(schedule.startedAt);
    if (origin === undefined) origin = schedule.startedAt;
    assert.equal(schedule.startedAt, origin, 'Proxy origin changed');
    assert(
      Array.isArray(schedule.phases) && schedule.phases.length >= 1 && schedule.phases.length <= 3,
    );
    const phases = schedule.phases.map((phase, index) => {
      assert.equal(phase.atMilliseconds, requested[index].atMilliseconds);
      assert.equal(phase.rateBitsPerSecond, requested[index].rateBitsPerSecond);
      time(phase.appliedAt);
      const due = origin + phase.atMilliseconds;
      assert(
        phase.appliedAt >= due && phase.appliedAt <= due + 2000 && phase.appliedAt <= at,
        'Invalid applied phase time',
      );
      return {
        atMilliseconds: phase.atMilliseconds,
        rateBitsPerSecond: phase.rateBitsPerSecond,
        appliedAt: phase.appliedAt,
      };
    });
    assert(phases.length >= previousPhases.length, 'Applied phase disappeared');
    assert.deepEqual(
      phases.slice(0, previousPhases.length),
      previousPhases,
      'Applied phase changed',
    );
    previousPhases = phases;
    return phases;
  }
  async function waitUntil(target) {
    for (let index = 0; index < 256; index++) {
      const remaining = target - check();
      if (remaining <= 0) return;
      await wait(Math.min(1000, remaining));
    }
    throw Error('Clock scheduling exhausted bounded waits');
  }
  observe();
  const exchanges = [];
  for (const phaseIndex of [1, 2]) {
    const due = origin + requested[phaseIndex].atMilliseconds;
    await waitUntil(due - 500);
    assert(check() <= due - 250, 'Too late for a bounded before challenge');
    assert.equal(observe().length, phaseIndex, 'Fault already applied before challenge');
    const before = await sampleCapacityClock({
      scope: expectedScope,
      sequence: phaseIndex * 2 - 1,
      signal,
      write,
      read,
      now: check,
      wait,
    });
    exchanges.push(before);
    let phase;
    for (let index = 0; index < 128; index++) {
      assert(check() - before.requestAt <= 1500, 'Applied phase missed clock bracket');
      phase = observe()[phaseIndex];
      if (phase) break;
      await wait(10);
    }
    assert(phase, 'Applied phase missing after bounded polls');
    assert(before.responseAt < phase.appliedAt, 'Before response missed applied fault');
    assert(check() >= phase.appliedAt);
    const after = await sampleCapacityClock({
      scope: expectedScope,
      sequence: phaseIndex * 2,
      signal,
      write,
      read,
      now: check,
      wait,
    });
    assert(after.requestAt >= phase.appliedAt);
    assert(after.responseAt - before.requestAt <= 1500, 'Host clock bracket exceeds 1.5s');
    assert(
      after.response.sample.nativeAt > before.response.sample.nativeAt &&
        after.response.sample.nativeAt - before.response.sample.nativeAt <= 1.5,
      'Native clock bracket exceeds 1.5s',
    );
    exchanges.push(after);
    observe();
  }
  return {
    formatVersion: 1,
    scope: expectedScope,
    exchanges,
    clockBracketsQualified: false,
    nativeAdaptationQualified: false,
  };
}
