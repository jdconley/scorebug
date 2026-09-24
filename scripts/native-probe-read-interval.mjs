import assert from 'node:assert/strict';

const check = (value, message) => assert.ok(value, `Native probe read interval: ${message}`);
const time = (value) =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12;
const count = (value) => {
  check(typeof value === 'string' && /^(0|[1-9][0-9]{0,7})$/.test(value), 'malformed acceptance');
  const n = Number(value);
  check(n <= 16 * 1024 * 1024 && n % 1316 === 0, 'unaligned or excessive acceptance');
  return n;
};

// Two native snapshots cannot put increasing acceptance and increasing leases
// in opposite orders, even when their asynchronous read intervals overlap.
export function assertNativeProbeStateOrder(a, b) {
  const na = count(a.acceptedPayloadBytes),
    nb = count(b.acceptedPayloadBytes);
  check(time(a.leaseDeadline) && time(b.leaseDeadline), 'invalid lease');
  if (na === nb)
    check(a.lastAcceptedAt === b.lastAcceptedAt, 'timestamp changed without acceptance');
  else if (na < nb)
    check(
      a.leaseDeadline <= b.leaseDeadline &&
        (a.lastAcceptedAt === null || a.lastAcceptedAt < b.lastAcceptedAt),
      'incompatible native state order',
    );
  else
    check(
      b.leaseDeadline <= a.leaseDeadline &&
        (b.lastAcceptedAt === null || b.lastAcceptedAt < a.lastAcceptedAt),
      'incompatible native state order',
    );
}

/** Read-order proof only. Callers independently validate owner identity, raw
 * events, native token pacing, measurement cost and authority at application.
 * Find one snapshot instant compatible with the whole history, not a different
 * favorable instant for each counter/lease comparison. Inputs are never edited. */
export function qualifyNativeProbeReadInterval(
  sample,
  { readStartedAt, readFinishedAt, usedAt, events },
) {
  check(
    [
      readStartedAt,
      readFinishedAt,
      usedAt,
      sample?.startedAt,
      sample?.lastAcceptedAt,
      sample?.leaseDeadline,
    ].every(time),
    'missing or invalid clock',
  );
  check(
    readStartedAt <= readFinishedAt && readFinishedAt <= usedAt && usedAt < sample.leaseDeadline,
    'reversed read, read after use, or expired lease',
  );
  check(
    sample.reason === null && sample.startedAt <= sample.lastAcceptedAt,
    'invalid live snapshot',
  );
  check(
    Array.isArray(events) && events.length > 0 && events.length <= 2000,
    'missing bounded native history',
  );
  const accepted = count(sample.acceptedPayloadBytes);
  check(accepted > 0, 'empty native snapshot');
  const renewedAt = sample.leaseDeadline - 0.3;
  let lower = Math.max(readStartedAt, sample.lastAcceptedAt, renewedAt);
  let upper = readFinishedAt,
    exclusive = false;
  const before = (at) => {
    check(time(at), 'invalid history time');
    if (at <= upper) {
      upper = at;
      exclusive = true;
    }
  };
  const renewal = events.find(
    (e) => e.sample.leaseDeadline === sample.leaseDeadline && e.sample.reason === null,
  );
  check(
    renewal &&
      count(renewal.sample.acceptedPayloadBytes) <= accepted &&
      (renewal.sample.lastAcceptedAt === null ||
        renewal.sample.lastAcceptedAt <= sample.lastAcceptedAt),
    'unobserved lease or counters before renewal',
  );
  for (const event of events) {
    check(time(event.observedAt), 'invalid native observation time');
    const other = event.sample,
      n = count(other.acceptedPayloadBytes);
    assertNativeProbeStateOrder(sample, other);
    // Revocation remains checked through use, including a recorded retirement
    // request that precedes the asynchronously returned terminal observation.
    if (other.reason !== null) {
      const terminal = event.retirementRequestedAt ?? event.observedAt;
      check(time(terminal) && terminal > usedAt, 'native ownership retired before use');
    }
    if (n > accepted) before(other.lastAcceptedAt);
    if (other.leaseDeadline > sample.leaseDeadline) before(other.leaseDeadline - 0.3);
    if (n > accepted || other.leaseDeadline > sample.leaseDeadline) before(event.observedAt);
  }
  check(
    lower < upper || (lower === upper && !exclusive),
    'no common snapshot instant inside read interval',
  );
  return { earliestSnapshotAt: lower, latestSnapshotAt: upper, latestExclusive: exclusive };
}
