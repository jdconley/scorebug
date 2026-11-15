import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { capacityClockScope } from './capacity-clock-brackets.mjs';
const uuid = (value) => {
  assert(
    typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value),
    'Invalid clock nonce',
  );
  return value.toLowerCase();
};
const time = (value) =>
  assert(
    typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12,
    'Invalid clock',
  );
const keys = (value, fields) => {
  assert(value && typeof value === 'object' && !Array.isArray(value));
  assert.deepEqual(Object.keys(value).sort(), [...fields].sort());
};
/** Caller supplies bounded atomic file I/O in the owned app container. Every
 * operation is awaited even on cancellation; no detached polling or deadline reset. */
export async function sampleCapacityClock({
  scope,
  sequence,
  nonce = randomUUID(),
  signal,
  write,
  read,
  now = () => performance.now(),
  wait = (ms) => delay(ms, undefined, { signal }),
}) {
  const expected = capacityClockScope(scope),
    owner = uuid(nonce);
  assert(Number.isSafeInteger(sequence) && sequence >= 1 && sequence <= 4);
  assert(signal instanceof AbortSignal);
  assert([write, read, now, wait].every((f) => typeof f === 'function'));
  const request = { formatVersion: 1, scope: expected, sequence, nonce: owner };
  const requestAt = now();
  time(requestAt);
  let previous = requestAt;
  const check = () => {
    signal.throwIfAborted();
    const at = now();
    time(at);
    assert(at >= previous, 'Host clock regressed');
    previous = at;
    assert(at - requestAt <= 250, 'Clock exchange exceeds 250ms');
    return at;
  };
  check();
  await write(structuredClone(request));
  check();
  for (let index = 0; index < 64; index++) {
    const response = await read(),
      responseAt = check();
    if (response !== null) {
      keys(response, ['formatVersion', 'scope', 'sample']);
      assert.equal(response.formatVersion, 1);
      assert.deepEqual(capacityClockScope(response.scope), expected);
      const sample = response.sample;
      keys(sample, ['sequence', 'nonce', 'nativeAt']);
      assert(
        Number.isSafeInteger(sample.sequence) &&
          sample.sequence >= 1 &&
          sample.sequence <= sequence,
      );
      time(sample.nativeAt);
      const receivedNonce = uuid(sample.nonce);
      if (sample.sequence === sequence) {
        assert.equal(receivedNonce, owner, 'Reply to another clock challenge');
        return { requestAt, responseAt, request, response: structuredClone(response) };
      }
      assert.notEqual(receivedNonce, owner, 'Reused nonce from an older clock challenge');
    }
    await wait(Math.min(10, 250 - (responseAt - requestAt)));
    check();
  }
  throw Error('Clock exchange exhausted bounded polls');
}
