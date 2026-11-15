import assert from 'node:assert/strict';
import test from 'node:test';
import { repeatedCandidateFixture } from './fixtures/repeated-candidate-evidence.mjs';
import { qualifyRepeatedNativeBandwidthProbe } from '../repeated-native-bandwidth-probe.mjs';
import { qualifyNativeProfileTransitions } from '../native-profile-transitions.mjs';
import { qualifyNativeCandidateMeasurement } from '../native-candidate-measurement.mjs';

const implementation = await import('../repeated-native-candidate-measurement.mjs').catch(
  (error) => {
    if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
    return {};
  },
);
const qualify = ({ proof, options }) => {
  assert.equal(
    typeof implementation.qualifyRepeatedNativeCandidateMeasurements,
    'function',
    'repeated candidate verifier must be implemented',
  );
  return implementation.qualifyRepeatedNativeCandidateMeasurements(proof, options);
};
const campaign = (f) => f.proof.campaigns[1];
const measurement = (f) => campaign(f).measurement;
const binding = (f) => measurement(f).probeBinding;

test('raw candidate fixtures satisfy their existing independent validators', () => {
  const { proof, options } = repeatedCandidateFixture();
  qualifyRepeatedNativeBandwidthProbe(options.nativeProbe, {
    scope: options.scope,
    publishingGeneration: '2',
  });
  const media = qualifyNativeProfileTransitions(options.format, options.snapshot, options.liveIDs, {
    sequence: 'repeated240',
    requireFrameEvidence: true,
  });
  for (const [index, row] of proof.campaigns.entries()) {
    qualifyNativeCandidateMeasurement(row.measurement, {
      scope: options.scope,
      profile: '360p30',
      liveProfile: '240p30',
      requiredFormatVersion: 3,
      format: { ...media.phases[index * 2], scope: options.scope, publishingGeneration: '2' },
    });
  }
});

test('replays original two-campaign A/V measurements without admission permission', () => {
  const f = repeatedCandidateFixture(),
    before = structuredClone(f);
  const result = qualify(f);
  assert.deepEqual(f, before);
  assert.equal(result.formatVersion, 4);
  assert.deepEqual(
    result.campaigns.map((c) => c.campaign),
    ['1', '2'],
  );
  assert.deepEqual(
    result.campaigns.map((c) => c.appliedRevision),
    ['0', '2'],
  );
  assert.deepEqual(
    result.campaigns.map((c) => c.baselinePhaseIndex),
    [0, 2],
  );
  assert.deepEqual(
    result.campaigns.map((c) => c.firstFrame),
    [600, 2400],
  );
  assert.ok(result.campaigns.every((c) => c.transport.audioInputCount === 188));
  for (const flag of [
    'receiverCapacityQualified',
    'admissionQualified',
    'recoveryQualified',
    'repeatedPolicyQualified',
    'upgradeAuthorized',
  ])
    assert.equal(result[flag], false);
});

test('retains original revisions for combined admission replay', () => {
  const f = repeatedCandidateFixture();
  for (const [index, revision] of ['4', '6'].entries()) {
    f.proof.campaigns[index].appliedRevision = revision;
    f.options.nativeProbe.campaigns[index].context.appliedRevision = revision;
  }
  assert.deepEqual(
    qualify(f).campaigns.map((c) => c.appliedRevision),
    ['4', '6'],
  );
});

