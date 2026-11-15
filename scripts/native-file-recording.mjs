import assert from 'node:assert/strict';
import { basename } from 'node:path';
import { validateArchiveDiagnostics } from './archive-diagnostics-validation.mjs';

/** Match one decoded export to the completed draft and both joined diagnostic owners. */
export function qualifyNativeFileRecording({ recordings, exports, archive, file, videoFrames }) {
  assert(Array.isArray(recordings) && recordings.length === 1, 'Exactly one recording required');
  assert(Array.isArray(exports) && exports.length === 1, 'Exactly one export required');
  const { folder, status } = recordings[0];
  assert.equal(status.version, 1);
  const id = status.id;
  assert(typeof id === 'string' && id.length > 0 && basename(id) === id);
  assert.equal(folder, id, 'Recording folder/status identity mismatch');
  assert(
    typeof exports[0] === 'string' &&
      basename(exports[0]) === exports[0] &&
      exports[0].startsWith(`${id}-`) &&
      exports[0].endsWith('.mp4'),
    'Export does not belong to recording',
  );
  assert(
    Number.isFinite(status.createdAt) &&
      Number.isFinite(status.completedAt) &&
      status.completedAt >= status.createdAt,
    'Completed recording required',
  );
  assert.equal(status.failure, undefined);
  const shape = validateArchiveDiagnostics({ snapshot: archive, recordingID: id });
  assert.equal(archive.terminal.state, 'finished');
  assert.equal(archive.terminal.failure, undefined);
  assert.equal(archive.firstFailure, undefined);
  assert.equal(archive.coverage.persistenceComplete, true);
  assert.deepEqual(archive.validity, {
    timingValid: true,
    counterOverflow: false,
    invalidToken: false,
    invalidSequence: false,
  });
  for (const key of ['currentItems', 'currentBytes', 'rejectedCount', 'droppedCount'])
    assert.equal(archive.terminal.queue[key], '0');
  for (const key of ['audioRejected', 'videoRejected'])
    assert.equal(archive.observations[key], '0');
  assert.equal(file.formatVersion, 1);
  assert.equal(file.recordingID, id);
  const stats = file.statistics;
  assert.equal(stats.closed, true);
  const count = {};
  for (const key of ['videoFrames', 'audioSamples', 'audioBuffers', 'readCalls']) {
    assert(
      typeof stats[key] === 'string' && /^(0|[1-9][0-9]{0,18})$/.test(stats[key]),
      'Decimal source counter required',
    );
    count[key] = BigInt(stats[key]);
    assert(count[key] > 0n && count[key] <= 9223372036854775807n, 'Source counter outside Int64');
  }
  assert(Number.isSafeInteger(videoFrames) && videoFrames > 1, 'Decoded video count required');
  assert.equal(count.videoFrames, BigInt(videoFrames), 'Source/export video count mismatch');
  assert.equal(archive.observations.videoAccepted, stats.videoFrames);
  assert.equal(archive.observations.audioAccepted, stats.audioBuffers);
  assert.equal(BigInt(archive.terminal.writtenSamples), count.videoFrames + count.audioBuffers);
  assert.equal(archive.terminal.queue.acceptedCount, archive.terminal.writtenSamples);
  assert(
    count.audioSamples >= count.audioBuffers && count.audioSamples <= count.audioBuffers * 1600n,
    'Invalid delivered PCM count',
  );
  const prepared = count.readCalls - count.videoFrames - count.audioBuffers;
  assert(prepared === 0n || prepared === 1n, 'Unexpected prepared sample count');
  for (const key of [
    'totalReadSeconds',
    'maximumReadSeconds',
    'maximumSourceLagSeconds',
    'firstVideoDeliverySeconds',
    'lastVideoDeliverySeconds',
  ])
    assert(Number.isFinite(stats[key]) && stats[key] >= 0, 'Finite source timing required');
  assert(stats.totalReadSeconds >= stats.maximumReadSeconds && stats.maximumReadSeconds > 0);
  assert(stats.lastVideoDeliverySeconds > stats.firstVideoDeliverySeconds);
  return {
    recordingID: id,
    archive: shape,
    statistics: stats,
    preparedUndeliveredSamples: Number(prepared),
    averageReadSeconds: stats.totalReadSeconds / Number(count.readCalls),
    averageVideoDeliveryFramesPerSecond:
      (videoFrames - 1) / (stats.lastVideoDeliverySeconds - stats.firstVideoDeliverySeconds),
    passed: true,
  };
}
