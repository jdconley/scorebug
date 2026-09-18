import assert from 'node:assert/strict';
import test from 'node:test';
import { repeatedLifecycleFixture } from './fixtures/repeated-lifecycle-evidence.mjs';
import { qualifyRepeatedNativeBandwidthProbe } from '../repeated-native-bandwidth-probe.mjs';

const implementation = await import('../repeated-probe-retirement.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
const qualify = (f) => {
  assert.equal(
    typeof implementation.qualifyRepeatedProbeRetirements,
    'function',
    'repeated probe retirement verifier must be implemented',
  );
  return implementation.qualifyRepeatedProbeRetirements(f.probe, {
    lifecycle: f.lifecycle,
    quality: f.quality,
  });
};
const fixture = () => JSON.parse(JSON.stringify(repeatedLifecycleFixture()));
const request = (f, campaign = 1) => f.lifecycle.profileRequests[campaign * 2];
const resetRequest = (f, campaign = 1) => f.lifecycle.profileRequests[campaign * 2 + 1];
const candidate = (f, campaign = 1) =>
  f.quality.events.filter((e) => e.kind === 'candidate')[campaign];
const applied = (f, index = 2) => f.quality.events.filter((e) => e.kind === 'applied')[index];
const rawCampaign = (f, index = 1) => f.probe.campaigns[index];
const final = (f, index = 1) => rawCampaign(f, index).events.at(-1);
const live = (f, index = 1) =>
  rawCampaign(f, index)
    .events.filter((e) => e.sample.stage === 3 && e.sample.reason === null)
    .at(-1);

test('retirement fixture preserves valid raw two-campaign native proof', () => {
  const f = fixture();
  assert.equal(
    qualifyRepeatedNativeBandwidthProbe(f.probe, {
      scope: f.probe.scope,
      publishingGeneration: f.probe.publishingGeneration,
    }).campaigns.length,
    2,
  );
});

test('joins each original trial request to its own cancellation without policy permission', () => {
  const f = fixture(),
    before = structuredClone(f);
  const result = qualify(f);
  assert.deepEqual(f, before);
  assert.equal(result.mode, 'repeated');
  assert.deepEqual(
    result.campaigns.map((c) => c.campaign),
    ['1', '2'],
  );
  assert.deepEqual(
    result.campaigns.map((c) => c.appliedRevision),
    ['0', '2'],
  );
  for (const [index, row] of result.campaigns.entries()) {
    const r = request(f, index);
    assert.equal(row.profileRequestID, r.requestID);
    assert.equal(row.retirementRequestedAt, r.requestedAt);
    assert.equal(row.retiredObservedAt, r.terminalProbeRead.completedAt);
    assert.equal(row.retirementKind, 'profile-request-terminal-read');
    assert.ok(
      final(f, index).observedAt < r.terminalProbeRead.startedAt,
      'fixture must exercise raw final before post-receipt terminal read',
    );
  }
  for (const flag of [
    'receiverCapacityQualified',
    'admissionQualified',
    'recoveryQualified',
    'repeatedPolicyQualified',
    'upgradeAuthorized',
  ])
    assert.equal(result[flag], false);
});

const faults = {
  'legacy raw proof': (f) => (f.probe.formatVersion = 2),
  'invalid raw proof': (f) => (f.probe.campaigns[0].events[1].sample.acceptedPayloadBytes = '1'),
  'unclosed native proof': (f) => (f.probe.isClosed = false),
  'missing lifecycle': (f) => delete f.lifecycle,
  'legacy lifecycle': (f) => (f.lifecycle.formatVersion = 2),
  'unclosed lifecycle': (f) => (f.lifecycle.isClosed = false),
  'invalid lifecycle': (f) => (f.lifecycle.invalid = true),
  'overflow lifecycle': (f) => (f.lifecycle.overflow = true),
  'foreign lifecycle scope': (f) => (f.lifecycle.scope.recordingID += '-other'),
  'missing profile request': (f) => f.lifecycle.profileRequests.pop(),
  'extra profile request': (f) => f.lifecycle.profileRequests.push(structuredClone(request(f))),
  'reordered requests': (f) => f.lifecycle.profileRequests.reverse(),
  'missing quality': (f) => delete f.quality,
  'wrong quality version': (f) => (f.quality.formatVersion = 3),
  'overflow quality': (f) => (f.quality.overflow = true),
  'disabled candidate evaluation': (f) => (f.quality.measuredSourceEvaluationEnabled = false),
  'missing candidate event': (f) =>
    f.quality.events.splice(f.quality.events.indexOf(candidate(f)), 1),
  'extra candidate event': (f) => f.quality.events.push(structuredClone(candidate(f))),
  'missing reset application': (f) =>
    f.quality.events.splice(f.quality.events.indexOf(applied(f, 3)), 1),
  'extra application': (f) => f.quality.events.push(structuredClone(applied(f))),
  'closed trial': (f) => (candidate(f).closed = true),
  'closed applied event': (f) => (applied(f).closed = true),
  'trial from stale revision': (f) => (candidate(f).action.fromRevision = '0'),
  'trial application stale revision': (f) => (candidate(f).application.fromRevision = '0'),
  'candidate stale revision': (f) => (candidate(f).candidate.appliedRevision = '0'),
  'trial revision rewritten': (f) => (candidate(f).revision = '1'),
  'applied revision rewritten': (f) => (applied(f).revision = '1'),
  'foreign candidate owner': (f) => (candidate(f).candidate.attemptID = request(f).requestID),
  'foreign application owner': (f) => (candidate(f).application.attemptID = request(f).requestID),
  'crossed measurement': (f) =>
    (request(f).candidateMeasurementID = request(f, 0).candidateMeasurementID),
  'reused request identity': (f) => (request(f).requestID = request(f, 0).requestID),
  'reused application identity': (f) => {
    candidate(f).application.id = applied(f).application.id = applied(f, 0).application.id;
  },
  'missing candidate authority': (f) => (request(f).authorityPermitted = false),
  'missing probe authority': (f) => (request(f).probeAuthorityPermitted = false),
  'inactive current probe': (f) => (request(f).currentProbeActive = false),
  'failed trial request': (f) => (request(f).outcome = 'failed'),
  'failed trial native operation': (f) => (request(f).failure = 'cancelled'),
  'wrong trial target': (f) => (request(f).targetProfile = '240p30'),
  'missing terminal read': (f) => (request(f).terminalProbeRead = null),
  'wrong terminal campaign': (f) => (request(f).terminalProbeRead.observation.campaign = '1'),
  'wrong terminal identity': (f) =>
    (request(f).terminalProbeRead.observation.id = final(f, 0).sample.id),
  'wrong terminal bytes': (f) =>
    (request(f).terminalProbeRead.observation.acceptedPayloadBytes = '0'),
  'wrong terminal lease': (f) => (request(f).terminalProbeRead.observation.leaseDeadline += 0.001),
  'wrong terminal reason': (f) =>
    (request(f).terminalProbeRead.observation.reason = 'leaseExpired'),
  'terminal read before receipt': (f) =>
    (request(f).terminalProbeRead.startedAt = request(f).requestedAt),
  'terminal read reversed': (f) =>
    (request(f).terminalProbeRead.completedAt = request(f).terminalProbeRead.startedAt - 0.001),
  'terminal read after deadline': (f) =>
    (request(f).terminalProbeRead.completedAt =
      candidate(f).application.completionDeadline + 0.001),
  'request before application': (f) =>
    (request(f).requestedAt = candidate(f).application.admittedAt - 0.001),
  'request after action expiry': (f) => (candidate(f).action.validUntil = request(f).requestedAt),
  'unbounded deadline': (f) => (candidate(f).application.completionDeadline += 1),
  'stale current evaluation': (f) =>
    (candidate(f).candidate.evaluatedAt = request(f).requestedAt - 0.251),
  'quality receipt substituted': (f) => (candidate(f).profileReceipt.acknowledgedAt += 0.001),
  'wrong profile encoder': (f) => (request(f).receipt.encoderSessionID = request(f).requestID),
  'wrong bound campaign': (f) => (request(f).probeBinding.observation.campaign = '1'),
  'wrong current campaign': (f) => (request(f).currentProbe.campaign = '1'),
  'missing binding': (f) => (request(f).probeBinding = null),
  'missing current probe': (f) => (request(f).currentProbe = null),
  'unobserved binding lease': (f) => {
    request(f).probeBinding.observation.leaseDeadline += 0.001;
    candidate(f).candidateAdmission.binding.leaseDeadline += 0.001;
  },
  'changed current lease': (f) => (request(f).currentProbe.leaseDeadline += 0.001),
  'expired current lease': (f) => (request(f).requestedAt = request(f).currentProbe.leaseDeadline),
  'unaligned active bytes': (f) => (request(f).currentProbe.acceptedPayloadBytes = '1317'),
  'future active acceptance': (f) =>
    (request(f).currentProbe.lastAcceptedAt = request(f).requestedAt + 0.001),
  'changed admission current': (f) =>
    (candidate(f).candidateAdmission.probe.acceptedPayloadBytes = '0'),
  'changed admission binding': (f) =>
    (candidate(f).candidateAdmission.binding.acceptedPayloadBytes = '0'),
  'changed admission measurement': (f) =>
    (candidate(f).candidateAdmission.measurement.id = request(f).requestID),
  'changed admission revision': (f) => (candidate(f).candidateAdmission.applied.revision = '0'),
  'early cancellation': (f) => {
    request(f).requestedAt = final(f).observedAt + 0.001;
    candidate(f).application.admittedAt = request(f).requestedAt - 0.001;
  },
  'foreign reset historical candidate': (f) =>
    (resetRequest(f).candidateMeasurementID = request(f, 0).candidateMeasurementID),
  'reset impersonates trial': (f) => (applied(f, 3).action.kind = 'trial'),
  'reset wrong revision': (f) => (applied(f, 3).revision = '2'),
  'reset wrong prior revision': (f) => (applied(f, 3).application.fromRevision = '1'),
  'reset borrows candidate action': (f) =>
    (applied(f, 3).action.candidateID = request(f).candidateMeasurementID),
  'reset borrows candidate application': (f) =>
    (applied(f, 3).application.candidateID = request(f).candidateMeasurementID),
  'reset claims live probe authority': (f) => (resetRequest(f).probeAuthorityPermitted = true),
  'reset replaces original cancellation': (f) =>
    (resetRequest(f).terminalProbeRead.observation.campaign = '1'),
  'reset changes historical bytes': (f) =>
    (resetRequest(f).terminalProbeRead.observation.acceptedPayloadBytes = '0'),
  'reset precedes trial': (f) => (resetRequest(f).requestedAt = request(f).requestedAt - 0.001),
  'second campaign substitutes reset encoder': (f) =>
    (rawCampaign(f).context.encoderSessionID = applied(f, 0).receipt.encoderSessionID),
  'second campaign substitutes reset configuration': (f) =>
    (rawCampaign(f).context.configurationID = applied(f, 0).receipt.configurationID),
  'reset after lifecycle closure': (f) => (applied(f, 3).at = f.lifecycle.closedAt + 0.001),
};
for (const [name, mutate] of Object.entries(faults))
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

test('reset dispatch may omit its closed historical measurement', () => {
  const f = fixture();
  resetRequest(f, 0).candidateMeasurementID = resetRequest(f).candidateMeasurementID = null;
  assert.equal(qualify(f).campaigns.length, 2);
});

test('raw final may be observed after the lifecycle terminal read without changing causality', () => {
  const f = fixture();
  for (let index = 0; index < 2; index++)
    final(f, index).observedAt = request(f, index).terminalProbeRead.completedAt + 0.001;
  assert.equal(qualify(f).campaigns.length, 2);
});

test('allows a live renewal snapshot delivered after dispatch when its native instant precedes dispatch', () => {
  const f = fixture();
  live(f).observedAt = request(f).requestedAt + 0.001;
  assert.equal(qualify(f).campaigns.length, 2);
});

test('accepts cancellation observed by the suspended native renewal', () => {
  const f = fixture();
  for (const campaign of f.probe.campaigns)
    campaign.events.find((event) => event.phase === 'observed').phase = 'renewed';
  assert.equal(qualify(f).campaigns.length, 2);
});

function setTerminalAcceptance(f, at) {
  const terminal = final(f).sample;
  terminal.acceptedPayloadBytes = String(Number(terminal.acceptedPayloadBytes) + 1316);
  terminal.totalAcceptedPayloadBytes = String(Number(terminal.totalAcceptedPayloadBytes) + 1316);
  terminal.lastAcceptedAt = at;
  for (const event of rawCampaign(f).events.filter(
    (event) => event.sample.reason !== null && event.sample.stage === 3,
  ))
    event.sample = structuredClone(terminal);
  for (const row of [request(f), resetRequest(f)]) {
    const { campaignStartedAt, totalAcceptedPayloadBytes, ...observation } = terminal;
    row.terminalProbeRead.observation = structuredClone(observation);
  }
}

test('allows an in-flight send between external dispatch and joined native cancellation', () => {
  const f = fixture();
  setTerminalAcceptance(f, request(f).requestedAt + 0.001);
  assert.equal(qualify(f).campaigns.length, 2);
});

test('rejects acceptance after the native profile receipt even when delayed terminal observations match', () => {
  const f = fixture();
  setTerminalAcceptance(f, request(f).receipt.acknowledgedAt + 0.001);
  rawCampaign(f).events.find((event) => event.phase === 'observed').observedAt =
    request(f).receipt.acknowledgedAt + 0.002;
  final(f).observedAt = request(f).receipt.acknowledgedAt + 0.003;
  qualifyRepeatedNativeBandwidthProbe(f.probe, {
    scope: f.probe.scope,
    publishingGeneration: f.probe.publishingGeneration,
  });
  assert.throws(() => qualify(f), /acceptance after joined profile cancellation/);
});

function busyCampaign() {
  const f = fixture();
  for (const event of rawCampaign(f).events.filter((event) => event.sample.stage === 3)) {
    const n = Number(event.sample.acceptedPayloadBytes) * 90;
    event.sample.acceptedPayloadBytes = String(n);
    event.sample.totalAcceptedPayloadBytes = String(5264 + n);
  }
  for (const p of [
    request(f).probeBinding.observation,
    request(f).currentProbe,
    candidate(f).candidateAdmission.binding,
    candidate(f).candidateAdmission.probe,
    request(f).terminalProbeRead.observation,
    resetRequest(f).terminalProbeRead.observation,
  ])
    p.acceptedPayloadBytes = String(Number(p.acceptedPayloadBytes) * 90);
  return f;
}
function syncBound(f) {
  candidate(f).candidateAdmission.boundAt = request(f).probeBinding.boundAt;
  candidate(f).candidateAdmission.binding = structuredClone(request(f).probeBinding.observation);
}

test('rejects an interpolated burst from a native checkpoint to the bound observation', () => {
  const f = busyCampaign();
  assert.equal(qualify(f).campaigns.length, 2);
  const p = request(f).probeBinding.observation;
  p.acceptedPayloadBytes = String(Number(p.acceptedPayloadBytes) + 5 * 1316);
  p.lastAcceptedAt = request(f).probeBinding.boundAt + 0.00001;
  request(f).probeBinding.boundAt += 0.00002;
  syncBound(f);
  assert.throws(() => qualify(f), /one-message token allowance/);
});

test('rejects an interpolated burst from the bound observation to a later native checkpoint', () => {
  const f = busyCampaign();
  const p = request(f).probeBinding.observation;
  const next = rawCampaign(f).events.find(
    (event) =>
      event.sample.stage === 3 &&
      event.sample.acceptedPayloadBytes === String((57 + 1) * 90 * 1316),
  );
  p.acceptedPayloadBytes = String((57 * 90 + 1) * 1316);
  p.lastAcceptedAt = next.sample.lastAcceptedAt - 0.00001;
  request(f).probeBinding.boundAt = next.sample.lastAcceptedAt;
  syncBound(f);
  assert.throws(() => qualify(f), /one-message token allowance/);
});

test('preserves unchanged counts and acceptance timestamps while leases advance', () => {
  const f = fixture();
  const bound = request(f).probeBinding.observation;
  const accepted = Number(bound.acceptedPayloadBytes);
  for (const event of rawCampaign(f).events.filter((event) => event.sample.stage === 3)) {
    if (Number(event.sample.acceptedPayloadBytes) >= accepted) {
      event.sample.acceptedPayloadBytes = String(accepted);
      event.sample.totalAcceptedPayloadBytes = String(5264 + accepted);
      event.sample.lastAcceptedAt = bound.lastAcceptedAt;
    }
  }
  for (const value of [
    request(f).currentProbe,
    candidate(f).candidateAdmission.probe,
    request(f).terminalProbeRead.observation,
    resetRequest(f).terminalProbeRead.observation,
  ]) {
    value.acceptedPayloadBytes = bound.acceptedPayloadBytes;
    value.lastAcceptedAt = bound.lastAcceptedAt;
  }
  assert.equal(qualify(f).campaigns.length, 2);
  request(f).currentProbe.lastAcceptedAt += 0.001;
  candidate(f).candidateAdmission.probe.lastAcceptedAt += 0.001;
  assert.throws(() => qualify(f), /timestamp changed without bytes/);
});

test('scheduled joined retirement cannot masquerade as profile-caused cancellation', () => {
  const f = fixture();
  const campaign = rawCampaign(f);
  campaign.events.pop();
  const terminal = campaign.events.at(-1);
  terminal.phase = 'retired';
  terminal.retirementRequestedAt = terminal.observedAt - 0.001;
  campaign.status = 'completed';
  qualifyRepeatedNativeBandwidthProbe(f.probe, {
    scope: f.probe.scope,
    publishingGeneration: f.probe.publishingGeneration,
  });
  assert.throws(() => qualify(f), /joined profile cancellation/);
});

const bootstrap = (f) => f.quality.events.find((event) => event.kind === 'bootstrap');
test('joins the first campaign to its original bootstrap, not a mutually substituted baseline', () => {
  const f = fixture();
  const configurationID = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
  rawCampaign(f, 0).context.configurationID = configurationID;
  candidate(f, 0).candidateAdmission.applied.receipt = {
    ...structuredClone(candidate(f, 0).candidateAdmission.applied.receipt),
    configurationID,
  };
  assert.notEqual(bootstrap(f).receipt.configurationID, configurationID);
  assert.notEqual(f.lifecycle.bitRateRequests[0].receipt.configurationID, configurationID);
  qualifyRepeatedNativeBandwidthProbe(f.probe, {
    scope: f.probe.scope,
    publishingGeneration: f.probe.publishingGeneration,
  });
  assert.throws(() => qualify(f), /bootstrap/);
});

for (const [name, mutate] of Object.entries({
  'missing bootstrap': (f) => f.quality.events.splice(f.quality.events.indexOf(bootstrap(f)), 1),
  'duplicate bootstrap': (f) => f.quality.events.push(structuredClone(bootstrap(f))),
  'bootstrap not first': (f) => f.quality.events.splice(1, 0, f.quality.events.shift()),
  'closed bootstrap': (f) => (bootstrap(f).closed = true),
  'bootstrap wrong revision': (f) => (bootstrap(f).revision = '1'),
  'bootstrap wrong profile': (f) => (bootstrap(f).profileID = '360p30'),
  'bootstrap wrong bitrate': (f) => (bootstrap(f).receipt.bitRate = 600000),
  'bootstrap wrong generation': (f) => (bootstrap(f).receipt.generation = '99'),
  'bootstrap foreign encoder': (f) =>
    (bootstrap(f).receipt.encoderSessionID = request(f).requestID),
  'bootstrap foreign configuration': (f) =>
    (bootstrap(f).receipt.configurationID = request(f).requestID),
  'bootstrap acknowledgment differs from native context': (f) =>
    (bootstrap(f).acknowledgedAt += 0.001),
  'bootstrap receipt after acknowledgment': (f) =>
    (bootstrap(f).receipt.acceptedAt = bootstrap(f).acknowledgedAt + 0.001),
  'bootstrap event before acknowledgment': (f) =>
    (bootstrap(f).at = bootstrap(f).acknowledgedAt - 0.001),
  'bootstrap event after campaign begins': (f) =>
    (bootstrap(f).at = rawCampaign(f, 0).events[0].sample.startedAt + 0.001),
  'bootstrap missing receipt': (f) => delete bootstrap(f).receipt,
  'bootstrap nonfinite acknowledgment': (f) => (bootstrap(f).acknowledgedAt = Infinity),
  'substituted admission baseline receipt timestamp': (f) => {
    const p = candidate(f, 0).candidateAdmission.applied;
    p.receipt = { ...structuredClone(p.receipt), acceptedAt: p.receipt.acceptedAt + 0.001 };
  },
}))
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f), /bootstrap/);
  });