const faults = {
  'legacy envelope': (f) => (f.proof.formatVersion = 3),
  'unclosed envelope': (f) => (f.proof.isClosed = false),
  'wrong campaign bound': (f) => (f.proof.maximumCampaigns = 3),
  'missing campaign': (f) => f.proof.campaigns.pop(),
  'extra campaign': (f) => f.proof.campaigns.push(structuredClone(campaign(f))),
  'crossed campaign': (f) => (campaign(f).campaign = '1'),
  'stale revision': (f) => (campaign(f).appliedRevision = '0'),
  'noncanonical revision': (f) => (campaign(f).appliedRevision = '02'),
  'measurement never started': (f) => (campaign(f).started = false),
  'crossed publication': (f) => (f.proof.scope = { ...f.options.scope, recordingID: 'other' }),
  'invalid raw probe': (f) =>
    (f.options.nativeProbe.campaigns[0].events[1].sample.acceptedPayloadBytes = '999'),
  'prequalified native summary': (f) =>
    (f.options.nativeProbe = qualifyRepeatedNativeBandwidthProbe(f.options.nativeProbe, {
      scope: f.options.scope,
      publishingGeneration: '2',
    })),
  'malformed raw media': (f) => (f.options.format.receipts[2].profile = '240p30'),
  'crossed baseline encoder': (f) =>
    (f.options.nativeProbe.campaigns[1].context.encoderSessionID =
      f.options.format.encoderSessions[1].encoderSessionID),
  'legacy measurement': (f) => (measurement(f).formatVersion = 2),
  'missing A/V cost': (f) => delete measurement(f).measurement.transport,
  'false A/V cost': (f) => measurement(f).measurement.transport.mux.transportBytes++,
  'crossed audio generation': (f) =>
    (measurement(f).measurement.transport.audio[2].publishingGeneration = '3'),
  'broken candidate source identity': (f) =>
    (measurement(f).measurement.encoding.frames[2].sourcePTS.value = '1'),
  'reused measurement identity': (f) => {
    const id = f.proof.campaigns[0].measurement.measurement.id;
    measurement(f).measurement.id =
      measurement(f).measurement.encoding.id =
      measurement(f).measurement.transport.id =
        id;
  },
  'reused candidate encoder': (f) => {
    const e = measurement(f).measurement.encoding;
    e.encoderSessionID = f.proof.campaigns[0].measurement.measurement.encoding.encoderSessionID;
    e.frames.forEach((frame) => (frame.encoderSessionID = e.encoderSessionID));
  },
  'candidate reuses live encoder': (f) => {
    const e = measurement(f).measurement.encoding;
    e.encoderSessionID = f.options.format.encoderSessions[2].encoderSessionID;
    e.frames.forEach((frame) => (frame.encoderSessionID = e.encoderSessionID));
  },
  'missing decoded candidate frame': (f) =>
    f.options.liveIDs.splice(f.options.liveIDs.indexOf(2440), 1),
  'candidate lacks native baseline frame': (f) => {
    const rows = f.options.format.compressedFrames;
    rows.splice(
      rows.findIndex(
        (row) =>
          row.sourcePTS.value === measurement(f).measurement.encoding.frames[40].sourcePTS.value,
      ),
      1,
    );
    f.options.format.frames--;
    f.options.format.phases[2].frames--;
    f.options.format.encoderSessions[2].frames--;
    f.options.snapshot.completed[0].encodedVideo.callbackCount = String(f.options.format.frames);
    f.options.format.phases[2].maximumSourceGapSeconds = 2 / 30;
    f.options.format.phases[2].maximumObservationGapSeconds = 2 / 30;
    qualifyNativeProfileTransitions(f.options.format, f.options.snapshot, f.options.liveIDs, {
      sequence: 'repeated240',
      requireFrameEvidence: true,
    });
  },
  'overlapping closed measurement': (f) =>
    (f.proof.campaigns[0].measurement.closedAt = measurement(f).measurement.startedAt + 1),
  'new publisher clock': (f) => measurement(f).publisherStartedAt++,
  'missing probe binding': (f) => delete measurement(f).probeBinding,
  'binding before final stage settling': (f) =>
    (binding(f).boundAt = binding(f).initial.observedAt = binding(f).initial.startedAt + 0.49),
  'binding after measurement starts': (f) =>
    (binding(f).boundAt = binding(f).initial.observedAt =
      measurement(f).measurement.startedAt + 0.01),
  'completion before measurement': (f) =>
    (binding(f).completedAt = measurement(f).measurement.endedAt - 0.01),
  'binding extends past closed proof': (f) =>
    (binding(f).completedAt = measurement(f).closedAt + 0.01),
  'crossed binding campaign': (f) => (binding(f).initial.campaign = '1'),
  'crossed final campaign': (f) => (binding(f).final.campaign = '1'),
  'crossed binding generation': (f) => (binding(f).initial.publishingGeneration = '1'),
  'crossed binding stage': (f) => (binding(f).initial.stage = 2),
  'crossed binding identity': (f) =>
    (binding(f).initial.id = f.options.nativeProbe.campaigns[0].events.at(-1).sample.id),
  'changed binding origin': (f) => (binding(f).initial.startedAt -= 0.01),
  'unobserved lease': (f) => (binding(f).initial.leaseDeadline += 0.01),
  'expired binding lease': (f) =>
    (binding(f).initial.observedAt = binding(f).boundAt = binding(f).initial.leaseDeadline),
  'cancelled binding': (f) => (binding(f).final.reason = 'cancelled'),
  'future accepted time': (f) =>
    (binding(f).initial.lastAcceptedAt = binding(f).initial.observedAt + 0.01),
  'fractional binding bytes': (f) => (binding(f).initial.acceptedPayloadBytes = '1.5'),
  'unaligned binding bytes': (f) => (binding(f).initial.acceptedPayloadBytes = '1317'),
  'counter exceeds native evidence': (f) => (binding(f).final.acceptedPayloadBytes = '16776568'),
  'counter precedes lease renewal': (f) => {
    binding(f).initial.acceptedPayloadBytes = '1316';
    binding(f).initial.lastAcceptedAt -= 0.1;
  },
  'final observation before candidate end': (f) =>
    (binding(f).final.observedAt = measurement(f).measurement.endedAt - 0.01),
};
for (const [name, mutate] of Object.entries(faults))
  test(`rejects ${name}`, () => {
    const f = repeatedCandidateFixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

test('rejects an invented acceptance timestamp with unchanged native bytes', () => {
  const f = repeatedCandidateFixture();
  binding(f).initial.lastAcceptedAt += 0.001;
  assert.throws(() => qualify(f));
});

test('accepts joined withdrawal after each completed candidate measurement', () => {
  const f = repeatedCandidateFixture();
  for (const native of f.options.nativeProbe.campaigns) {
    const terminal = native.events.at(-1);
    terminal.phase = 'observed';
    delete terminal.retirementRequestedAt;
    native.events.push({
      ...structuredClone(terminal),
      phase: 'final',
      observedAt: terminal.observedAt + 0.01,
    });
    native.status = 'withdrawn';
  }
  assert.equal(qualify(f).campaigns.length, 2);
});

test('rejects an interpolated binding burst beyond the current native token allowance', () => {
  const f = repeatedCandidateFixture();
  const native = f.options.nativeProbe.campaigns[1];
  for (const event of native.events.filter((event) => event.sample.stage === 3)) {
    const messages = Number(event.sample.acceptedPayloadBytes) / 1316;
    event.sample.acceptedPayloadBytes = String(messages * 90 * 1316);
    event.sample.totalAcceptedPayloadBytes = String(5264 + messages * 90 * 1316);
  }
  for (const p of [binding(f).initial, binding(f).final]) {
    p.acceptedPayloadBytes = String(Number(p.acceptedPayloadBytes) * 90);
  }
  qualifyRepeatedNativeBandwidthProbe(f.options.nativeProbe, {
    scope: f.options.scope,
    publishingGeneration: '2',
  });
  assert.equal(qualify(f).campaigns.length, 2);
  const p = binding(f).initial;
  p.acceptedPayloadBytes = String(Number(p.acceptedPayloadBytes) + 5 * 1316);
  p.lastAcceptedAt = p.observedAt + 0.00001;
  p.observedAt += 0.00002;
  binding(f).boundAt = p.observedAt;
  assert.throws(() => qualify(f));
});

function busySecondCampaign() {
  const f = repeatedCandidateFixture();
  for (const event of f.options.nativeProbe.campaigns[1].events.filter(
    (event) => event.sample.stage === 3,
  )) {
    const messages = Number(event.sample.acceptedPayloadBytes) / 1316;
    event.sample.acceptedPayloadBytes = String(messages * 90 * 1316);
    event.sample.totalAcceptedPayloadBytes = String(5264 + messages * 90 * 1316);
  }
  for (const p of [binding(f).initial, binding(f).final])
    p.acceptedPayloadBytes = String(Number(p.acceptedPayloadBytes) * 90);
  return f;
}

test('rejects a binding that leaves an impossible burst before the next native checkpoint', () => {
  const f = busySecondCampaign();
  assert.equal(qualify(f).campaigns.length, 2);
  const p = binding(f).initial;
  const next = f.options.nativeProbe.campaigns[1].events.find(
    (event) => event.sample.stage === 3 && event.sample.acceptedPayloadBytes === String(720 * 1316),
  );
  p.acceptedPayloadBytes = String(631 * 1316);
  p.lastAcceptedAt = next.sample.lastAcceptedAt - 0.00001;
  p.observedAt = binding(f).boundAt = next.sample.lastAcceptedAt;
  assert.throws(() => qualify(f));
});

test('rejects a burst between binding endpoints that individually fit every native checkpoint', () => {
  const f = busySecondCampaign();
  const p = measurement(f);
  const start = p.measurement.startedAt,
    end = p.measurement.endedAt;
  const targetStart = 178.245001,
    targetEnd = 178.245009;
  function compressTimes(value) {
    if (Array.isArray(value)) return value.forEach(compressTimes);
    if (!value || typeof value !== 'object') return;
    for (const [key, child] of Object.entries(value)) {
      if (typeof child === 'number' && key.endsWith('At') && key !== 'publisherStartedAt')
        value[key] = targetStart + ((child - start) * (targetEnd - targetStart)) / (end - start);
      else compressTimes(child);
    }
  }
  compressTimes(p);
  p.probeBinding.initial.startedAt = p.probeBinding.final.startedAt = 177.5;
  const lease = f.options.nativeProbe.campaigns[1].events.find(
    (event) => event.sample.stage === 3 && event.sample.acceptedPayloadBytes === String(630 * 1316),
  ).sample.leaseDeadline;
  Object.assign(p.probeBinding.initial, {
    acceptedPayloadBytes: String(675 * 1316),
    leaseDeadline: lease,
    lastAcceptedAt: 178.245,
    observedAt: 178.245,
  });
  Object.assign(p.probeBinding.final, {
    acceptedPayloadBytes: String(680 * 1316),
    leaseDeadline: lease,
    lastAcceptedAt: 178.24501,
    observedAt: 178.25,
  });
  p.probeBinding.boundAt = 178.245;
  p.probeBinding.completedAt = 178.25;
  p.closedAt = 178.251;
  // The existing candidate A/V validator allows fast native sampling; preserve
  // its semantics while checking the separate probe's actual acceptance clock.
  qualifyNativeCandidateMeasurement(p, {
    scope: f.options.scope,
    profile: '360p30',
    liveProfile: '240p30',
    requiredFormatVersion: 3,
    format: {
      scope: f.options.scope,
      width: 426,
      height: 240,
      firstFrame: 1800,
      lastFrame: 2699,
      publishingGeneration: '2',
    },
  });
  assert.throws(() => qualify(f), /binding endpoints/);
  // Equal counts must retain their acceptance timestamp even when neither
  // interpolated endpoint equals a raw checkpoint's count.
  p.probeBinding.final.acceptedPayloadBytes = p.probeBinding.initial.acceptedPayloadBytes;
  assert.throws(() => qualify(f), /timestamp changed without bytes/);
});

test('allows unchanged accepted bytes and timestamp while binding leases renew', () => {
  const f = repeatedCandidateFixture();
  const initial = binding(f).initial;
  const bytes = Number(initial.acceptedPayloadBytes);
  for (const event of f.options.nativeProbe.campaigns[1].events.filter(
    (event) => event.sample.stage === 3,
  )) {
    if (Number(event.sample.acceptedPayloadBytes) >= bytes) {
      event.sample.acceptedPayloadBytes = String(bytes);
      event.sample.totalAcceptedPayloadBytes = String(5264 + bytes);
      event.sample.lastAcceptedAt = initial.lastAcceptedAt;
    }
  }
  binding(f).final.acceptedPayloadBytes = String(bytes);
  binding(f).final.lastAcceptedAt = initial.lastAcceptedAt;
  assert.equal(qualify(f).campaigns.length, 2);
});
