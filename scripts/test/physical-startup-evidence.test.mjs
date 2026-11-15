import test from 'node:test';
import assert from 'node:assert/strict';
import * as nativeEvidence from '../ordinary-recovery-evidence.mjs';
import * as geometryEvidence from '../ordinary-geometry-evidence.mjs';
import {
  physical720Fixture,
  physical720GeometryFixture,
} from './fixtures/physical720-evidence.mjs';
import {
  ordinary720Fixture,
  ordinary720GeometryFixture,
} from './fixtures/ordinary720-evidence.mjs';
const qualify = (input) => {
  assert.equal(typeof nativeEvidence.qualifyPhysical720RecoveryNativeEvidence, 'function');
  return nativeEvidence.qualifyPhysical720RecoveryNativeEvidence(input);
};
const encoder = (f) => f.native.samples[0];
const source = (f) => f.native.samples[1];
const gate = (f, phase) => f.native.gates.find((g) => g.phase === phase);

test('physical v3 distinguishes native encoder ACK from later qualified source acquisition', () => {
  const f = physical720Fixture();
  const result = qualify(f);
  assert.equal(result.nativePhaseOrderingQualified, true);
  assert.equal(result.physicalStartupQualified, true);
  assert.equal(result.mediaQualified, false);
  assert.equal(result.transportQualified, false);
  assert.equal(result.phases.length, 10);
  assert.equal(result.phases[0].phase, 'initial-source-ready');
  assert.equal(encoder(f).diagnostic.policyOwnerKey, undefined);
  assert(source(f).readEndedUptimeSeconds > f.native.workerOutputObservedUptimeSeconds + 10);
  assert.throws(() => nativeEvidence.qualifyOrdinary720RecoveryNativeEvidence(f));
  assert.throws(() => nativeEvidence.qualifyOrdinaryRecoveryNativeEvidence(f));
});

test('ordinary contract and closed ten-gate startup remain distinct', () => {
  const f = ordinary720Fixture();
  assert.equal(
    nativeEvidence.qualifyOrdinary720RecoveryNativeEvidence(f).nativePhaseOrderingQualified,
    true,
  );
  assert.throws(() => qualify(f));
  f.native.gates[0].limitSeconds = 30;
  assert.throws(() => nativeEvidence.qualifyOrdinary720RecoveryNativeEvidence(f));
});

