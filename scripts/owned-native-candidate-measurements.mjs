import assert from 'node:assert/strict';
import { qualifyOwnedNativeProbes } from './owned-native-probes.mjs';
import { qualifyRawNativeCandidateMeasurement } from './native-candidate-measurement.mjs';
import { qualifyNativeProfileTransitions } from './native-profile-transitions.mjs';
import { expandQualityEvidence } from './quality-evidence-dictionary.mjs';
import { qualifyTimingContract } from './native-timing-contract.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';

const check = (value, message) => assert.ok(value, `Owned native candidates: ${message}`);
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const time = (value) =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12;
const uint = (value) =>
  typeof value === 'string' &&
  /^(0|[1-9][0-9]{0,19})$/.test(value) &&
  BigInt(value) <= 18446744073709551615n;
function id(value) {
  check(
    typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value),
    'invalid UUID',
  );
  return value.toLowerCase();
}
const resourceLimits = Object.freeze({
  rawQueueCount: 4,
  unresolvedInputCount: 16,
  unresolvedRawBytes: 64 * 1024 * 1024,
  rawBytesPerInput: 16 * 1024 * 1024,
});
function receipt(value, generation, native = false) {
  check(object(value) && time(value.acceptedAt), 'invalid configuration receipt');
  assert.equal(
    native ? value.publishingGeneration : value.generation,
    generation,
    'Owned native candidates: receipt generation mismatch',
  );
  check([350000, 600000].includes(value.bitRate), 'unexpected receipt rate');
  const sourcePTS = native ? value.lastSubmittedSourcePTS : value.lastSubmittedPTS;
  fixtureFrameID(sourcePTS);
  return {
    configurationID: id(value.configurationID),
    encoderSessionID: id(value.encoderSessionID),
    publishingGeneration: generation,
    bitRate: value.bitRate,
    acceptedAt: value.acceptedAt,
    lastSubmittedSourcePTS: sourcePTS,
  };
}

