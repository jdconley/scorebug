import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import test from 'node:test';
import { qualifyOwnedNativeProbes } from '../owned-native-probes.mjs';
const implementation = await import('../owned-receiver-probe-evidence.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
function fixture(name = 'LvDNAy') {
  const provenance = JSON.parse(
    readFileSync(new URL(`./fixtures/owned-receiver-${name}.provenance.json`, import.meta.url)),
  );
  const read = (entry) => {
    const bytes = gunzipSync(readFileSync(new URL(`../../${entry.fixture}`, import.meta.url)));
    assert.equal(bytes.length, entry.bytes);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), entry.sha256);
    return JSON.parse(bytes);
  };
  return {
    records: read(provenance.receiver),
    raw: read(provenance.native),
    options: provenance.options,
  };
}
function qualify(f) {
  assert.equal(
    typeof implementation.qualifyOwnedReceiverProbeEvidence,
    'function',
    'owned receiver replay must exist',
  );
  return implementation.qualifyOwnedReceiverProbeEvidence(f.records, f.raw, f.options);
}
for (const [name, count, bytes, stageCounts] of [
  ['LvDNAy', 540, 14940548, [3, 2, 2, 3]],
  ['mAluZi', 514, 14507584, [3, 1, 1, 3]],
])
  test(`reconciles full original ${name} history including failed campaigns`, () => {
    const f = fixture(name),
      before = structuredClone(f),
      result = qualify(f);
    assert.deepEqual(f, before);
    assert.equal(result.mode, 'owned');
    assert.equal(result.eventCount, count);
    assert.equal(result.campaignCount, 4);
    assert.equal(
      result.stageCount,
      stageCounts.reduce((a, b) => a + b),
    );
    assert.equal(result.observationCount, 551);
    assert.equal(result.deliveredPayloadBytes, bytes);
    assert.equal(result.deliveredMessages, bytes / 1316);
    assert.equal(result.publicationId, f.records[0].publication.publicationId);
    assert.equal(result.publishingGeneration, '1');
    assert.deepEqual(result.scope, f.options.scope);
    assert.equal(result.receiverConservationQualified, true);
    for (const flag of [
      'receiverCapacityQualified',
      'candidateAdmissionQualified',
      'retryPolicyQualified',
      'mediaQualified',
      'recoveryQualified',
    ])
      assert.equal(result[flag], false, flag);
    const native = qualifyOwnedNativeProbes(f.raw, f.options);
    assert.deepEqual(
      result.attempts.map((a) => a.stages.length),
      stageCounts,
    );
    assert.deepEqual(
      result.attempts.map((a) => a.terminal),
      ['settledAcknowledged', 'settledFailure', 'settledFailure', 'settledAcknowledged'],
    );
    let total = 0;
    for (const [i, attempt] of result.attempts.entries()) {
      const original = native.attempts[i];
      assert.equal(attempt.attemptIndex, i);
      for (const key of [
        'ownerID',
        'appliedRevision',
        'campaign',
        'eventIndices',
        'registeredEventIndex',
        'cleanupEventIndex',
        'settlementEventIndex',
        'binding',
      ])
        assert.deepEqual(attempt[key], original[key], key);
      let campaign = 0;
      for (const [j, stage] of attempt.stages.entries()) {
        for (const [key, value] of Object.entries(original.stages[j]))
          assert.deepEqual(stage[key], value, key);
        assert.equal(stage.attemptIndex, i);
        assert.equal(stage.campaign, attempt.campaign);
        assert.equal(stage.publishingGeneration, '1');
        assert.equal(stage.deliveredPayloadBytes, stage.acceptedPayloadBytes);
        assert.equal(stage.deliveredMessages, stage.acceptedPayloadBytes / 1316);
        campaign += stage.acceptedPayloadBytes;
        assert.equal(stage.campaignDeliveredPayloadBytes, campaign);
        assert.equal(stage.totalDeliveredPayloadBytes, total + campaign);
        const indices = f.records.flatMap((r, k) => (r.probe.id === stage.id ? [k] : []));
        assert.deepEqual(stage.receiverRecordIndices, indices);
        assert.equal(stage.observationCount, indices.length);
        assert.ok(indices.length > 0);
      }
      total += campaign;
      assert.equal(attempt.deliveredPayloadBytes, campaign);
    }
    const lower = Math.max(
      ...f.records.map(
        (r) => r.request.startedAtMilliseconds - Number(r.probe.observedAtNanoseconds) / 1e6,
      ),
    );
    const upper = Math.min(
      ...f.records.map(
        (r) => r.request.receivedAtMilliseconds - Number(r.probe.observedAtNanoseconds) / 1e6,
      ),
    );
    assert.deepEqual(result.clockOffsetBoundMilliseconds, [lower, upper]);
    assert.ok(lower <= upper);
  });