for (const [name, change] of [
  [
    'wrong format',
    (f) => {
      f.native.formatVersion = 2;
    },
  ],
  [
    'wrong contract',
    (f) => {
      f.native.contract = 'recovery720';
    },
  ],
  [
    'wrong capture source',
    (f) => {
      f.native.captureSource = 'file';
    },
  ],
  [
    'retained failure',
    (f) => {
      f.native.failure = 'initial readiness failed';
    },
  ],
  [
    'missing ACK milestone',
    (f) => {
      f.native.milestones = f.native.milestones.filter((m) => m.phase !== 'initial-encoder-ack');
    },
  ],
  [
    'missing acquisition milestone',
    (f) => {
      f.native.milestones = f.native.milestones.filter((m) => m.phase !== 'initial-source-ready');
    },
  ],
  [
    'missing ACK gate',
    (f) => {
      f.native.gates.shift();
    },
  ],
  [
    'missing source gate',
    (f) => {
      f.native.gates.splice(1, 1);
    },
  ],
  [
    'extra gate',
    (f) => {
      f.native.gates.push({ ...f.native.gates[0] });
    },
  ],
  [
    'missing local anchor',
    (f) => {
      delete f.native.localPublishingObservedUptimeSeconds;
    },
  ],
  [
    'missing output anchor',
    (f) => {
      delete f.native.workerOutputObservedUptimeSeconds;
    },
  ],
  [
    'anchor without observed milestone',
    (f) => {
      f.native.milestones = f.native.milestones.filter((m) => m.phase !== 'worker-output-observed');
    },
  ],
  [
    'late ACK',
    (f) => {
      encoder(f).readStartedUptimeSeconds = 1012;
      encoder(f).readEndedUptimeSeconds = 1012.1;
    },
  ],
  [
    'late acquisition',
    (f) => {
      source(f).readStartedUptimeSeconds = 1042;
      source(f).readEndedUptimeSeconds = 1042.1;
    },
  ],
  [
    'detached ACK gate',
    (f) => {
      gate(f, 'initial-encoder-ack').startedUptimeSeconds += 1;
    },
  ],
  [
    'detached acquisition gate',
    (f) => {
      gate(f, 'initial-source-ready').startedUptimeSeconds += 1;
    },
  ],
  [
    'relaxed ACK budget',
    (f) => {
      gate(f, 'initial-encoder-ack').limitSeconds = 11;
    },
  ],
  [
    'relaxed acquisition budget',
    (f) => {
      gate(f, 'initial-source-ready').limitSeconds = 31;
    },
  ],
  [
    'output observed before ACK',
    (f) => {
      f.native.workerOutputObservedUptimeSeconds = 1005;
    },
  ],
  [
    'wrong ACK profile',
    (f) => {
      encoder(f).diagnostic.policyAppliedProfile = '360p30';
    },
  ],
  [
    'wrong ACK bitrate',
    (f) => {
      encoder(f).diagnostic.policyAppliedBitrate = '600000';
    },
  ],
  [
    'nonzero initial revision',
    (f) => {
      encoder(f).diagnostic.policyAppliedRevision = '1';
    },
  ],
  [
    'wrong initial attempt',
    (f) => {
      encoder(f).diagnostic.policyAttemptID = 'other';
    },
  ],
  [
    'ACK before recording',
    (f) => {
      encoder(f).diagnostic.policyAcknowledgedAtUptimeSeconds = '999';
    },
  ],
  [
    'future ACK',
    (f) => {
      encoder(f).diagnostic.policyAcknowledgedAtUptimeSeconds = '1007';
    },
  ],
  [
    'closed ACK',
    (f) => {
      encoder(f).diagnostic.sessionClosed = 'true';
    },
  ],
  [
    'busy ACK',
    (f) => {
      encoder(f).diagnostic.sessionBusy = 'true';
    },
  ],
  [
    'active ACK trial',
    (f) => {
      encoder(f).diagnostic.policyTrialActive = 'true';
    },
  ],
  [
    'ACK rollback required',
    (f) => {
      encoder(f).diagnostic.policyTrialRollbackRequired = 'true';
    },
  ],
  [
    'stale ACK observation',
    (f) => {
      encoder(f).diagnostic.sessionObservedAtUptimeSeconds = '1000';
    },
  ],
  [
    'source missing owner',
    (f) => {
      delete source(f).diagnostic.policyOwnerKey;
    },
  ],
  [
    'stale acquisition source',
    (f) => {
      source(f).diagnostic.policyAcceptedSourceWindowEnd = '1010';
    },
  ],
  [
    'active acquisition trial',
    (f) => {
      source(f).diagnostic.policyTrialActive = 'true';
    },
  ],
  [
    'acquisition attempt substitution',
    (f) => {
      source(f).diagnostic.policyAttemptID = 'other';
    },
  ],
  [
    'acquisition ACK substitution',
    (f) => {
      source(f).diagnostic.policyAcknowledgedAtUptimeSeconds = '1006';
    },
  ],
  [
    'reset substitution',
    (f) => {
      source(f).diagnostic.policyAppliedRevision = '2';
      source(f).diagnostic.policyAcknowledgedAtUptimeSeconds = '1023';
    },
  ],
  [
    'hidden intervening revision',
    (f) => {
      const s = structuredClone(encoder(f));
      s.readStartedUptimeSeconds = 1014;
      s.readEndedUptimeSeconds = 1014.1;
      s.diagnostic.policyAppliedRevision = '1';
      f.native.samples.splice(1, 0, s);
      for (const m of f.native.milestones) if (m.sampleIndex >= 1) m.sampleIndex++;
    },
  ],
  [
    'weakened later increase gate',
    (f) => {
      gate(f, 'initial-360-increase').limitSeconds = 151;
    },
  ],
  [
    'missing later probation',
    (f) => {
      f.native.samples[4].diagnostic.policyTrialActive = 'false';
    },
  ],
  [
    'stale later source',
    (f) => {
      f.native.samples[4].diagnostic.policyAcceptedSourceWindowEnd = '1000';
    },
  ],
  [
    'later trial owner swap',
    (f) => {
      f.native.samples[5].diagnostic.policyOwnerKey = 'f'.repeat(64);
    },
  ],
  [
    'early fallback',
    (f) => {
      f.native.samples[6].diagnostic.policyAcknowledgedAtUptimeSeconds = '1110';
    },
  ],
  [
    'altered mutation diagnostic',
    (f) => {
      f.audit.records[0].diagnostic.policyAppliedProfile = '240p30';
    },
  ],
  [
    'recording budget expansion',
    (f) => {
      f.native.recordingDeadlineUptimeSeconds = 1541;
    },
  ],
])
  test(`physical startup rejects ${name}`, () => {
    const f = physical720Fixture();
    change(f);
    assert.throws(() => qualify(f));
  });