// Validate the complete bounded control envelope and its receipt chronology.
// Pressure/advice/recovery semantics are deliberately left to policy replay.
function configurations(quality, { timingProfile, publishingGeneration, scope, format, snapshot }) {
  check(
    object(quality) && [5, 6].includes(quality.formatVersion),
    'requires original recovery quality controls',
  );
  check(
    // Same original wire bound as measuredTrialArtifacts.quality.
    Buffer.byteLength(JSON.stringify(quality)) <= 8 * 1024 * 1024,
    'quality envelope exceeds bound',
  );
  qualifyTimingContract(quality, timingProfile);
  check(
    quality.overflow === false && quality.transportPolicy === 'recovery-budget-v1',
    'incomplete quality envelope',
  );
  for (const key of [
    'measuredSourceEvaluationEnabled',
    'decoderStallEnabled',
    'deadlineFailuresEnabled',
  ])
    check(quality[key] === true, 'quality control disabled');
  const q = expandQualityEvidence(quality);
  check(
    Array.isArray(q.events) && q.events.length > 1 && q.events.length <= 512,
    'invalid quality event count',
  );
  const allowed = new Set([
    'bootstrap',
    'applied',
    'evaluated',
    'localPressure',
    'transition',
    'candidate',
    'rejected',
    'skipped',
    'stopped',
  ]);
  const configs = [],
    configurationIDs = new Set(),
    applicationIDs = new Set();
  let current,
    previousAt = snapshot.monotonicAnchor;
  for (const [eventIndex, row] of q.events.entries()) {
    check(object(row) && allowed.has(row.kind), 'unknown quality event');
    check(
      time(row.at) && row.at >= previousAt && row.at <= snapshot.captureDetachedAt + 2,
      'quality event clock outside captured publication',
    );
    check(uint(row.revision), 'invalid quality revision');
    const last = eventIndex === q.events.length - 1;
    check(
      row.closed === last && (row.kind === 'stopped') === last,
      'quality terminal boundary mismatch',
    );
    const r = receipt(row.receipt, publishingGeneration);
    check(
      time(row.acknowledgedAt) &&
        r.acceptedAt <= row.acknowledgedAt &&
        row.acknowledgedAt <= row.at,
      'invalid quality receipt chronology',
    );
    if (row.kind === 'bootstrap' || row.kind === 'applied') {
      check((row.kind === 'bootstrap') === (eventIndex === 0), 'misplaced quality bootstrap');
      check(
        row.revision === (current ? String(BigInt(current.revision) + 1n) : '0'),
        'quality revision discontinuity',
      );
      check(!configurationIDs.has(r.configurationID), 'reused configuration identity');
      configurationIDs.add(r.configurationID);
      const phaseIndex = format.encoderSessions.findIndex(
        (e) => id(e.encoderSessionID) === r.encoderSessionID,
      );
      check(
        phaseIndex >= 0 && !configs.some((c) => c.phaseIndex === phaseIndex),
        'configuration lacks distinct native phase',
      );
      const phase = format.phases[phaseIndex],
        frame = fixtureFrameID(r.lastSubmittedSourcePTS);
      check(
        row.profileID === (phase.height === 240 ? '240p30' : '360p30') &&
          r.bitRate === (phase.height === 240 ? 350000 : 600000),
        'configuration profile differs from native phase',
      );
      check(
        frame >= fixtureFrameID(phase.firstSourcePTS) &&
          frame <= fixtureFrameID(phase.lastSourcePTS),
        'configuration receipt escapes native phase',
      );
      check(
        r.acceptedAt >= phase.firstObservedAt && r.acceptedAt <= phase.lastObservedAt,
        'configuration acceptance outside native phase',
      );
      if (current) {
        check(phaseIndex === current.phaseIndex + 1, 'quality skipped native phase');
        assert.deepEqual(
          row.profileReceipt,
          format.receipts[phaseIndex - 1],
          'Owned native candidates: quality/native profile receipt mismatch',
        );
        check(
          row.profileReceipt.acknowledgedAt <= r.acceptedAt,
          'configuration accepted before native transition',
        );
        const a = row.application,
          action = row.action;
        check(object(a) && object(action), 'missing applied configuration ownership');
        check(
          id(a.attemptID) === id(scope.publishingAttemptID) && !applicationIDs.has(id(a.id)),
          'foreign/reused application',
        );
        applicationIDs.add(id(a.id));
        check(
          a.fromRevision === current.revision &&
            action.fromRevision === current.revision &&
            action.profileID === row.profileID &&
            action.bitRate === r.bitRate,
          'applied configuration revision mismatch',
        );
        check(
          time(a.admittedAt) &&
            a.admittedAt >= previousAt &&
            a.admittedAt <= r.acceptedAt &&
            a.completionDeadline === a.admittedAt + 2 &&
            row.acknowledgedAt <= a.completionDeadline,
          'invalid application receipt chronology',
        );
        check(
          time(action.validUntil) && a.admittedAt <= action.validUntil,
          'application after advice expiry',
        );
        check(a.candidateID === action.candidateID, 'applied candidate identity mismatch');
        if (a.candidateID !== null) id(a.candidateID);
      } else check(phaseIndex === 0 && row.profileID === '240p30', 'invalid bootstrap baseline');
      current = {
        revision: row.revision,
        receipt: r,
        phaseIndex,
        eventIndex,
        acknowledgedAt: row.acknowledgedAt,
        at: row.at,
        row,
      };
      configs.push(current);
    } else {
      check(
        current &&
          row.revision === current.revision &&
          row.profileID === current.row.profileID &&
          row.acknowledgedAt === current.acknowledgedAt,
        'quality event changed configuration ownership',
      );
      assert.deepEqual(
        r,
        current.receipt,
        'Owned native candidates: quality event changed receipt',
      );
      for (const key of ['profileReceipt', 'application'])
        assert.deepEqual(
          row[key],
          current.row[key],
          `Owned native candidates: quality changed ${key}`,
        );
    }
    previousAt = row.at;
  }
  check(configs.length === format.phases.length, 'quality omits native configurations');
  return configs;
}

