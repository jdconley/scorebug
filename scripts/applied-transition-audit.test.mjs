import { test } from 'node:test';
import assert from 'node:assert/strict';
import { verifyAppliedTransitionAudit } from './applied-transition-audit.mjs';

const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const auditOnly = ['admittedAt', 'completionDeadline', 'profileRequestedAt', 'rateRequestedAt'];
function fixture() {
  const record = (revision, at, fromEncoder, bitrate, profile, width, height) => ({
    attemptID: id(1),
    applicationID: id(revision + 10),
    fromRevision: String(revision - 1),
    revision: String(revision),
    sequence: String(revision),
    causeSequence: String(revision),
    input: 'window',
    reasons: 'test',
    at: String(at - 2),
    validUntil: String(at + 0.2),
    admittedAt: String(at),
    completionDeadline: String(at + 2),
    profileRequestedAt: String(at + 0.01),
    profileNativeAt: String(at + 0.4),
    rateRequestedAt: String(at + 0.41),
    nativeAt: String(at + 0.42),
    ackAt: String(at + 0.43),
    kind: revision === 1 ? 'trial' : 'decrease',
    profile,
    bitrate: String(bitrate),
    nativeBitrate: String(bitrate),
    formatWidth: String(width),
    formatHeight: String(height),
    profileGeneration: '1',
    rateGeneration: '1',
    oldEncoder: id(fromEncoder),
    newEncoder: id(fromEncoder + 1),
    rateEncoder: id(fromEncoder + 1),
    oldPTS: `${revision * 100}/30`,
    newPTS: `${revision * 100 + 1}/30`,
    ratePTS: `${revision * 100 + 2}/30`,
  });
  const records = [
    record(1, 10, 20, 3000000, '720p30', 1280, 720),
    record(2, 20, 21, 600000, '360p30', 640, 360),
  ];
  const audit = {
    formatVersion: 1,
    scope: 'successful applications only',
    attemptID: id(1),
    maximumRecords: 16,
    maximumRecordBytes: 8192,
    closed: true,
    overflow: false,
    timingContract: {
      formatVersion: 1,
      scope: 'ordinary-successful-applications',
      profileId: 'broadcast-reliability3000-v1',
      decoderBudgetMs: 3000,
      maximumCaptureWindowEvaluationAgeMs: 3500,
      maximumCompletedDecoderWindowReportAgeMs: 2000,
      maximumCadenceDeliveryReportAgeMs: 250,
      decoderStallThresholdMs: 1000,
    },
    records,
  };
  const phase = {
    formatVersion: 2,
    contract: 'recovery720',
    samples: records.map((r) => ({
      readStartedUptimeSeconds: Number(r.ackAt) + 0.1,
      readEndedUptimeSeconds: Number(r.ackAt) + 0.2,
      diagnostic: {
        policyAttemptID: id(1),
        policyAppliedRevision: r.revision,
        timingProfileID: audit.timingContract.profileId,
        appliedTransition: JSON.stringify(
          Object.fromEntries(Object.entries(r).filter(([k]) => !auditOnly.includes(k))),
        ),
      },
    })),
    exchanges: [
      {
        operation: 'constrain',
        sequence: 1,
        requestStartedUptimeSeconds: 19,
        responseEndedUptimeSeconds: 19.1,
        response: {
          runID: 'run',
          sequence: 1,
          phase: 'constrained',
          rateBitsPerSecond: 750000,
          appliedAt: 100,
          forwardOperationOrdinal: 40,
        },
      },
    ],
  };
  return { audit, phase };
}
const verify = (f) => verifyAppliedTransitionAudit(f.audit, f.phase);
test('binds complete successful history and reports request-relative first descent without media qualification', () => {
  const f = fixture(),
    result = verify(f);
  assert.equal(result.traceValid, true);
  assert.equal(result.mediaQualified, false);
  assert.equal(result.diagnosticOnly, true);
  assert.equal(result.sampledApplications, 2);
  assert.equal(result.firstDescent.revision, '2');
  assert(Math.abs(result.firstDescent.nativeCompletionAfterConstrainRequestMs[0] - 1320) < 0.0001);
  assert(Math.abs(result.firstDescent.nativeCompletionAfterConstrainRequestMs[1] - 1420) < 0.0001);
});
test('retains an unsampled first descent when only later UI state is observed', () => {
  const f = fixture();
  f.phase.samples = f.phase.samples.slice(1);
  assert.equal(verify(f).recordCount, 2);
});
test('cause may be latched long before admission and ACK may follow recommendation expiry', () => {
  const f = fixture();
  f.audit.records[1].at = '1';
  f.phase.samples = f.phase.samples.slice(0, 1);
  assert.equal(verify(f).traceValid, true);
});
for (const [name, mutate] of [
  [
    'open export',
    (f) => {
      f.audit.closed = false;
    },
  ],
  [
    'overflow',
    (f) => {
      f.audit.overflow = true;
    },
  ],
  [
    'missing records',
    (f) => {
      f.audit.records = [];
    },
  ],
  [
    'wrong scope',
    (f) => {
      f.audit.scope = 'all native effects';
    },
  ],
  [
    'owned timing scope',
    (f) => {
      f.audit.timingContract.scope = 'owned-capacity-diagnostic';
    },
  ],
  [
    'changed timing budget',
    (f) => {
      f.audit.timingContract.decoderBudgetMs = 700;
    },
  ],
  [
    'raised cap',
    (f) => {
      f.audit.maximumRecords = 17;
    },
  ],
  [
    'too many records',
    (f) => {
      f.audit.records = Array(17).fill(f.audit.records[0]);
    },
  ],
  [
    'oversized scalar',
    (f) => {
      f.audit.records[0].padding = 'x'.repeat(8192);
    },
  ],
  [
    'nested field',
    (f) => {
      f.audit.records[0].padding = {};
    },
  ],
  [
    'nonfinite time',
    (f) => {
      f.audit.records[0].ackAt = 'NaN';
    },
  ],
  [
    'noncanonical UUID',
    (f) => {
      f.audit.attemptID = 'ABC';
    },
  ],
  [
    'mixed attempts',
    (f) => {
      f.audit.records[1].attemptID = id(2);
    },
  ],
  [
    'duplicate application',
    (f) => {
      f.audit.records[1].applicationID = f.audit.records[0].applicationID;
    },
  ],
  [
    'omitted successful revision',
    (f) => {
      f.audit.records[1].revision = '3';
    },
  ],
  [
    'noncanonical revision',
    (f) => {
      f.audit.records[0].revision = '01';
    },
  ],
  [
    'admitted after expiry',
    (f) => {
      f.audit.records[0].validUntil = '9';
    },
  ],
  [
    'ACK after deadline',
    (f) => {
      f.audit.records[0].completionDeadline = '10.1';
    },
  ],
  [
    'rate requested before profile receipt',
    (f) => {
      f.audit.records[0].rateRequestedAt = '10.1';
    },
  ],
  [
    'missing request time',
    (f) => {
      delete f.audit.records[0].rateRequestedAt;
    },
  ],
  [
    'request after native write',
    (f) => {
      f.audit.records[0].rateRequestedAt = '11';
    },
  ],
  [
    'unverified bitrate',
    (f) => {
      f.audit.records[0].nativeBitrate = '1';
    },
  ],
  [
    'broken encoder continuity',
    (f) => {
      f.audit.records[1].oldEncoder = id(50);
    },
  ],
  [
    'broken generation',
    (f) => {
      f.audit.records[1].rateGeneration = '2';
    },
  ],
  [
    'nonincreasing source boundary',
    (f) => {
      f.audit.records[1].newPTS = f.audit.records[1].oldPTS;
    },
  ],
  [
    'rounded source boundary',
    (f) => {
      f.audit.records[1].newPTS = '6.7';
    },
  ],
  [
    'source moves backwards between applications',
    (f) => {
      f.audit.records[1].oldPTS = '1/30';
    },
  ],
  [
    'sample disagrees',
    (f) => {
      f.phase.samples[0].diagnostic.appliedTransition = '{}';
    },
  ],
  [
    'sample from another attempt',
    (f) => {
      f.phase.samples[0].diagnostic.policyAttemptID = id(50);
    },
  ],
  [
    'sample wrong current revision',
    (f) => {
      f.phase.samples[0].diagnostic.policyAppliedRevision = '5';
    },
  ],
  [
    'sample before ACK',
    (f) => {
      f.phase.samples[0].readEndedUptimeSeconds = 10;
    },
  ],
  [
    'no sampled witness',
    (f) => {
      f.phase.samples = [];
    },
  ],
  [
    'reversed constrain interval',
    (f) => {
      f.phase.exchanges[0].responseEndedUptimeSeconds = 18;
    },
  ],
])
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => verify(f));
  });
