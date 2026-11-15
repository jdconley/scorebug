import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { qualifyNativeCadenceReports } from '../native-cadence-reports.mjs';
import { qualifyNativeDeliveryDeadlines } from '../native-delivery-deadlines.mjs';
import { qualifyMeasuredNativeMedia } from '../measured-native-trial.mjs';
import { qualifyRepeatedMeasuredPolicy } from '../repeated-measured-policy.mjs';
import { qualifyRepeatedMeasuredRecoveryFaults } from '../repeated-measured-recovery-fault.mjs';
import { repeatedMeasuredPolicyFixture } from './fixtures/repeated-measured-policy-evidence.mjs';
import {
  repeatedMeasuredRecoveryFaultFixture,
  repeatedMeasuredDeliveryFaultFixture,
  repeatedFaultDeliveryRow,
} from './fixtures/repeated-measured-recovery-fault-evidence.mjs';

// Synthetic envelope variants exercise routing only; historical exports stay unchanged.
function repeated(audit) {
  return {
    ...audit,
    formatVersion: 2,
    mode: 'repeated',
    maximumRows: 3072,
    maximumBytes: 16777216,
  };
}
function legacy(audit) {
  const result = { ...audit, formatVersion: 1 };
  for (const key of ['mode', 'maximumRows', 'maximumBytes']) delete result[key];
  return result;
}
function cadenceFixture(count = 3072) {
  const response = JSON.parse(
    fs.readFileSync(
      new URL('../../packages/protocol/fixtures/decoder-cadence-v1.json', import.meta.url),
    ),
  );
  response.status.decoderCadenceAgeUpperBoundMs = 100;
  const scope = {
    matchID: 'match',
    broadcastGeneration: 2,
    publishingAttemptID: response.status.publication.publishingAttemptId,
  };
  const audit = repeated({
    closed: true,
    overflow: false,
    invalid: false,
    rows: Array.from({ length: count }, (_, index) => ({
      response,
      expectedAttempt: scope.publishingAttemptID,
      receivedUptime: 100 + index / 10,
      evaluatedUptime: 100 + index / 10 + 0.002,
      requestSeconds: 0.01,
      residenceSeconds: 0.002,
      sampleAgeSeconds: 0.112,
      observedStall: false,
    })),
  });
  return { audit, scope };
}

test('native cadence accepts exactly 3072 rows only through explicit repeated mode', () => {
  const f = cadenceFixture(),
    before = JSON.stringify(f);
  assert.equal(
    qualifyNativeCadenceReports({ ...f, cadenceAuditMode: 'repeated' }).withinBudgetFraction,
    1,
  );
  assert.throws(() => qualifyNativeCadenceReports(f));
  assert.equal(JSON.stringify(f), before);
});

test('legacy cadence rejects repeated metadata even on a version1 small envelope', () => {
  for (const metadata of [
    { mode: 'repeated' },
    { maximumRows: 3072 },
    { maximumBytes: 16777216 },
  ]) {
    const f = cadenceFixture(401);
    f.audit = { ...legacy(f.audit), ...metadata };
    assert.throws(() => qualifyNativeCadenceReports(f));
  }
});

test('repeated cadence requires exact version mode bounds and closed successful envelope', () => {
  for (const change of [
    { formatVersion: 1 },
    { mode: 'legacy' },
    { mode: undefined },
    { maximumRows: 2048 },
    { maximumRows: 3073 },
    { maximumRows: undefined },
    { maximumBytes: 16777215 },
    { maximumBytes: 16777217 },
    { maximumBytes: undefined },
    { closed: false },
    { overflow: true },
    { invalid: true },
    { rows: [] },
  ]) {
    const f = cadenceFixture(401);
    Object.assign(f.audit, change);
    assert.throws(() => qualifyNativeCadenceReports({ ...f, cadenceAuditMode: 'repeated' }));
  }
  assert.throws(() =>
    qualifyNativeCadenceReports({ ...cadenceFixture(3073), cadenceAuditMode: 'repeated' }),
  );
  assert.throws(() =>
    qualifyNativeCadenceReports({ ...cadenceFixture(401), cadenceAuditMode: 'other' }),
  );
});