/** Whole original owner history joined to raw completed candidate cost and
 * actual native/decoded baseline source frames. No synthetic legacy envelopes,
 * success-only histories, policy replay, or capacity/application authority. */
export function qualifyOwnedNativeCandidateMeasurements(rawOwned, options = {}) {
  check(object(options), 'invalid options');
  assert.deepEqual(
    Reflect.ownKeys(options).sort(),
    [
      'scope',
      'publishingGeneration',
      'timingProfile',
      'format',
      'snapshot',
      'liveIDs',
      'quality',
    ].sort(),
    'Owned native candidates: requires exact explicit options',
  );
  const { scope, publishingGeneration, timingProfile, format, snapshot, liveIDs, quality } =
    options;
  check(typeof timingProfile === 'string', 'missing trusted timing selection');
  const native = qualifyOwnedNativeProbes(rawOwned, { scope, publishingGeneration, timingProfile });
  assert.deepEqual(format.scope, scope, 'Owned native candidates: foreign media scope');
  assert.equal(
    format.publishingGeneration,
    publishingGeneration,
    'Owned native candidates: foreign media generation',
  );
  const media = qualifyNativeProfileTransitions(format, snapshot, liveIDs, {
    sequence: 'owned240',
    requireFrameEvidence: true,
  });
  const configs = configurations(quality, options);
  const frames = new Set(format.compressedFrames.map((f) => fixtureFrameID(f.sourcePTS))),
    decoded = new Set(liveIDs);
  const candidates = new Set(),
    encoders = new Set(format.encoderSessions.map((e) => id(e.encoderSessionID)));
  const attempts = native.attempts.map((attempt) => {
    const registration = rawOwned.events[attempt.registeredEventIndex];
    const baseline = configs.find((c) => c.revision === attempt.appliedRevision);
    check(
      baseline && baseline.row.profileID === '240p30',
      'registration lacks original baseline revision',
    );
    assert.deepEqual(
      receipt(registration.receipt, publishingGeneration, true),
      baseline.receipt,
      'Owned native candidates: registered baseline receipt mismatch',
    );
    const phase = media.phases[baseline.phaseIndex],
      rawPhase = format.phases[baseline.phaseIndex];
    const next = configs[baseline.phaseIndex + 1];
    check(
      baseline.acknowledgedAt <= registration.coreRegisteredAt &&
        (!next || registration.at < next.receipt.acceptedAt),
      'registration outside baseline configuration',
    );
    const indices = (kind) => attempt.eventIndices.filter((i) => rawOwned.events[i].kind === kind);
    const unique = (kind) => {
      const values = indices(kind);
      check(values.length <= 1, `duplicate ${kind}`);
      return values[0] ?? null;
    };
    const boundIndex = unique('candidateBound'),
      startIndex = unique('candidateStartRequested'),
      startedIndex = unique('candidateStarted'),
      joinIndex = unique('candidateJoined');
    const retiredIndex = unique('candidateRetired');
    check(
      retiredIndex !== null &&
        retiredIndex < attempt.cleanupEventIndex &&
        (joinIndex === null || retiredIndex > joinIndex) &&
        (startedIndex === null || retiredIndex > startedIndex),
      'missing or unordered candidate retirement',
    );
    const transfers = indices('applicationTransferred'),
      acknowledgements = indices('acknowledged');
    check(
      transfers.length <= 1 && acknowledgements.length <= 1,
      'duplicate candidate application event',
    );
    if (startIndex !== null)
      check(
        boundIndex !== null && boundIndex < startIndex,
        'candidate request lacks original binding',
      );
    if (startedIndex !== null)
      check(
        startIndex !== null && startIndex < startedIndex,
        'candidate start lacks original request',
      );
    let measurement = null;
    if (joinIndex !== null) {
      check(
        startedIndex !== null && startedIndex < joinIndex && joinIndex < attempt.cleanupEventIndex,
        'candidate join lacks ordered start/cleanup',
      );
      const join = rawOwned.events[joinIndex],
        start = rawOwned.events[startIndex],
        bound = rawOwned.events[boundIndex],
        m = join.measurement;
      check(
        object(m) &&
          m.reason === 'completed' &&
          m.acceptedInputCount === 121 &&
          m.encoding?.outcome === 'completed' &&
          m.encoding.failure === null &&
          m.encoding.nativeFailure === null &&
          m.encoding.acceptedInputCount === 121 &&
          m.encoding.outputCount === 121 &&
          m.encoding?.frames?.length === 121,
        'unsupported partial or failed joined candidate',
      );
      const candidateID = id(m.id),
        encoderID = id(m.encoding.encoderSessionID);
      check(
        !candidates.has(candidateID) && !encoders.has(encoderID),
        'reused candidate or live encoder identity',
      );
      candidates.add(candidateID);
      encoders.add(encoderID);
      check(
        bound.boundAt <= start.at &&
          rawPhase.firstObservedAt <= start.at &&
          join.at <= rawPhase.lastObservedAt,
        'candidate outside actual baseline phase',
      );
      measurement = qualifyRawNativeCandidateMeasurement(m, {
        scope,
        publishingGeneration,
        profile: registration.targetProfile,
        liveProfile: registration.baselineProfile,
        measurementID: m.id,
        baselineEncoderSessionID: phase.encoderSessionID,
        startedNotBefore: start.at,
        endedNotAfter: join.at,
        baselineFirstFrame: phase.firstFrame,
        baselineLastFrame: phase.lastFrame,
        resourceLimits,
      });
      for (let frame = measurement.firstFrame; frame <= measurement.lastFrame; frame++) {
        check(frames.has(frame), 'candidate source frame missing from native baseline');
        check(decoded.has(frame), 'candidate source frame missing from decoded live media');
      }
      for (const i of attempt.eventIndices) {
        const e = rawOwned.events[i];
        if (Object.hasOwn(e, 'candidateID'))
          check(id(e.candidateID) === candidateID, 'owner candidate identity mismatch');
        check(
          !Object.hasOwn(e, 'measurement') || i === joinIndex,
          'measurement outside original candidate join',
        );
      }
      for (const i of transfers) {
        check(
          i > joinIndex && id(rawOwned.events[i].candidateID) === candidateID,
          'application transfer differs from joined candidate',
        );
      }
      for (const i of acknowledgements)
        check(
          transfers.length === 1 && transfers[0] < i,
          'acknowledgement lacks joined candidate transfer',
        );
    } else {
      check(
        transfers.length === 0 && acknowledgements.length === 0,
        'application without joined candidate',
      );
      check(
        !attempt.eventIndices.some(
          (i) =>
            Object.hasOwn(rawOwned.events[i], 'measurement') ||
            Object.hasOwn(rawOwned.events[i], 'candidateID'),
        ),
        'unjoined owner carries candidate evidence',
      );
    }
    return {
      ...attempt,
      baselinePhaseIndex: baseline.phaseIndex,
      baselineQualityEventIndex: baseline.eventIndex,
      baselineEncoderSessionID: phase.encoderSessionID,
      candidateBoundEventIndex: boundIndex,
      candidateStartRequestedEventIndex: startIndex,
      candidateStartedEventIndex: startedIndex,
      candidateJoinedEventIndex: joinIndex,
      measurement,
    };
  });
  return {
    ...native,
    scope,
    publishingGeneration,
    attempts,
    candidateCostQualified: true,
    baselineMediaQualified: true,
    receiverCapacityQualified: false,
    admissionQualified: false,
    recoveryQualified: false,
    retryPolicyQualified: false,
    trialConfirmed: false,
    upgradeAuthorized: false,
  };
}