test('valid original bootstrap tolerates native UUID case and later acknowledgment within its bounds', () => {
  const f = fixture();
  rawCampaign(f, 0).context.configurationID = rawCampaign(
    f,
    0,
  ).context.configurationID.toUpperCase();
  rawCampaign(f, 0).context.encoderSessionID = rawCampaign(
    f,
    0,
  ).context.encoderSessionID.toUpperCase();
  bootstrap(f).acknowledgedAt =
    rawCampaign(f, 0).context.acknowledgedAt =
    candidate(f, 0).candidateAdmission.applied.acknowledgedAt =
      100.105;
  const result = qualify(f);
  assert.equal(result.campaigns[0].appliedRevision, '0');
  assert.equal(result.admissionQualified, false);
  assert.equal(result.repeatedPolicyQualified, false);
});

test('joins actual native lowercase admission receipts to uppercase quality UUID receipts without rewriting proof', () => {
  const f = fixture();
  for (let index = 0; index < 2; index++) {
    const admission = candidate(f, index).candidateAdmission.applied;
    admission.receipt = structuredClone(admission.receipt);
    const original = index === 0 ? bootstrap(f).receipt : applied(f, 1).receipt;
    for (const key of ['configurationID', 'encoderSessionID']) {
      admission.receipt[key] = admission.receipt[key].toLowerCase();
      original[key] = original[key].toUpperCase();
      f.lifecycle.bitRateRequests[index === 0 ? 0 : 2].receipt[key] = original[key];
    }
  }
  const before = structuredClone(f);
  assert.equal(qualify(f).campaigns.length, 2);
  assert.deepEqual(f, before);
});