const failed = (f) => f.records.findIndex((r) => r.probe.campaign === '2');
const bump = (p, key, n = 1316) => {
  p[key] = String(BigInt(p[key]) + BigInt(n));
};
const mutations = {
  'foreign stage identity': (f) => {
    f.records[failed(f)].probe.id = f.records[0].probe.id;
  },
  'foreign campaign': (f) => {
    f.records[failed(f)].probe.campaign = '9';
  },
  'foreign stage rate': (f) => {
    f.records[failed(f)].probe.bitRate = 12000000;
  },
  'foreign native generation': (f) => {
    f.records[failed(f)].probe.publishingGeneration = '2';
  },
  'foreign scope': (f) => {
    f.options.scope.matchID = 'foreign';
  },
  'foreign native scope': (f) => {
    f.raw.scope.recordingID = 'foreign';
  },
  'foreign publication': (f) => {
    f.records[failed(f)].publication.publicationId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
  },
  'missing publication': (f) => {
    for (const r of f.records) delete r.publication.publicationId;
  },
  'missing authenticated path': (f) => {
    for (const r of f.records) delete r.publication.path;
  },
  'changed authenticated path': (f) => {
    f.records[failed(f)].publication.path = f.records[0].publication.path.replace(/.$/, '0');
  },
  'foreign attempt': (f) => {
    f.records[failed(f)].publication.publishingAttemptId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
  },
  'foreign recording': (f) => {
    f.records[failed(f)].publication.recordingId = 'foreign';
  },
  'foreign game': (f) => {
    f.records[failed(f)].publication.gameId = 'foreign';
  },
  'foreign broadcast': (f) => {
    f.records[failed(f)].publication.generation = 2;
  },
  'missing failed campaign': (f) => {
    f.records = f.records.filter((r) => r.probe.campaign !== '2');
  },
  'missing failed stage': (f) => {
    f.records = f.records.filter((r) => !(r.probe.campaign === '2' && r.probe.stage === 2));
  },
  'missing first stage': (f) => {
    f.records = f.records.filter((r) => !(r.probe.campaign === '1' && r.probe.stage === 1));
  },
  'missing final stage': (f) => {
    f.records = f.records.filter((r) => !(r.probe.campaign === '4' && r.probe.stage === 3));
  },
  'reordered failed campaign': (f) => {
    f.records = [
      ...f.records.filter((r) => r.probe.campaign === '2'),
      ...f.records.filter((r) => r.probe.campaign !== '2'),
    ];
  },
  'reordered failed stage': (f) => {
    const i = failed(f);
    [f.records[i], f.records[i + 1]] = [f.records[i + 1], f.records[i]];
  },
  'receiver campaign counter reset': (f) => {
    const p = f.records.find((r) => r.probe.campaign === '2' && r.probe.stage === 2).probe;
    p.campaignDeliveredPayloadBytes = p.deliveredPayloadBytes;
  },
  'receiver publication counter reset': (f) => {
    for (const r of f.records.filter((r) => r.probe.campaign === '2'))
      r.probe.totalDeliveredPayloadBytes = r.probe.campaignDeliveredPayloadBytes;
  },
  'inflated campaign carry': (f) => {
    bump(f.records[failed(f) + 1].probe, 'campaignDeliveredPayloadBytes');
  },
  'inflated publication carry': (f) => {
    bump(f.records[failed(f) + 1].probe, 'totalDeliveredPayloadBytes');
  },
  'pending exceeds accepted': (f) => {
    f.records[failed(f) + 2].probe.pendingPackets = 1;
  },
  'inflated delivered bytes': (f) => {
    const p = f.records.at(-1).probe;
    for (const key of [
      'deliveredPayloadBytes',
      'campaignDeliveredPayloadBytes',
      'totalDeliveredPayloadBytes',
    ])
      bump(p, key);
    for (const key of ['deliveredMessages', 'nextSequence']) bump(p, key, 1);
  },
  'terminal pending': (f) => {
    f.records.at(-1).probe.pendingPackets = 1;
  },
  'terminal underdelivery': (f) => {
    // Retain every original stage but stop at a genuine partial final-stage poll.
    const i = f.records.findIndex((r) => r.probe.campaign === '4' && r.probe.stage === 3);
    f.records = f.records.slice(0, i + 1);
  },
  'clock rebase between campaigns': (f) => {
    for (const r of f.records.slice(failed(f))) {
      r.request.startedAtMilliseconds += 1000;
      r.request.receivedAtMilliseconds += 1000;
    }
  },
  'overlapping requests': (f) => {
    f.records[1].request.startedAtMilliseconds = f.records[0].request.startedAtMilliseconds;
  },
  'unbounded request': (f) => {
    f.records[1].request.receivedAtMilliseconds += 2000;
  },
  'nonfinite request': (f) => {
    f.records[1].request.startedAtMilliseconds = NaN;
  },
  'receiver counter beyond integer bound': (f) => {
    f.records[1].probe.totalDeliveredPayloadBytes = '18446744073709551616';
  },
  'empty receiver history': (f) => {
    f.records = [];
  },
  'oversized receiver history': (f) => {
    f.records = Array(2049).fill(f.records[0]);
  },
  'invalid receiver proof': (f) => {
    f.records[1].probe.invalidReason = 'invalid';
  },
  'receiver counter noncanonical': (f) => {
    f.records[1].probe.deliveredMessages = '035';
  },
  'native invalid acceptance': (f) => {
    f.raw.events.find((e) => e.kind === 'renewed').snapshot.acceptedPayloadBytes = '1317';
  },
  'native original event omitted': (f) => {
    f.raw.events.splice(10, 1);
  },
  'native summarized envelope': (f) => {
    f.raw = qualifyOwnedNativeProbes(f.raw, f.options);
  },
  'native unclosed': (f) => {
    f.raw.isClosed = false;
  },
  'unknown option': (f) => {
    f.options.allowMissingStages = true;
  },
  'symbol option': (f) => {
    f.options[Symbol('bypass')] = true;
  },
  'wrong timing profile': (f) => {
    f.options.timingProfile = 'strict1500-v1';
  },
  'evidence-selected timing profile': (f) => {
    delete f.options.timingProfile;
  },
  'unknown timing profile': (f) => {
    f.options.timingProfile = 'foreign';
  },
  'null options': (f) => {
    f.options = null;
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    assert.equal(typeof implementation.qualifyOwnedReceiverProbeEvidence, 'function');
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });
test('reports an unobserved zero-acceptance stage as unsupported conservation', () => {
  const f = fixture();
  const empty = f.raw.events.find(
    (e) => e.kind === 'allocated' && e.snapshot.campaign === '2' && e.snapshot.stage === 2,
  ).snapshot;
  // Mutation of the original failed allocation: no receiver record is fabricated.
  // Native replay must still pass before the independent receiver join rejects it.
  const removed = 30268;
  for (const e of f.raw.events)
    for (const key of ['snapshot', 'predecessor']) {
      const s = e[key];
      if (s?.id === empty.id) {
        s.acceptedPayloadBytes = '0';
        s.totalAcceptedPayloadBytes = '48692';
        s.lastAcceptedAt = null;
        s.recoveryObservation = structuredClone(empty.recoveryObservation);
      }
    }
  f.records = f.records.filter((r) => r.probe.id !== empty.id.toLowerCase());
  for (const r of f.records)
    if (BigInt(r.probe.campaign) > 2n) bump(r.probe, 'totalDeliveredPayloadBytes', -removed);
  const native = qualifyOwnedNativeProbes(f.raw, f.options);
  assert.equal(native.attempts[1].stages[1].acceptedPayloadBytes, 0);
  assert.throws(
    () => qualify(f),
    /Unsupported conservation: unobserved zero-acceptance native stage/,
  );
});