test('accepts same-encoder bitrate-only application with exact continuous source evidence', () => {
  const f = fixture(),
    r = f.audit.records[1];
  for (const k of [
    'formatWidth',
    'formatHeight',
    'profileGeneration',
    'oldEncoder',
    'newEncoder',
    'oldPTS',
    'newPTS',
    'profileRequestedAt',
    'profileNativeAt',
  ])
    delete r[k];
  r.rateEncoder = f.audit.records[0].rateEncoder;
  r.profile = '720p30';
  f.phase.samples = f.phase.samples.slice(0, 1);
  assert.equal(verify(f).traceValid, true);
});

test('rejects audit-only admission moved outside Core two-second application deadline', () => {
  const f = fixture();
  f.audit.records[1].admittedAt = '18';
  assert.throws(() => verify(f));
});
test('rejects inflated application deadline even with unchanged UI witness', () => {
  const f = fixture();
  f.audit.records[1].completionDeadline = '23';
  assert.throws(() => verify(f));
});

function cadenceFixture() {
  const f = fixture(),
    r = f.audit.records[1];
  Object.assign(r, {
    input: 'cadenceRejected',
    error: 'freshness',
    reasons: 'telemetryInvalidated',
    kind: 'reset',
  });
  // The UI retains the ordinary cause; cadence fields are audit-only.
  f.phase.samples[1].diagnostic.appliedTransition = JSON.stringify(
    Object.fromEntries(Object.entries(r).filter(([k]) => !auditOnly.includes(k))),
  );
  Object.assign(r, {
    cadenceReceiptID: id(99),
    cadenceEvaluatedAt: r.at,
    cadenceAgeState: 'available',
    cadenceSampleAgeSeconds: '0.35',
    cadenceMaximumSampleAgeSeconds: '0.25',
    cadenceServerAgeSeconds: '0.05',
    cadenceRequestSeconds: '0.1',
    cadenceResidenceSeconds: '0.2',
    cadenceReceiptPreviouslyConsumed: 'false',
    cadenceRequiresRevalidation: 'false',
    cadenceStalled: 'false',
    cadenceProgressAgeMs: '50.0',
    cadenceLastFreshPTS: '180000',
  });
  return f;
}
test('validates exact cadence rejection audit witness without adding it to UI fields', () => {
  assert.equal(verify(cadenceFixture()).traceValid, true);
});
for (const [name, mutate] of [
  [
    'missing error',
    (r) => {
      delete r.error;
    },
  ],
  [
    'missing component',
    (r) => {
      delete r.cadenceRequestSeconds;
    },
  ],
  [
    'wrong receipt',
    (r) => {
      r.cadenceReceiptID = 'bad';
    },
  ],
  [
    'changed limit',
    (r) => {
      r.cadenceMaximumSampleAgeSeconds = '0.5';
    },
  ],
  [
    'age sum mismatch',
    (r) => {
      r.cadenceSampleAgeSeconds = '0.4';
    },
  ],
  [
    'nonstale freshness rejection',
    (r) => {
      r.cadenceSampleAgeSeconds = '0.25';
      r.cadenceResidenceSeconds = '0.1';
    },
  ],
  [
    'detached evaluation',
    (r) => {
      r.cadenceEvaluatedAt = '19';
    },
  ],
  [
    'unknown unavailable reason',
    (r) => {
      r.cadenceAgeState = 'other';
    },
  ],
  [
    'unavailable but numeric total',
    (r) => {
      r.cadenceAgeState = 'statusExpired';
    },
  ],
  [
    'bad progress',
    (r) => {
      r.cadenceStalled = 'true';
    },
  ],
  [
    'unknown field',
    (r) => {
      r.cadenceInjected = '1';
    },
  ],
  [
    'wrong cause',
    (r) => {
      r.input = 'localPressure';
    },
  ],
  [
    'consumed without revalidation',
    (r) => {
      r.cadenceReceiptPreviouslyConsumed = 'true';
    },
  ],
])
  test(`rejects cadence ${name}`, () => {
    const f = cadenceFixture();
    mutate(f.audit.records[1]);
    assert.throws(() => verify(f));
  });
