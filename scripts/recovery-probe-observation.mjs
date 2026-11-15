import assert from 'node:assert/strict';

const check = (value, message) => assert.ok(value, `Recovery probe observation: ${message}`);
const time = (value) =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12;
const int32 = (value) => Number.isInteger(value) && value >= 0 && value <= 2147483647;
const fields = [
  'checkedAt',
  'sampledAt',
  'elapsedMilliseconds',
  'sentBytes',
  'retransmittedBytes',
  'droppedPackets',
  'rttMilliseconds',
  'senderBufferMilliseconds',
  'senderDeliveryDelayMilliseconds',
].sort();
function counter(value, maximum = 18446744073709551615n) {
  check(typeof value === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(value), 'noncanonical counter');
  const parsed = BigInt(value);
  check(parsed <= maximum, 'counter overflow');
  return parsed;
}

/** Exact last successful native-send preflight, not receiver delivery or capacity.
 * checkedAt is historical: reading a snapshot later must not freshen its sample. */
export function assertRecoveryProbeObservation(
  sample,
  { observedAt, policy = 'local-zero-loss-v1' } = {},
) {
  check(['local-zero-loss-v1', 'recovery-budget-v1'].includes(policy), 'unknown policy');
  check(sample && typeof sample === 'object' && !Array.isArray(sample), 'missing sample');
  if (policy === 'local-zero-loss-v1') {
    check(
      !Object.hasOwn(sample, 'policy') && !Object.hasOwn(sample, 'recoveryObservation'),
      'legacy evidence contains recovery metadata',
    );
    return;
  }
  check(sample.policy === policy, 'wrong policy');
  check(
    Number.isInteger(sample.stage) && sample.stage >= 1 && sample.stage <= 32,
    'recovery requires a staged owner',
  );
  const r = sample.recoveryObservation;
  check(r && typeof r === 'object' && !Array.isArray(r), 'missing raw observation');
  assert.deepEqual(
    Object.keys(r).sort(),
    fields,
    'Recovery probe observation: unexpected raw fields',
  );
  check([sample.startedAt, observedAt, r.checkedAt, r.sampledAt].every(time), 'invalid clock');
  check(
    sample.startedAt <= r.checkedAt && r.checkedAt <= observedAt,
    'check outside owner lifetime or in future',
  );
  check(
    r.sampledAt <= r.checkedAt && r.checkedAt - r.sampledAt <= 0.1,
    'future or stale native collection',
  );
  counter(r.elapsedMilliseconds, 9223372036854775807n);
  check(counter(r.retransmittedBytes) <= counter(r.sentBytes), 'retransmissions exceed sent bytes');
  check(
    int32(r.droppedPackets) &&
      int32(r.senderBufferMilliseconds) &&
      int32(r.senderDeliveryDelayMilliseconds) &&
      r.senderDeliveryDelayMilliseconds > 0,
    'invalid transport counters or delay',
  );
  check(
    typeof r.rttMilliseconds === 'number' &&
      Number.isFinite(r.rttMilliseconds) &&
      r.rttMilliseconds >= 0 &&
      r.rttMilliseconds <= Math.min(500, r.senderDeliveryDelayMilliseconds / 4),
    'RTT exceeds recovery budget',
  );
  check(
    r.senderBufferMilliseconds <= Math.min(500, r.senderDeliveryDelayMilliseconds / 2),
    'sender backlog exceeds recovery reserve',
  );
}

/** Validate bounded raw checks per owner, sorted by native check time rather than
 * asynchronous read completion. A new owner establishes its own drop baseline. */
