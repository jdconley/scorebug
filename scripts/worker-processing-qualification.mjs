import assert from 'node:assert/strict';
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const keys = [
  'sourceStartExclusive',
  'sourceEndInclusive',
  'decodedFrames',
  'submittedFrames',
  'completedFrames',
  'pendingFrames',
  'omittedBeforeEncoderFrames',
];
function processing(value) {
  assert(value && typeof value.scopeID === 'string' && uuid.test(value.scopeID));
  assert(['software', 'videotoolbox', 'nvenc'].includes(value.encoder));
  const result = { scopeID: value.scopeID, encoder: value.encoder };
  for (const key of ['previousSequence', 'sequence', 'firstPTS']) {
    assert(Number.isSafeInteger(value[key]));
    result[key] = value[key];
  }
  result.interval = {};
  for (const key of keys) {
    assert(Number.isSafeInteger(value.interval?.[key]));
    result.interval[key] = value.interval[key];
  }
  for (const key of ['filterDuration', 'processingDuration']) {
    const d = value.interval[key];
    assert(
      d === null ||
        (d &&
          Number.isFinite(d.meanMs) &&
          Number.isFinite(d.maximumMs) &&
          d.meanMs >= 0 &&
          d.maximumMs >= d.meanMs &&
          d.maximumMs <= Number.MAX_SAFE_INTEGER),
    );
    result.interval[key] = d === null ? null : { meanMs: d.meanMs, maximumMs: d.maximumMs };
  }
  const i = result.interval;
  assert(result.sequence >= 2 && result.previousSequence === result.sequence - 1);
  assert(i.sourceStartExclusive < result.firstPTS && result.firstPTS <= i.sourceEndInclusive);
  for (const key of keys.slice(2)) assert(i[key] >= 0);
  assert(i.submittedFrames <= i.decodedFrames && i.completedFrames <= i.submittedFrames);
  assert(
    i.pendingFrames === i.submittedFrames - i.completedFrames &&
      i.omittedBeforeEncoderFrames === i.decodedFrames - i.submittedFrames,
  );
  assert(i.pendingFrames === 0 || i.processingDuration === null);
  assert(i.submittedFrames > 0 || (i.filterDuration === null && i.processingDuration === null));
  return result;
}
/** Only allowlisted public scalar evidence is retained; omissions never resurrect current status. */
export function recordWorkerProcessingEvidence(history, status, limit = 64) {
  if (status.state !== 'producing_output' || !status.observation?.processing || !status.publication)
    return;
  const o = status.observation,
    p = processing(o.processing),
    publication = status.publication;
  assert(history instanceof Map);
  assert(
    typeof status.gameId === 'string' &&
      status.gameId.length > 0 &&
      status.gameId.length <= 128 &&
      /^[A-Za-z0-9_-]+$/.test(status.gameId),
  );
  assert(
    typeof status.workerId === 'string' &&
      status.workerId.length > 0 &&
      status.workerId.length <= 128 &&
      /^[A-Za-z0-9_-]+$/.test(status.workerId),
  );
  assert(Number.isSafeInteger(status.generation) && status.generation > 0);
  assert(o.state === status.state);
  for (const id of [publication.readerId, publication.publisherId, publication.publishingAttemptId])
    assert(typeof id === 'string' && uuid.test(id));
  assert(publication.readerId !== publication.publisherId);
  assert(publication.clock?.convention === 'mpegts-ingress-origin-90k-v1');
  const origin = publication.clock.originPTS;
  assert(
    typeof origin === 'string' &&
      origin.length <= 10 &&
      /^(0|[1-9][0-9]*)$/.test(origin) &&
      Number(origin) < 2 ** 33,
  );
  assert(Number.isSafeInteger(o.attempt) && o.attempt > 0);
  assert(typeof status.workerEpoch === 'string' && uuid.test(status.workerEpoch));
  assert(o.gameId === status.gameId && o.generation === status.generation);
  assert(
    o.decodedVideo?.completed?.sequence === p.sequence &&
      !o.decodedVideo.ended &&
      o.decodedVideo.invalidReason === null,
  );
  const window = o.decodedVideo.completed;
  assert(
    o.decodedVideo.clock === 'mpegts-pts-90k-v1' &&
      window.valid &&
      window.duplicateFrames === 0 &&
      window.reorderedFrames === 0,
  );
  assert(
    window.firstPTS === p.firstPTS &&
      window.lastPTS === p.interval.sourceEndInclusive &&
      window.freshFrames === p.interval.decodedFrames,
  );
  assert(Number.isSafeInteger(limit) && limit > 0 && limit <= 128);
  const sample = {
    gameId: status.gameId,
    generation: status.generation,
    workerId: status.workerId,
    workerEpoch: status.workerEpoch,
    attempt: o.attempt,
    publication: {
      readerId: publication.readerId,
      publisherId: publication.publisherId,
      publishingAttemptId: publication.publishingAttemptId,
      clock: { convention: publication.clock.convention, originPTS: publication.clock.originPTS },
    },
    processing: p,
  };
  const key = `${status.workerEpoch}/${o.attempt}/${p.sequence}`;
  assert(history.has(key) || history.size < limit, 'Processing evidence exceeded fixture bound');
  history.set(key, sample);
}
/** Finite 30 fps native fixture only; source intervals and saved video identities are qualified first. */
export function qualifyWorkerProcessingReports({
  snapshot,
  sourceIntervalQualification,
  processingEvidence,
  encoder = 'videotoolbox',
}) {
  assert(Array.isArray(processingEvidence) && processingEvidence.length <= 128);
  const completed = [];
  let scope;
  for (const row of snapshot.sourceIntervals) {
    if (!row.processing) continue;
    const p = processing(row.processing),
      i = p.interval;
    const source = sourceIntervalQualification.intervals.find(
      (v) => v.sequence === Number(row.sequence),
    );
    assert(source, 'Processing lacks independently qualified native source interval');
    const api = processingEvidence.find(
      (v) =>
        v.workerEpoch === row.workerEpoch &&
        v.attempt === row.workerAttempt &&
        v.processing.sequence === p.sequence,
    );
    assert(api, 'Native processing lacks independent API evidence');
    assert.equal(api.gameId, snapshot.scope.matchID);
    assert.equal(api.generation, snapshot.scope.broadcastGeneration);
    assert.equal(api.workerId, row.workerId);
    assert.deepEqual(api.publication, row.publication);
    assert.equal(p.encoder, encoder);
    scope ??= p.scopeID;
    assert.equal(p.scopeID, scope);
    assert.equal(p.sequence, source.sequence);
    assert.equal(p.previousSequence, source.previousSequence);
    assert.equal(p.firstPTS, Number(row.firstDecodedPTS));
    assert.equal(i.sourceStartExclusive, Number(row.previousDecodedPTS));
    assert.equal(i.sourceEndInclusive, Number(row.lastDecodedPTS));
    assert.equal(i.decodedFrames, source.decodedFrames);
    assert.equal(i.submittedFrames, source.decodedFrames);
    assert.equal(i.omittedBeforeEncoderFrames, 0);
    assert(i.completedFrames >= 0 && i.completedFrames <= i.submittedFrames);
    assert.equal(i.pendingFrames, i.submittedFrames - i.completedFrames);
    assert(i.pendingFrames === 0 || i.processingDuration === null);
    const remote = processing(api.processing);
    const stable = (v) => ({
      ...v,
      interval: { ...v.interval, completedFrames: 0, pendingFrames: 0, processingDuration: null },
    });
    assert.deepEqual(
      stable(p),
      stable(remote),
      'Native/API processing source identity or filter timing differs',
    );
    if (i.pendingFrames === 0 && remote.interval.pendingFrames === 0) {
      assert.deepEqual(p, remote, 'Completed native/API processing differs');
      completed.push({
        sequence: p.sequence,
        decodedFrames: i.decodedFrames,
        completedFrames: i.completedFrames,
      });
    }
  }
  assert(completed.length >= 2, 'Need two complete native/API processing windows');
  return {
    scopeID: scope,
    encoder,
    completed,
    scope:
      'Historical API/native correspondence and saved output identity; not fresh health, spare capacity or sustained qualification.',
  };
}
