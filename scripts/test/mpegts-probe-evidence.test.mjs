import test from 'node:test';
import assert from 'node:assert/strict';
import { qualifyMPEGTSProbe } from '../mpegts-probe-evidence.mjs';

function fixture(scenario = 'baseline') {
  const packet = Buffer.alloc(188, 0xff);
  packet.set([0x47, 1, 0, 0x10]);
  const nullPacket = Buffer.from(packet);
  nullPacket.set([0x47, 0x1f, 0xff, 0x10]);
  const source = Buffer.concat([packet, nullPacket, ...Array(3000).fill(packet)]);
  const probe =
    scenario === 'baseline' ? Buffer.alloc(0) : Buffer.concat(Array(7).fill(nullPacket));
  const accepted = Buffer.concat([source, probe]);
  const senderRows = [];
  if (probe.length) {
    senderRows.push({
      kind: 'probe-start',
      at: 1,
      rateBps: 1_000_000,
      deadline: 1.3,
      retransmittedBytes: 10,
      droppedPackets: 2,
      sourceBytes: 0,
      transportBytes: 0,
      probeBytes: 0,
    });
    for (const at of [1.2, 1.4, 1.6, 1.8])
      senderRows.push({ kind: 'lease', at, deadline: at + 0.3, renewed: true });
    senderRows.push({
      kind: 'withdrawn',
      at: scenario === 'pressure' ? 2.05 : 2.101,
      reason: scenario === 'pressure' ? 'transport-pressure' : 'lease-expired',
      deadline: 2.1,
      lastAcceptedAt: 2.04,
      statisticsAt: 2.04,
      rttMs: scenario === 'pressure' ? 52 : 2,
      bufferMs: 0,
      retransmittedBytes: 10,
      droppedPackets: 2,
      transportBytes: 188 + probe.length,
      sourceBytes: 188,
      probeBytes: probe.length,
    });
  }
  senderRows.push({
    kind: 'sample',
    at: 3,
    sourceBytes: source.length,
    transportBytes: accepted.length,
    probeBytes: probe.length,
  });
  senderRows.push({
    kind: 'finished',
    at: 4,
    requestedStop: true,
    sourceBytes: source.length,
    transportBytes: accepted.length,
    probeBytes: probe.length,
  });
  const receiverRows = [
    { kind: 'finished', at: 4, requestedStop: true, transportBytes: accepted.length },
  ];
  return { source, accepted, received: Buffer.from(accepted), senderRows, receiverRows, scenario };
}
test('qualifies exact media/transport delivery and does not count source null packets as probes', () => {
  const result = qualifyMPEGTSProbe(fixture('lease'));
  assert.equal(result.probePackets, 7);
  assert.equal(result.sourceNullPackets, 1);
  assert.equal(result.receivedNullPackets, 8);
});
test('baseline must contain no probe', () => {
  assert.equal(qualifyMPEGTSProbe(fixture()).probePackets, 0);
  const value = fixture('lease');
  value.scenario = 'baseline';
  assert.throws(() => qualifyMPEGTSProbe(value));
});
for (const [name, mutate] of [
  [
    'missing received packet',
    (v) => {
      v.received = v.received.subarray(188);
    },
  ],
  [
    'media corruption in both saved streams',
    (v) => {
      v.accepted[5] ^= 1;
      v.received[5] ^= 1;
    },
  ],
  [
    'incorrect source null attribution',
    (v) => {
      v.senderRows.at(-1).probeBytes += 188;
    },
  ],
  [
    'padding accepted after withdrawal',
    (v) => {
      v.senderRows.find((r) => r.kind === 'withdrawn').probeBytes = 0;
    },
  ],
  [
    'media stopped at withdrawal',
    (v) => {
      v.senderRows.find((r) => r.kind === 'withdrawn').sourceBytes = v.source.length;
    },
  ],
  [
    'unexpected withdrawal',
    (v) => {
      v.senderRows.find((r) => r.kind === 'withdrawn').reason = 'invalid-time';
    },
  ],
  [
    'no terminal sender join marker',
    (v) => {
      v.senderRows.pop();
    },
  ],
  [
    'unsolicited receiver exit',
    (v) => {
      v.receiverRows[0].requestedStop = false;
    },
  ],
  [
    'reversed native samples',
    (v) => {
      v.senderRows.find((r) => r.kind === 'sample').at = 0;
    },
  ],
])
  test(`rejects ${name}`, () => {
    const value = fixture('lease');
    mutate(value);
    assert.throws(() => qualifyMPEGTSProbe(value));
  });

test('qualifies a fresh measured pressure withdrawal', () => {
  assert.equal(qualifyMPEGTSProbe(fixture('pressure')).withdrawal.rttMs, 52);
});
for (const [name, scenario, mutate] of [
  [
    'negative withdrawal source bytes',
    'lease',
    (w) => {
      w.sourceBytes = -1;
    },
  ],
  [
    'missing pressure observation',
    'pressure',
    (w) => {
      delete w.rttMs;
    },
  ],
  [
    'healthy pressure reason',
    'pressure',
    (w) => {
      w.rttMs = 2;
    },
  ],
  [
    'future pressure observation',
    'pressure',
    (w) => {
      w.statisticsAt = 2.06;
    },
  ],
  [
    'stale pressure observation',
    'pressure',
    (w) => {
      w.statisticsAt = 1.94;
    },
  ],
  [
    'counter reset',
    'pressure',
    (w) => {
      w.retransmittedBytes = 0;
    },
  ],
  [
    'invented lease deadline',
    'lease',
    (w) => {
      w.deadline = 2.099;
    },
  ],
  [
    'early lease withdrawal',
    'lease',
    (w) => {
      w.at = 2.09;
    },
  ],
  [
    'late lease withdrawal',
    'lease',
    (w) => {
      w.at = 2.2;
    },
  ],
  [
    'padding after lease deadline',
    'lease',
    (w) => {
      w.lastAcceptedAt = 2.101;
    },
  ],
])
  test(`rejects ${name}`, () => {
    const value = fixture(scenario);
    mutate(value.senderRows.find((r) => r.kind === 'withdrawn'));
    assert.throws(() => qualifyMPEGTSProbe(value));
  });
test('rejects missed lease renewals and unsupported rates', () => {
  const missed = fixture('lease');
  missed.senderRows = missed.senderRows.filter((r) => r.kind !== 'lease');
  assert.throws(() => qualifyMPEGTSProbe(missed));
  const rate = fixture('lease');
  rate.senderRows[0].rateBps = 2_000_001;
  assert.throws(() => qualifyMPEGTSProbe(rate));
});