function renewAfterCachedCurrent(f, at) {
  const campaign = rawCampaign(f);
  const previous = structuredClone(live(f));
  previous.observedAt = at + 0.001;
  previous.sample.leaseDeadline = at + 0.3;
  const terminalIndex = campaign.events.findIndex(
    (event) => event.sample.stage === 3 && event.sample.reason !== null,
  );
  campaign.events.splice(terminalIndex, 0, previous);
  for (const event of campaign.events.slice(terminalIndex + 1))
    event.sample.leaseDeadline = previous.sample.leaseDeadline;
  request(f).terminalProbeRead.observation.leaseDeadline = previous.sample.leaseDeadline;
  resetRequest(f).terminalProbeRead.observation.leaseDeadline = previous.sample.leaseDeadline;
}

for (const [name, at] of [
  ['before dispatch', 189.97],
  ['after dispatch', 189.99],
])
  test(`permits a same-owner renewal ${name} after the cached current observation`, () => {
    const f = fixture();
    renewAfterCachedCurrent(f, at);
    qualifyRepeatedNativeBandwidthProbe(f.probe, {
      scope: f.probe.scope,
      publishingGeneration: f.probe.publishingGeneration,
    });
    assert.ok(request(f).currentProbe.leaseDeadline < final(f).sample.leaseDeadline);
    assert.equal(qualify(f).campaigns.length, 2);
  });

test('rejects a renewed native lease whose provable instant is after the joined profile receipt', () => {
  const f = fixture();
  const at = request(f).receipt.acknowledgedAt + 0.001;
  renewAfterCachedCurrent(f, at);
  rawCampaign(f).events.find((event) => event.phase === 'observed').observedAt = at + 0.002;
  final(f).observedAt = at + 0.003;
  qualifyRepeatedNativeBandwidthProbe(f.probe, {
    scope: f.probe.scope,
    publishingGeneration: f.probe.publishingGeneration,
  });
  assert.throws(() => qualify(f), /cancellation/);
});
