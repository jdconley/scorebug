import assert from 'node:assert/strict';
import test from 'node:test';
import {
  repeatedNativeProbeEvidence,
  repeatedProbeScope as scope,
} from './fixtures/repeated-probe-evidence.mjs';
const implementation = await import('../owned-native-probes.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
function fixture() {
  const events = [];
  let lastTerminal = null;
  for (const campaign of repeatedNativeProbeEvidence('retired').campaigns) {
    const context = campaign.context,
      origin = campaign.events[0].sample.startedAt;
    const base = {
      ownerID: `cccccccc-cccc-4ccc-8ccc-${campaign.campaign.padStart(12, '0')}`,
      coreRegisteredAt: origin - 0.02,
      appliedRevision: '2',
    };
    const push = (kind, at, fields = {}) => events.push({ ...base, kind, at, ...fields });
    push('registered', origin - 0.02, {
      ...context,
      appliedRevision: '2',
      policy: 'recovery-budget-v1',
      readinessValidUntil: origin + 1,
      receipt: {
        publishingGeneration: '7',
        configurationID: context.configurationID,
        encoderSessionID: context.encoderSessionID,
        bitRate: 350000,
        acceptedAt: context.acknowledgedAt,
        lastSubmittedSourcePTS: { value: '0', timescale: 30, epoch: '0', flags: 1 },
      },
    });
    push('contextRequested', origin - 0.015);
    push('contextCaptured', origin - 0.01, {
      scope,
      publishingGeneration: '7',
      receipt: events.at(-2).receipt,
    });
    let prior;
    for (const event of campaign.events) {
      const snapshot = structuredClone(event.sample);
      snapshot.policy = 'recovery-budget-v1';
      const checkedAt =
        snapshot.acceptedPayloadBytes === '0'
          ? snapshot.startedAt
          : snapshot.lastAcceptedAt - 0.001;
      snapshot.recoveryObservation = {
        checkedAt,
        sampledAt: checkedAt,
        elapsedMilliseconds: String(Math.floor(checkedAt * 1000)),
        sentBytes: snapshot.acceptedPayloadBytes,
        retransmittedBytes: '0',
        droppedPackets: 0,
        rttMilliseconds: 10,
        senderBufferMilliseconds: 0,
        senderDeliveryDelayMilliseconds: 400,
      };
      if (event.phase === 'began' || event.phase === 'replaced') {
        push('allocationRequested', snapshot.startedAt, {
          bitRate: snapshot.bitRate,
          kindOfAllocation:
            event.phase === 'replaced' ? 'replace' : lastTerminal ? 'restart' : 'begin',
          predecessor: lastTerminal,
        });
        push('allocated', event.observedAt, { snapshot });
      } else if (event.phase === 'renewed') {
        push('renewalRequested', event.observedAt - 0.002, { snapshot: prior });
        push('renewed', event.observedAt, { snapshot });
      } else {
        push('retirementRequested', event.retirementRequestedAt, { snapshot: prior });
        push('retired', event.observedAt, { snapshot });
        lastTerminal = snapshot;
      }
      prior = snapshot;
    }
    push('candidateRetired', origin + 0.72);
    push('cleanupJoined', origin + 0.73);
    push('settledFailure', origin + 0.74);
  }
  events.forEach((event, i) => {
    event.ordinal = String(i + 1);
  });
  return {
    formatVersion: 1,
    scope,
    isClosed: true,
    closedAt: 70,
    overflow: false,
    maximumAttempts: 16,
    maximumEvents: 4096,
    events,
  };
}
function qualify(raw = fixture()) {
  assert.equal(
    typeof implementation.qualifyOwnedNativeProbes,
    'function',
    'owned native probe replay must exist',
  );
  return implementation.qualifyOwnedNativeProbes(raw, { scope, publishingGeneration: '7' });
}
const samples = (raw) =>
  raw.events.filter((e) => ['allocated', 'renewed', 'retired'].includes(e.kind));
test('replays every native stage and failed same-revision restart without policy permission', () => {
  const raw = fixture(),
    before = structuredClone(raw),
    result = qualify(raw);
  assert.deepEqual(raw, before);
  assert.equal(result.nativeProbeQualified, true);
  assert.equal(result.retryPolicyQualified, false);
  assert.equal(result.receiverCapacityQualified, false);
  assert.deepEqual(
    result.attempts.map((a) => a.stages.map((s) => s.stage)),
    [
      [1, 2, 3],
      [1, 2, 3],
    ],
  );
  assert.deepEqual(
    result.attempts.map((a) => a.acceptedPayloadBytes),
    [7896, 7896],
  );
});
test('preserves failure before any native allocation', () => {
  const raw = fixture(),
    first = raw.events[0];
  raw.events.unshift(
    ...[
      'registered',
      'contextRequested',
      'failed',
      'candidateRetired',
      'cleanupJoined',
      'settledFailure',
    ].map((kind, i) => ({
      ...first,
      ownerID: 'dddddddd-dddd-4ddd-8ddd-000000000001',
      kind,
      coreRegisteredAt: 10,
      at: 10 + i / 100,
      healthySince: 5,
      healthyThrough: 9.9,
      readinessValidUntil: 11,
      receipt: { ...first.receipt, acceptedAt: 1 },
    })),
  );
  raw.events.forEach((e, i) => {
    e.ordinal = String(i + 1);
  });
  assert.equal(qualify(raw).attempts[0].stages.length, 0);
});
test('records a returned late allocation through its joined terminal snapshot', () => {
  const raw = fixture();
  const firstRetire = raw.events.findIndex((e) => e.kind === 'retired');
  raw.events[firstRetire].snapshot.leaseDeadline = raw.events[firstRetire].snapshot.startedAt + 0.3;
  raw.events.find((e) => e.kind === 'retirementRequested').snapshot = null;
  raw.events = raw.events.filter(
    (e, i) => i >= firstRetire || !['allocated', 'renewed', 'renewalRequested'].includes(e.kind),
  );
  raw.events.forEach((e, i) => {
    e.ordinal = String(i + 1);
  });
  assert.equal(qualify(raw).attempts[0].stages[0].acceptedPayloadBytes, 2632);
});
test('an awaited pre-install rejection consumes its request without inventing native retirement', () => {
  const raw = fixture(),
    base = raw.events[0];
  raw.events.unshift(
    ...[
      'registered',
      'contextRequested',
      'contextCaptured',
      'allocationRequested',
      'allocationRejected',
      'failed',
      'candidateRetired',
      'cleanupJoined',
      'settledFailure',
    ].map((kind, i) => ({
      ...base,
      kind,
      ownerID: 'dddddddd-dddd-4ddd-8ddd-000000000001',
      coreRegisteredAt: 10,
      at: 10 + i / 100,
      healthySince: 5,
      healthyThrough: 9.9,
      readinessValidUntil: 11,
      receipt: { ...base.receipt, acceptedAt: 1 },
      ...(kind === 'allocationRequested'
        ? { kindOfAllocation: 'begin', predecessor: null, bitRate: 500000 }
        : {}),
      ...(kind === 'contextCaptured' ? { scope, publishingGeneration: '7' } : {}),
      ...(kind === 'allocationRejected' ? { reason: 'obsolete' } : {}),
    })),
  );
  raw.events.forEach((e, i) => {
    e.ordinal = String(i + 1);
  });
  assert.equal(qualify(raw).attempts[0].stages.length, 0);
  const rejection = raw.events.find((e) => e.kind === 'allocationRejected');
  rejection.kind = 'failed';
  assert.throws(() => qualify(raw), /cleanup omitted native work/);
});
test('does not claim native proof when every attempt failed before allocation', () => {
  const raw = fixture();
  raw.events = raw.events.filter((e) =>
    [
      'registered',
      'contextRequested',
      'candidateRetired',
      'cleanupJoined',
      'settledFailure',
    ].includes(e.kind),
  );
  raw.events.forEach((e, i) => {
    e.ordinal = String(i + 1);
  });
  assert.throws(() => qualify(raw), /no actual native probe observations/);
});
function failedRenewalFixture(expired) {
  const raw = fixture(),
    firstOwner = raw.events[0].ownerID;
  const firstRequest = raw.events.findIndex((e) => e.kind === 'retirementRequested');
  const prefix = raw.events.slice(0, firstRequest),
    prior = prefix.at(-1).snapshot;
  const requestedAt = prior.startedAt + (expired ? 0.6 : 0.19);
  const terminal = {
    ...prior,
    reason: expired ? 'leaseExpired' : 'cancelled',
    leaseDeadline: expired ? prior.leaseDeadline : requestedAt + 0.3,
  };
  const base = prefix[0];
  const events = [
    ['renewalRequested', { snapshot: prior }],
    ['renewalRejected', { reason: 'cancelled' }],
    ['candidateRetired', {}],
    ['retirementRequested', { snapshot: prior }],
    ['retired', { snapshot: terminal }],
    ['cleanupJoined', {}],
    ['settledFailure', {}],
  ].map(([kind, fields], i) => ({ ...base, kind, at: requestedAt + i / 100, ...fields }));
  const suffix = raw.events.filter((e) => e.ownerID !== firstOwner);
  suffix.find((e) => e.kind === 'allocationRequested').predecessor = terminal;
  raw.events = [...prefix, ...events, ...suffix];
  raw.events.forEach((e, i) => {
    e.ordinal = String(i + 1);
  });
  return raw;
}
test('retains a renewal that was attempted after expiry and rejected', () => {
  const result = qualify(failedRenewalFixture(true));
  assert.equal(result.attempts[0].stages[0].terminal.reason, 'leaseExpired');
});
test('joins a rejected native renewal to its actual terminal lease advance', () => {
  const raw = failedRenewalFixture(false);
  assert.equal(qualify(raw).attempts[0].stages.length, 1);
  raw.events.find((e) => e.kind === 'renewalRejected').kind = 'failed';
  assert.throws(() => qualify(raw), /renewal completed/);
});
test('rejected renewal cannot acquire a native lease after its returned error', () => {
  const raw = failedRenewalFixture(false);
  const rejected = raw.events.find((e) => e.kind === 'renewalRejected');
  raw.events.find((e) => e.kind === 'retired').snapshot.leaseDeadline = rejected.at + 0.02 + 0.3;
  assert.throws(() => qualify(raw), /renewal revived or forged lease/);
});
test('successful renewal must prove a native renewal instant inside its call interval', () => {
  const raw = fixture();
  const first = samples(raw)[0].snapshot;
  samples(raw)[1].snapshot.leaseDeadline = first.leaseDeadline;
  assert.throws(() => qualify(raw), /renewal revived or forged lease/);
});
test('candidate binding cannot begin after exact native retirement was requested', () => {
  const raw = fixture();
  const index = raw.events.findIndex(
    (e) => e.kind === 'retirementRequested' && e.snapshot?.stage === 3,
  );
  const request = raw.events[index];
  raw.events.splice(index + 1, 0, {
    ...request,
    kind: 'candidateBound',
    at: request.at + 0.001,
    boundAt: request.at + 0.001,
  });
  raw.events.forEach((e, i) => {
    e.ordinal = String(i + 1);
  });
  assert.throws(() => qualify(raw), /candidate not bound to active final stage/);
});
test('native acceptance cannot spend old idle pacing credit in a later burst', () => {
  const raw = fixture(),
    owner = raw.events[0].ownerID;
  const first = samples(raw)[1],
    second = samples(raw)[2];
  const firstRequest = raw.events.find((e) => e.kind === 'renewalRequested');
  firstRequest.at = 30.159;
  first.at = 30.161;
  first.snapshot.leaseDeadline = 30.46;
  first.snapshot.lastAcceptedAt = 30.16;
  Object.assign(first.snapshot.recoveryObservation, {
    checkedAt: 30.159,
    sampledAt: 30.159,
    elapsedMilliseconds: '30159',
  });
  const unique = new Set(
    raw.events
      .filter((e) => e.ownerID === owner)
      .map((e) => e.snapshot)
      .filter(Boolean),
  );
  for (const snapshot of unique) {
    if (snapshot.stage >= 2)
      snapshot.totalAcceptedPayloadBytes = String(
        BigInt(snapshot.totalAcceptedPayloadBytes) + 2632n,
      );
    else if (snapshot.acceptedPayloadBytes === '2632') {
      snapshot.acceptedPayloadBytes = '5264';
      snapshot.totalAcceptedPayloadBytes = '5264';
      snapshot.recoveryObservation.sentBytes = '5264';
    }
  }
  assert.ok(Math.abs(second.snapshot.lastAcceptedAt - 30.17) < 1e-8);
  assert.throws(() => qualify(raw), /one-message token budget/);
});
const mutations = {
  foreignGeneration: (r) => {
    samples(r)[0].snapshot.publishingGeneration = '8';
  },
  foreignPolicy: (r) => {
    samples(r)[0].snapshot.policy = 'local-zero-loss-v1';
  },
  stageSkipped: (r) => {
    samples(r)[0].snapshot.stage = 2;
  },
  wrongRate: (r) => {
    samples(r)[0].snapshot.bitRate = 12000000;
  },
  invalidUUID: (r) => {
    samples(r)[0].snapshot.id = 'x';
  },
  changedUUID: (r) => {
    samples(r)[1].snapshot.id = samples(r)[4].snapshot.id;
  },
  changedCampaign: (r) => {
    samples(r)[1].snapshot.campaign = '9';
  },
  changedOrigin: (r) => {
    samples(r)[1].snapshot.campaignStartedAt += 0.01;
  },
  futureAcceptance: (r) => {
    samples(r)[1].snapshot.lastAcceptedAt = 100;
  },
  fractionalPacket: (r) => {
    samples(r)[1].snapshot.acceptedPayloadBytes = '1317';
  },
  cumulativeMismatch: (r) => {
    samples(r)[1].snapshot.totalAcceptedPayloadBytes = '2632';
  },
  initialNotEmpty: (r) => {
    samples(r)[0].snapshot.acceptedPayloadBytes = '1316';
  },
  leaseRevival: (r) => {
    samples(r)[1].snapshot.leaseDeadline += 1;
  },
  changedTerminal: (r) => {
    samples(r)[3].snapshot.reason = null;
  },
  requestWrongRate: (r) => {
    r.events.find((e) => e.kind === 'allocationRequested').bitRate = 1;
  },
  wrongContinuation: (r) => {
    r.events.find((e) => e.kind === 'allocationRequested').kindOfAllocation = 'restart';
  },
  missingPredecessor: (r) => {
    r.events.find((e) => e.kindOfAllocation === 'replace').predecessor = null;
  },
  unknownTerminal: (r) => {
    samples(r)[3].snapshot.reason = 'success';
  },
  missingRetirementRequest: (r) => {
    r.events.find((e) => e.kind === 'retirementRequested').kind = 'failed';
  },
  impossibleRecoveryCheck: (r) => {
    samples(r)[1].snapshot.recoveryObservation.checkedAt += 1;
  },
  forgedRecoveryCounter: (r) => {
    samples(r)[2].snapshot.recoveryObservation.droppedPackets = 1;
  },
  staleReadiness: (r) => {
    r.events[0].readinessValidUntil = 1;
  },
  foreignReceipt: (r) => {
    r.events[0].receipt.publishingGeneration = '8';
  },
  foreignCapturedScope: (r) => {
    r.events.find((e) => e.kind === 'contextCaptured').scope = { ...scope, matchID: 'foreign' };
  },
  foreignCapturedReceipt: (r) => {
    r.events.find((e) => e.kind === 'contextCaptured').receipt = {
      ...r.events[0].receipt,
      bitRate: 600000,
    };
  },
  prematureLeaseExpiry: (r) => {
    samples(r)[3].snapshot.reason = 'leaseExpired';
  },
  prematureTimeLimit: (r) => {
    samples(r)[3].snapshot.reason = 'timeLimit';
  },
  prematureByteLimit: (r) => {
    samples(r)[3].snapshot.reason = 'byteLimit';
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    const raw = fixture();
    mutate(raw);
    assert.throws(() => qualify(raw));
  });