test('explicit unavailable cadence age does not fabricate a total', () => {
  const f = cadenceFixture();
  f.audit.records[1].cadenceAgeState = 'statusExpired';
  delete f.audit.records[1].cadenceSampleAgeSeconds;
  assert.equal(verify(f).traceValid, true);
});
test('physical audit entrypoint is separate and retains complete collapse requirements', async () => {
  const module = await import('./applied-transition-audit.mjs');
  assert.equal(typeof module.verifyPhysicalAppliedTransitionAudit, 'function');
  const f = cadenceFixture();
  assert.throws(() => module.verifyPhysicalAppliedTransitionAudit(f.audit, f.phase));
  Object.assign(f.phase, {
    formatVersion: 3,
    contract: 'physical-recovery720-v1',
    captureSource: 'physical-camera',
  });
  assert.equal(module.verifyPhysicalAppliedTransitionAudit(f.audit, f.phase).traceValid, true);
  assert.throws(() => verify(f));
  f.phase.exchanges = [];
  assert.throws(() => module.verifyPhysicalAppliedTransitionAudit(f.audit, f.phase));
});
test('context rejection may precede the consumed receipt fast path', () => {
  const f = cadenceFixture(),
    r = f.audit.records[1];
  r.error = 'ownership';
  r.cadenceReceiptPreviouslyConsumed = 'true';
  const ui = JSON.parse(f.phase.samples[1].diagnostic.appliedTransition);
  ui.error = 'ownership';
  f.phase.samples[1].diagnostic.appliedTransition = JSON.stringify(ui);
  assert.equal(verify(f).traceValid, true);
});