export function assertRecoveryProbeHistory(entries, { policy = 'local-zero-loss-v1' } = {}) {
  check(
    Array.isArray(entries) && entries.length > 0 && entries.length <= 4096,
    'missing or excessive history',
  );
  for (const e of entries) {
    check(e && typeof e === 'object', 'invalid entry');
    assertRecoveryProbeObservation(e.sample, { observedAt: e.observedAt, policy });
  }
  if (policy === 'local-zero-loss-v1') return;
  const owners = new Map();
  for (const { sample } of entries) {
    check(
      typeof sample.id === 'string' &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(sample.id),
      'invalid owner',
    );
    check(counter(sample.publishingGeneration) > 0n, 'invalid generation');
    const key = sample.id.toLowerCase(),
      group = owners.get(key) ?? [];
    if (group.length) {
      const first = group[0];
      check(
        sample.publishingGeneration === first.publishingGeneration &&
          sample.stage === first.stage &&
          sample.startedAt === first.startedAt,
        'owner identity changed',
      );
    }
    group.push(sample);
    owners.set(key, group);
  }
  for (const samples of owners.values()) {
    samples.sort((a, b) => a.recoveryObservation.checkedAt - b.recoveryObservation.checkedAt);
    let prior;
    for (const sample of samples) {
      const current = sample.recoveryObservation;
      if (prior) {
        if (current.checkedAt === prior.checkedAt)
          assert.deepEqual(current, prior, 'Recovery probe observation: changed check');
        check(current.sampledAt >= prior.sampledAt, 'collection clock regressed');
        if (current.sampledAt === prior.sampledAt)
          for (const field of fields.filter((f) => f !== 'checkedAt'))
            assert.equal(
              current[field],
              prior[field],
              `Recovery probe observation: cached ${field} changed`,
            );
        for (const field of ['elapsedMilliseconds', 'sentBytes', 'retransmittedBytes'])
          check(BigInt(current[field]) >= BigInt(prior[field]), `${field} regressed`);
        check(current.droppedPackets === prior.droppedPackets, 'sender drops changed within owner');
        check(
          BigInt(current.retransmittedBytes) - BigInt(prior.retransmittedBytes) <=
            BigInt(current.sentBytes) - BigInt(prior.sentBytes),
          'retransmission delta exceeds sent delta',
        );
      }
      prior = current;
    }
  }
}

/** Join successful active/cancelled snapshots to actual accepted traffic, including
 * overlapping asynchronous reads. Other terminal reasons require a separate gate. */
export function assertRecoveryProbeAcceptanceHistory(
  entries,
  { policy = 'local-zero-loss-v1' } = {},
) {
  assertRecoveryProbeHistory(entries, { policy });
  if (policy === 'local-zero-loss-v1') return;
  const owners = new Map();
  for (const { sample, observedAt } of entries) {
    const accepted = counter(sample.acceptedPayloadBytes, 16777216n);
    check(accepted % 1316n === 0n, 'unaligned acceptance');
    check(
      sample.reason === null || sample.reason === 'cancelled',
      'unsupported acceptance terminal reason',
    );
    check(
      Number.isSafeInteger(sample.bitRate) && sample.bitRate > 0 && sample.bitRate <= 12000000,
      'invalid offered rate',
    );
    const raw = sample.recoveryObservation;
    if (accepted === 0n)
      check(
        sample.lastAcceptedAt === null && raw.checkedAt === sample.startedAt,
        'empty stage must retain admission check',
      );
    else {
      check(
        time(sample.lastAcceptedAt) &&
          raw.checkedAt <= sample.lastAcceptedAt &&
          sample.lastAcceptedAt <= observedAt,
        'preflight or acceptance clock out of order',
      );
      check(
        Number(accepted / 1316n) * 10880 <= (raw.checkedAt - sample.startedAt) * sample.bitRate + 1,
        'preflight has insufficient total pacing credit',
      );
    }
    const key = sample.id.toLowerCase(),
      group = owners.get(key) ?? [];
    group.push({ sample, accepted });
    owners.set(key, group);
  }
  for (const group of owners.values()) {
    group.sort((a, b) => Number(a.accepted - b.accepted));
    let prior;
    for (const current of group) {
      const sample = current.sample,
        raw = sample.recoveryObservation;
      if (prior) {
        check(sample.bitRate === prior.sample.bitRate, 'offered rate changed within owner');
        if (current.accepted === prior.accepted) {
          check(
            sample.lastAcceptedAt === prior.sample.lastAcceptedAt,
            'unchanged acceptance time changed',
          );
          assert.deepEqual(
            raw,
            prior.sample.recoveryObservation,
            'Recovery probe observation: check changed without acceptance',
          );
        } else
          check(
            raw.checkedAt > prior.sample.recoveryObservation.checkedAt &&
              raw.checkedAt >= (prior.sample.lastAcceptedAt ?? prior.sample.startedAt),
            'new acceptance requires later preflight after prior completion',
          );
      }
      prior = current;
    }
  }
}