// Move all associated observations together: these failures must come from the
// fixed startup budget, not stale diagnostics or a detached milestone.
for (const [phase, end, message] of [
  ['initial-encoder-ack', 1012, 'initial-encoder-ack exceeded its gate'],
  ['initial-source-ready', 1042, 'initial-source-ready exceeded its gate'],
])
  test(`physical ${phase} deadline remains fixed with otherwise fresh evidence`, () => {
    function at(readEnd) {
      const f = physical720Fixture();
      const sample = phase === 'initial-encoder-ack' ? encoder(f) : source(f);
      sample.readStartedUptimeSeconds = readEnd - 0.1;
      sample.readEndedUptimeSeconds = readEnd;
      sample.diagnostic.sessionObservedAtUptimeSeconds = String(readEnd - 0.25);
      sample.diagnostic.observedAtUptimeSeconds = String(readEnd - 0.2);
      f.native.milestones.find((m) => m.phase === phase).uptimeSeconds = readEnd;
      if (phase === 'initial-encoder-ack') {
        f.native.workerOutputObservedUptimeSeconds = 1014;
        f.native.milestones.find((m) => m.phase === 'worker-output-observed').uptimeSeconds = 1014;
        gate(f, 'initial-source-ready').startedUptimeSeconds = 1014;
      } else {
        sample.diagnostic.policyAcceptedSourceWindowEnd = String(readEnd - 0.3);
        gate(f, 'initial-360-increase').startedUptimeSeconds = readEnd;
      }
      return f;
    }
    assert.equal(qualify(at(end - 0.01)).physicalStartupQualified, true);
    assert.throws(() => qualify(at(end + 0.01)), { message });
  });

test('physical geometry uses the physical native contract and only source-backed windows', () => {
  assert.equal(typeof geometryEvidence.qualifyPhysical720GeometryEvidence, 'function');
  const f = physical720GeometryFixture();
  const result = geometryEvidence.qualifyPhysical720GeometryEvidence(f);
  assert.equal(result.geometryQualified, true);
  assert.equal(result.phases.length, 10);
  assert.equal(result.phases[0].phase, 'initial-source-ready');
  assert.equal(result.mediaQualified, false);
  assert.throws(() => geometryEvidence.qualifyOrdinary720GeometryEvidence(f));
  assert.throws(() =>
    geometryEvidence.qualifyPhysical720GeometryEvidence(ordinary720GeometryFixture()),
  );
  f.workerRows[2].width = 640;
  assert.throws(() => geometryEvidence.qualifyPhysical720GeometryEvidence(f));
});
