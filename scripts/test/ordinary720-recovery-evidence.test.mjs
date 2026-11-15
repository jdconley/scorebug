import test from 'node:test';
import assert from 'node:assert/strict';
import * as evidence from '../ordinary-recovery-evidence.mjs';
import { ordinary720Fixture } from './fixtures/ordinary720-evidence.mjs';
const qualify = (f) => {
  assert.equal(typeof evidence.qualifyOrdinary720RecoveryNativeEvidence, 'function');
  return evidence.qualifyOrdinary720RecoveryNativeEvidence(f);
};
const witness = (f, i, change) => {
  const d = f.native.samples[i].diagnostic,
    v = JSON.parse(d.appliedTransition);
  change(v);
  d.appliedTransition = JSON.stringify(v);
};
test('closed v2 recovery720 qualifies four consecutive climbs and a newer possibly multi-step fallback', () => {
  const f = ordinary720Fixture(),
    result = qualify(f);
  assert.equal(result.nativePhaseOrderingQualified, true);
  assert.equal(result.mediaQualified, false);
  assert.equal(result.transportQualified, false);
  assert.equal(result.phases.length, 10);
  assert.equal(result.phases[4].phase, 'initial-720-confirmed');
  assert.throws(() => evidence.qualifyOrdinaryRecoveryNativeEvidence(f));
});
for (const [name, mutate] of [
  [
    'contract downgrade',
    (f) => {
      f.native.formatVersion = 1;
    },
  ],
  [
    'wrong contract',
    (f) => {
      f.native.contract = 'recovery';
    },
  ],
  [
    'missing720',
    (f) => {
      f.native.milestones = f.native.milestones.filter((m) => !m.phase.startsWith('initial-720'));
    },
  ],
  [
    '360 substitution',
    (f) => {
      f.native.samples[3].diagnostic.policyAppliedProfile = '360p30';
    },
  ],
  [
    'hidden climb rollback',
    (f) => {
      f.native.samples[3].diagnostic.policyAppliedRevision = '5';
    },
  ],
  [
    'reused trial owner',
    (f) => {
      f.native.samples[3].diagnostic.policyOwnerKey = f.native.samples[2].diagnostic.policyOwnerKey;
    },
  ],
  [
    'missing probation',
    (f) => {
      f.native.samples[3].diagnostic.policyTrialActive = 'false';
    },
  ],
  [
    'trial swap',
    (f) => {
      f.native.samples[4].diagnostic.policyAppliedRevision = '4';
    },
  ],
  [
    'early fallback',
    (f) => {
      f.native.samples[5].diagnostic.policyAcknowledgedAtUptimeSeconds = '1100';
    },
  ],
  [
    'early recovery',
    (f) => {
      f.native.samples[6].diagnostic.policyAcknowledgedAtUptimeSeconds = '1125';
    },
  ],
  [
    'expired gate',
    (f) => {
      f.native.gates[3].startedUptimeSeconds = 900;
    },
  ],
  [
    'stale source',
    (f) => {
      f.native.samples[3].diagnostic.policyAcceptedSourceWindowEnd = '1000';
    },
  ],
  [
    'oversized diagnostic',
    (f) => {
      f.native.samples[3].diagnostic.padding = 'a'.repeat(4096);
    },
  ],
  [
    'wrong dimensions',
    (f) =>
      witness(f, 3, (w) => {
        w.formatWidth = '640';
        w.formatHeight = '360';
      }),
  ],
  [
    'mismatched encoder',
    (f) =>
      witness(f, 3, (w) => {
        w.rateEncoder = w.oldEncoder;
      }),
  ],
  [
    'wrong preceding encoder',
    (f) =>
      witness(f, 3, (w) => {
        w.oldEncoder = '99999999-0000-4000-8000-000000000000';
      }),
  ],
  [
    'wrong recommendation kind',
    (f) =>
      witness(f, 3, (w) => {
        w.kind = 'reset';
      }),
  ],
  [
    'nonadjacent owner reuse',
    (f) => {
      f.native.samples[3].diagnostic.policyOwnerKey = f.native.samples[0].diagnostic.policyOwnerKey;
    },
  ],
  [
    'same encoders',
    (f) =>
      witness(f, 3, (w) => {
        w.oldEncoder = w.newEncoder;
      }),
  ],
  [
    'mismatched generation',
    (f) =>
      witness(f, 3, (w) => {
        w.rateGeneration = '8';
      }),
  ],
  [
    'mismatched receipt rate',
    (f) =>
      witness(f, 3, (w) => {
        w.nativeBitrate = '600000';
      }),
  ],
  [
    'out of order receipt',
    (f) =>
      witness(f, 3, (w) => {
        w.profileNativeAt = w.ackAt + '1';
      }),
  ],
  [
    'invalid rational',
    (f) =>
      witness(f, 3, (w) => {
        w.newPTS = '1/0';
      }),
  ],
  [
    'fractional integer',
    (f) =>
      witness(f, 3, (w) => {
        w.newPTS = '1.5/30';
      }),
  ],
  [
    'overflow integer',
    (f) =>
      witness(f, 3, (w) => {
        w.newPTS = '9223372036854775808/30';
      }),
  ],
  [
    'PTS rewind',
    (f) =>
      witness(f, 3, (w) => {
        w.ratePTS = w.oldPTS;
      }),
  ],
  [
    'missing receipt',
    (f) => {
      delete f.native.samples[3].diagnostic.appliedTransition;
    },
  ],
  [
    'observed constrained increase',
    (f) => {
      const s = structuredClone(f.native.samples[4]);
      s.readStartedUptimeSeconds = 1116;
      s.readEndedUptimeSeconds = 1116.1;
      s.diagnostic.policyAppliedRevision = '4';
      s.diagnostic.policyAcknowledgedAtUptimeSeconds = '1115';
      f.native.samples.splice(5, 0, s);
      for (const m of f.native.milestones) if (m.sampleIndex >= 5) m.sampleIndex++;
    },
  ],
])
  test(`720 rejects ${name}`, () => {
    const f = ordinary720Fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

function resyncAudit(f) {
  f.audit.records[0].diagnostic = structuredClone(f.native.samples[4].diagnostic);
  f.audit.records[1].diagnostic = structuredClone(f.native.samples[5].diagnostic);
}
for (const [name, indexes, mutate] of [
  [
    'climb PTS predates preceding receipt',
    [3, 4],
    (w) => {
      w.oldPTS = '0/1';
      w.newPTS = '1/1';
      w.ratePTS = '2/1';
    },
  ],
  [
    'climb native time predates preceding receipt',
    [3, 4],
    (w) => {
      w.profileNativeAt = '1000';
    },
  ],
  [
    'fallback PTS predates preceding receipt',
    [5],
    (w) => {
      w.oldPTS = '0/1';
      w.newPTS = '1/1';
      w.ratePTS = '2/1';
    },
  ],
  [
    'fallback native time predates preceding receipt',
    [5],
    (w) => {
      w.profileNativeAt = '1000';
    },
  ],
  [
    'fallback generation seeds a new recovery generation',
    [5, 6, 7, 8, 9],
    (w) => {
      w.profileGeneration = '8';
      w.rateGeneration = '8';
    },
  ],
])
  test(`720 rejects consistent ${name}`, () => {
    const f = ordinary720Fixture();
    for (const index of indexes) witness(f, index, mutate);
    resyncAudit(f);
    assert.throws(() => qualify(f));
  });
test('receipt continuity accepts exact equal rational lower bounds and skipped fallback encoders', () => {
  const f = ordinary720Fixture();
  const prior = JSON.parse(f.native.samples[2].diagnostic.appliedTransition);
  const [n, d] = prior.ratePTS.split('/').map(BigInt);
  for (const index of [3, 4])
    witness(f, index, (w) => {
      w.oldPTS = `${n * 2n}/${d * 2n}`;
      w.profileNativeAt = prior.nativeAt;
    });
  resyncAudit(f);
  assert.equal(qualify(f).nativePhaseOrderingQualified, true);
  const high = JSON.parse(f.native.samples[4].diagnostic.appliedTransition),
    fallback = JSON.parse(f.native.samples[5].diagnostic.appliedTransition);
  assert.notEqual(high.newEncoder, fallback.oldEncoder);
  assert(BigInt(fallback.revision) > BigInt(high.revision) + 1n);
});

test('720 rejects observed increase after selected fallback but before restoration', () => {
  const f = ordinary720Fixture(),
    extra = structuredClone(f.native.samples[6]);
  extra.readStartedUptimeSeconds = 1125.11;
  extra.readEndedUptimeSeconds = 1125.15;
  const d = extra.diagnostic;
  d.policyAcknowledgedAtUptimeSeconds = '1125.12';
  d.sessionObservedAtUptimeSeconds = '1125.13';
  d.observedAtUptimeSeconds = '1125.14';
  d.policyAcceptedSourceWindowEnd = '1125';
  d.policyAcceptedSourceSequence = '12';
  const receipt = JSON.parse(d.appliedTransition);
  receipt.ackAt = '1125.12';
  receipt.nativeAt = '1125.11';
  receipt.profileNativeAt = '1125.10';
  d.appliedTransition = JSON.stringify(receipt);
  f.native.samples.splice(6, 0, extra);
  for (const milestone of f.native.milestones)
    if (milestone.sampleIndex >= 6) milestone.sampleIndex++;
  assert.throws(() => qualify(f));
});