test('repeated cadence checks exact UTF8 serialized byte boundary including extra fields', () => {
  const f = cadenceFixture(401);
  f.audit.padding = '';
  const remaining = 16777216 - Buffer.byteLength(JSON.stringify(f.audit));
  f.audit.padding = 'x'.repeat(remaining);
  assert.equal(Buffer.byteLength(JSON.stringify(f.audit)), 16777216);
  assert.equal(
    qualifyNativeCadenceReports({ ...f, cadenceAuditMode: 'repeated' }).withinBudgetFraction,
    1,
  );
  f.audit.padding += 'é';
  assert.throws(() => qualifyNativeCadenceReports({ ...f, cadenceAuditMode: 'repeated' }));
});

test('deadline reconstruction explicitly opts into repeated reports without relabeling deadline audit', () => {
  const f = repeatedMeasuredRecoveryFaultFixture();
  const { row, report } = repeatedFaultDeliveryRow(f, {
    revision: '1',
    start: 140,
    end: 141,
    evaluatedAt: 143,
  });
  const input = {
    audit: {
      formatVersion: 1,
      closed: true,
      overflow: false,
      invalid: false,
      latencyBudget: 1.5,
      maximumSampleAge: 0.25,
      rows: [row],
    },
    reports: repeated({ ...f.cadenceReports, rows: [report] }),
    scope: f.scope,
    expectedLatencyBudget: 1.5,
  };
  assert.equal(
    qualifyNativeDeliveryDeadlines({ ...input, cadenceAuditMode: 'repeated' }).successfulRows,
    1,
  );
  assert.throws(() => qualifyNativeDeliveryDeadlines(input));
  assert.throws(() =>
    qualifyNativeDeliveryDeadlines({
      ...input,
      reports: legacy(input.reports),
      cadenceAuditMode: 'repeated',
    }),
  );
});

for (const routes of [
  ['decoderStall', 'decoderStall'],
  ['deliveryFailure', 'deliveryFailure'],
  ['decoderStall', 'deliveryFailure'],
])
  test(`repeated fault route requires v2 through nested ${routes.join('/')} checks`, () => {
    const f = repeatedMeasuredDeliveryFaultFixture(routes);
    f.cadenceReports = repeated(f.cadenceReports);
    assert.equal(qualifyRepeatedMeasuredRecoveryFaults(f).faultQualified, true);
    f.cadenceReports = legacy(f.cadenceReports);
    assert.throws(() => qualifyRepeatedMeasuredRecoveryFaults(f));
  });

test('global repeated policy propagates3072 report envelope through delivery faults and cadence partitions', () => {
  const f = repeatedMeasuredPolicyFixture(
    repeatedMeasuredDeliveryFaultFixture(['deliveryFailure', 'decoderStall']),
  );
  const first = f.cadenceReports.rows[0];
  const warmup = Array.from({ length: 3072 - f.cadenceReports.rows.length }, (_, index) => {
    const at = 1 + index / 30;
    return {
      expectedAttempt: first.expectedAttempt,
      receivedUptime: at,
      evaluatedUptime: at + 0.001,
      requestSeconds: 0.01,
      residenceSeconds: 0.001,
      sampleAgeSeconds: null,
      observedStall: null,
      deliveryReceiptID: null,
      deliverySampleAgeSeconds: null,
      response: {
        serverTime: first.response.serverTime,
        status: {
          gameId: f.scope.matchID,
          generation: f.scope.broadcastGeneration,
          state: 'unknown',
          observation: null,
        },
      },
    };
  });
  f.cadenceReports = repeated({ ...f.cadenceReports, rows: [...warmup, ...f.cadenceReports.rows] });
  assert.equal(f.cadenceReports.rows.length, 3072);
  const result = qualifyRepeatedMeasuredPolicy(f);
  assert.equal(result.repeatedPolicyQualified, true);
  assert.equal(result.productionUpgradeAuthorized, false);
  f.cadenceReports = legacy(f.cadenceReports);
  assert.throws(() => qualifyRepeatedMeasuredPolicy(f));
});

test('shared raw media takes repeated mode only from its explicit second options argument', () => {
  const f = JSON.parse(
    gunzipSync(
      fs.readFileSync(new URL('./fixtures/measured-trial-15qSdC.json.gz', import.meta.url)),
    ),
  ).input;
  f.cadenceReports = repeated(f.cadenceReports);
  const result = qualifyMeasuredNativeMedia(f, { cadenceAuditMode: 'repeated' });
  assert(result.source.intervals.length > 0);
  assert.throws(() => qualifyMeasuredNativeMedia({ ...f, cadenceAuditMode: 'repeated' }));
  f.cadenceReports = legacy(f.cadenceReports);
  assert.throws(() => qualifyMeasuredNativeMedia(f, { cadenceAuditMode: 'repeated' }));
});
