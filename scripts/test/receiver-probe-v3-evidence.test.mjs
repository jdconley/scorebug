import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  assertReceiverProbeProgress,
  qualifyReceiverProbeEvidence,
  validateReceiverProbeSnapshot,
} from '../receiver-probe-evidence.mjs';
import { stagedProbeEvidence } from './fixtures/staged-probe-evidence.mjs';

const cap = 16n * 1024n * 1024n;
const golden = (version = 3) =>
  JSON.parse(
    readFileSync(
      new URL(
        `../../packages/protocol/fixtures/receiver-probe-status-v${version}.json`,
        import.meta.url,
      ),
      'utf8',
    ),
  ).status.receiverProbe.snapshot;
const id = (n) => `60000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
function sample({
  campaign = 2,
  stage = 2,
  messages = 2,
  campaignMessages = 5,
  totalMessages = 15,
  pending = 0,
  at = 2,
  first = 1,
  identity = 2,
} = {}) {
  return {
    convention: 'mpegts-null-probe-v3',
    id: id(identity),
    publishingGeneration: '7',
    bitRate: 12000000,
    campaign: String(campaign),
    stage,
    deliveredMessages: String(messages),
    deliveredPayloadBytes: String(messages * 1316),
    nextSequence: String(messages),
    campaignDeliveredPayloadBytes: String(campaignMessages * 1316),
    totalDeliveredPayloadBytes: String(totalMessages * 1316),
    pendingPackets: pending,
    observedAtNanoseconds: String(at * 1e9),
    ...(messages
      ? {
          firstDeliveredAtNanoseconds: String(first * 1e9),
          lastDeliveredAtNanoseconds: String((messages === 1 ? first : at - 0.1) * 1e9),
        }
      : {}),
  };
}
function progress(previous, current) {
  validateReceiverProbeSnapshot(previous);
  validateReceiverProbeSnapshot(current);
  assertReceiverProbeProgress(current, previous);
}
const sameStage = () => [
  sample(),
  sample({ messages: 4, campaignMessages: 7, totalMessages: 17, at: 3 }),
];
const nextStage = () => [
  sample({ pending: 2 }),
  sample({
    stage: 3,
    messages: 1,
    campaignMessages: 7,
    totalMessages: 17,
    at: 3,
    first: 2.5,
    identity: 3,
  }),
];
const nextCampaign = () => [
  sample({ pending: 2 }),
  sample({
    campaign: 3,
    stage: 1,
    messages: 1,
    campaignMessages: 1,
    totalMessages: 17,
    at: 3,
    first: 2.5,
    identity: 3,
  }),
];

test('raw v3 retains the wire campaign and publication totals above 16 MiB', () => {
  assert.deepEqual(validateReceiverProbeSnapshot(golden()), golden());
});
test('raw v3 preserves exact maximum UInt32 identity and publication totals beyond Number safety', () => {
  const p = {
    ...golden(),
    campaign: '4294967295',
    pendingPackets: 0,
    totalDeliveredPayloadBytes: (((4294967294n * cap + 5264n) / 1316n) * 1316n).toString(),
  };
  assert.ok(BigInt(p.totalDeliveredPayloadBytes) > BigInt(Number.MAX_SAFE_INTEGER));
  assert.deepEqual(validateReceiverProbeSnapshot(p), p);
});
test('v3 zero-message restart omits delivery timestamps and can reserve its first message', () => {
  const p = sample({ stage: 1, messages: 0, campaignMessages: 0, totalMessages: 10, pending: 1 });
  assert.deepEqual(validateReceiverProbeSnapshot(p), p);
});
for (const [field, values] of Object.entries({
  campaign: [undefined, null, 2, '0', '02', '+2', '2\n', '4294967296'],
  campaignDeliveredPayloadBytes: [undefined, null, '05264', '5265', '1316', '16777684', '16776368'],
  totalDeliveredPayloadBytes: [undefined, '2632', '16781633', '33555000', '72057594021150721'],
  stage: [undefined, 0, 33, '1'],
  bitRate: [0, 12000001],
  invalidReason: ['scope'],
}))
  for (const value of values)
    test(`v3 rejects ${field}=${JSON.stringify(value)}`, () => {
      assert.throws(() => validateReceiverProbeSnapshot({ ...golden(), [field]: value }));
    });
test('v3 stage one has no earlier stage carry and campaign one has no earlier campaign carry', () => {
  assert.throws(() => validateReceiverProbeSnapshot({ ...golden(), stage: 1 }));
  assert.throws(() => validateReceiverProbeSnapshot({ ...golden(), campaign: '1' }));
  const p = sample({ campaign: 1, stage: 1, messages: 2, campaignMessages: 2, totalMessages: 2 });
  assert.deepEqual(validateReceiverProbeSnapshot(p), p);
});
test('v3 pending reservations consume a full campaign message without imposing the v2 publication cap', () => {
  const p = {
    ...golden(),
    campaignDeliveredPayloadBytes: '16776368',
    totalDeliveredPayloadBytes: '33552736',
    pendingPackets: 0,
  };
  assert.deepEqual(validateReceiverProbeSnapshot(p), p);
  assert.throws(() => validateReceiverProbeSnapshot({ ...p, pendingPackets: 1 }));
});
for (const version of [1, 2])
  test(`v${version} rejects campaign fields instead of silently stripping them`, () => {
    assert.deepEqual(validateReceiverProbeSnapshot(golden(version)), golden(version));
    for (const extra of [
      { campaign: '1' },
      { campaign: null },
      { campaignDeliveredPayloadBytes: '0' },
      { campaignDeliveredPayloadBytes: null },
    ])
      assert.throws(() => validateReceiverProbeSnapshot({ ...golden(version), ...extra }));
  });

test('v3 same-stage deltas retain both campaign and publication bases', () => {
  progress(...sameStage());
  const p = sample();
  progress(p, structuredClone(p));
  progress(p, { ...p, observedAtNanoseconds: '3000000000', pendingPackets: 6 });
});
for (const [name, mutate] of Object.entries({
  id: (p) => {
    p.id = id(9);
  },
  generation: (p) => {
    p.publishingGeneration = '8';
  },
  rate: (p) => {
    p.bitRate = 1000000;
  },
  campaignBase: (p) => {
    p.campaignDeliveredPayloadBytes = String(8 * 1316);
  },
  publicationBase: (p) => {
    p.totalDeliveredPayloadBytes = String(18 * 1316);
  },
  bothBases: (p) => {
    p.campaignDeliveredPayloadBytes = String(8 * 1316);
    p.totalDeliveredPayloadBytes = String(18 * 1316);
  },
  firstChanges: (p) => {
    p.firstDeliveredAtNanoseconds = '1100000000';
  },
  staleDelivery: (p) => {
    p.lastDeliveredAtNanoseconds = '1900000000';
  },
  sameInstant: (p) => {
    p.observedAtNanoseconds = '2000000000';
    p.lastDeliveredAtNanoseconds = '2000000000';
  },
}))
  test(`v3 same-stage rejects ${name}`, () => {
    const [previous, current] = sameStage();
    mutate(current);
    assert.throws(() => progress(previous, current));
  });
test('v3 same-stage pending packets cannot disappear or delivery counters reset', () => {
  const previous = sample({ pending: 5 });
  assert.throws(() =>
    progress(previous, { ...previous, pendingPackets: 4, observedAtNanoseconds: '3000000000' }),
  );
  assert.throws(() =>
    progress(previous, sample({ messages: 1, campaignMessages: 4, totalMessages: 14, at: 3 })),
  );
});
test('v3 unchanged delivery timestamps remain exact and first completion follows observation', () => {
  const previous = sample();
  assert.throws(() =>
    progress(previous, {
      ...previous,
      observedAtNanoseconds: '3000000000',
      lastDeliveredAtNanoseconds: '2100000000',
    }),
  );
  const empty = sample({ messages: 0, campaignMessages: 3, totalMessages: 13, pending: 2 });
  progress(
    empty,
    sample({ messages: 1, campaignMessages: 4, totalMessages: 14, at: 3, first: 2.5 }),
  );
  assert.throws(() =>
    progress(
      empty,
      sample({ messages: 1, campaignMessages: 4, totalMessages: 14, at: 3, first: 1.5 }),
    ),
  );
});
for (const [kind, fixture] of [
  ['stage', nextStage],
  ['campaign', nextCampaign],
]) {
  test(`v3 ${kind} boundary resets local counters while retaining publication history`, () =>
    progress(...fixture()));
  for (const [name, mutate] of Object.entries({
    reusedIdentity: (p) => {
      p.id = id(2);
    },
    changedGeneration: (p) => {
      p.publishingGeneration = '8';
    },
    regressedClock: (p) => {
      p.observedAtNanoseconds = '1900000000';
      p.firstDeliveredAtNanoseconds = p.lastDeliveredAtNanoseconds = '1800000000';
    },
    oldFirstDelivery: (p) => {
      p.firstDeliveredAtNanoseconds = p.lastDeliveredAtNanoseconds = '1900000000';
    },
    sameInstant: (p) => {
      p.observedAtNanoseconds =
        p.firstDeliveredAtNanoseconds =
        p.lastDeliveredAtNanoseconds =
          '2000000000';
    },
    lostPriorPending: (p) => {
      p.totalDeliveredPayloadBytes = String(16 * 1316);
      if (kind === 'stage') p.campaignDeliveredPayloadBytes = String(6 * 1316);
    },
    publicationReset: (p) => {
      p.totalDeliveredPayloadBytes = p.campaignDeliveredPayloadBytes;
    },
  }))
    test(`v3 ${kind} boundary rejects ${name}`, () => {
      const [previous, current] = fixture();
      mutate(current);
      assert.throws(() => progress(previous, current));
    });
}
test('v3 same-campaign stage ordering is forward and its publication delta equals campaign delta', () => {
  const [previous, current] = nextStage();
  assert.throws(() =>
    progress(previous, {
      ...current,
      stage: 1,
      campaignDeliveredPayloadBytes: current.deliveredPayloadBytes,
    }),
  );
  assert.throws(() =>
    progress(previous, { ...current, totalDeliveredPayloadBytes: String(18 * 1316) }),
  );
});
test('v3 campaign regression is rejected even when stage increases', () => {
  const [previous, current] = nextCampaign();
  assert.throws(() =>
    progress(previous, {
      ...current,
      campaign: '1',
      stage: 3,
      campaignDeliveredPayloadBytes: current.totalDeliveredPayloadBytes,
    }),
  );
});
test('v3 permits missed final polls, skipped ordinals and later snapshots of a new campaign', () => {
  progress(
    sample({ pending: 1 }),
    sample({
      stage: 5,
      messages: 2,
      campaignMessages: 10,
      totalMessages: 20,
      at: 3,
      first: 2,
      identity: 5,
    }),
  );
  progress(
    sample({ pending: 1 }),
    sample({
      campaign: 4,
      stage: 5,
      messages: 2,
      campaignMessages: 10,
      totalMessages: 30,
      at: 3,
      first: 2,
      identity: 5,
    }),
  );
});
test('v3 new campaign accounts for its full campaign counter, including missed earlier stages', () => {
  const previous = sample({ pending: 1 });
  const current = sample({
    campaign: 3,
    stage: 3,
    messages: 1,
    campaignMessages: 5,
    totalMessages: 21,
    at: 3,
    first: 2.5,
    identity: 3,
  });
  progress(previous, current);
  assert.throws(() =>
    progress(previous, { ...current, totalDeliveredPayloadBytes: String(20 * 1316) }),
  );
});
test('v3 new campaign cannot invent more unpolled prior bytes than the intervening campaign caps', () => {
  const previous = sample();
  const current = sample({
    campaign: 3,
    stage: 1,
    messages: 1,
    campaignMessages: 1,
    totalMessages: 17,
    at: 3,
    first: 2.5,
    identity: 3,
  });
  current.totalDeliveredPayloadBytes = String(((cap + 10n * 1316n) / 1316n + 2n) * 1316n);
  validateReceiverProbeSnapshot(current); // Globally bounded, but impossible given prior campaign carry.
  assert.throws(() => progress(previous, current));
});
test('v3 historical UUID reuse is legal after an intervening identity, as on the relay', () => {
  const first = sample();
  const middle = sample({
    stage: 3,
    messages: 1,
    campaignMessages: 6,
    totalMessages: 16,
    at: 3,
    first: 2.5,
    identity: 3,
  });
  const last = sample({
    campaign: 3,
    stage: 1,
    messages: 1,
    campaignMessages: 1,
    totalMessages: 17,
    at: 4,
    first: 3.5,
    identity: 2,
  });
  progress(first, middle);
  progress(middle, last);
});
test('legacy qualification stays closed to v3 even after raw snapshots validate', () => {
  const f = stagedProbeEvidence();
  for (const record of f.records)
    Object.assign(record.probe, {
      convention: 'mpegts-null-probe-v3',
      campaign: '1',
      campaignDeliveredPayloadBytes: record.probe.totalDeliveredPayloadBytes,
    });
  for (const record of f.records) validateReceiverProbeSnapshot(record.probe);
  assert.throws(() => qualifyReceiverProbeEvidence(f.records, f.scope, f.accepted));
});