for (const [name, change] of [
  [
    'small components cannot overflow',
    (r) => {
      r.cadenceAgeState = 'ageOverflow';
      delete r.cadenceSampleAgeSeconds;
    },
  ],
  [
    'server exceeds producer ceiling',
    (r) => {
      r.cadenceAgeState = 'statusExpired';
      delete r.cadenceSampleAgeSeconds;
      r.cadenceServerAgeSeconds = '9007199254742';
    },
  ],
  [
    'request exceeds producer ceiling',
    (r) => {
      r.cadenceAgeState = 'statusExpired';
      delete r.cadenceSampleAgeSeconds;
      r.cadenceRequestSeconds = '9007199254742';
    },
  ],
  [
    'base components exceed producer ceiling',
    (r) => {
      r.cadenceAgeState = 'statusExpired';
      delete r.cadenceSampleAgeSeconds;
      r.cadenceServerAgeSeconds = String(Number.MAX_SAFE_INTEGER / 1000);
      r.cadenceRequestSeconds = '1';
    },
  ],
  [
    'available components exceed producer ceiling',
    (r) => {
      r.cadenceServerAgeSeconds = String(Number.MAX_SAFE_INTEGER / 1000);
      r.cadenceRequestSeconds = '0';
      r.cadenceResidenceSeconds = '1';
      r.cadenceSampleAgeSeconds = String(Number(r.cadenceServerAgeSeconds) + 1);
    },
  ],
])
  test(`rejects impossible age state: ${name} in both contracts`, async () => {
    const { verifyPhysicalAppliedTransitionAudit } = await import('./applied-transition-audit.mjs');
    const f = cadenceFixture();
    change(f.audit.records[1]);
    assert.throws(() => verify(f));
    Object.assign(f.phase, {
      formatVersion: 3,
      contract: 'physical-recovery720-v1',
      captureSource: 'physical-camera',
    });
    assert.throws(() => verifyPhysicalAppliedTransitionAudit(f.audit, f.phase));
  });
test('large age overflow and progress milliseconds respect their distinct units', () => {
  const f = cadenceFixture(),
    r = f.audit.records[1];
  Object.assign(r, {
    cadenceServerAgeSeconds: String(Number.MAX_SAFE_INTEGER / 1000),
    cadenceRequestSeconds: '0',
    cadenceResidenceSeconds: '1',
    cadenceAgeState: 'ageOverflow',
    cadenceProgressAgeMs: String(Number.MAX_SAFE_INTEGER),
    cadenceStalled: 'true',
  });
  delete r.cadenceSampleAgeSeconds;
  assert.equal(verify(f).traceValid, true);
});
test('serialization ambiguity at the exact age ceiling does not invent precision', () => {
  for (const state of ['available', 'ageOverflow']) {
    const f = cadenceFixture(),
      r = f.audit.records[1];
    // Double(seconds) + fractional seconds rounds these sub-ms boundaries.
    Object.assign(r, {
      cadenceServerAgeSeconds: String(Number.MAX_SAFE_INTEGER / 1000),
      cadenceRequestSeconds: '0',
      cadenceResidenceSeconds: '0.000001',
      cadenceAgeState: state,
    });
    if (state === 'available') r.cadenceSampleAgeSeconds = r.cadenceServerAgeSeconds;
    else delete r.cadenceSampleAgeSeconds;
    assert.equal(verify(f).traceValid, true);
  }
});
