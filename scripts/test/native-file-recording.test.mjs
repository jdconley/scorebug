import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { qualifyNativeFileRecording } from '../native-file-recording.mjs';
const template = JSON.parse(
  await readFile(new URL('./fixtures/archive-diagnostics-swift.json', import.meta.url)),
);
function fixture() {
  const archive = structuredClone(template);
  delete archive.firstFailure;
  archive.recordingID = 'recording';
  archive.terminal.state = 'finished';
  delete archive.terminal.failure;
  archive.observations.videoAccepted = '10';
  archive.observations.audioAccepted = '20';
  archive.terminal.queue.acceptedCount = '30';
  archive.terminal.writtenSamples = '30';
  return {
    recordings: [
      {
        folder: 'recording',
        status: { version: 1, id: 'recording', createdAt: 1, completedAt: 2 },
      },
    ],
    exports: ['recording-export.mp4'],
    archive,
    videoFrames: 10,
    file: {
      formatVersion: 1,
      recordingID: 'recording',
      statistics: {
        videoFrames: '10',
        audioBuffers: '20',
        audioSamples: '16000',
        readCalls: '31',
        closed: true,
        totalReadSeconds: 0.1,
        maximumReadSeconds: 0.01,
        maximumSourceLagSeconds: 0.001,
        firstVideoDeliverySeconds: 0.001,
        lastVideoDeliverySeconds: 0.301,
      },
    },
  };
}
test('qualifies exact recording ownership and joined source counts', () => {
  const input = fixture(),
    saved = structuredClone(input);
  const report = qualifyNativeFileRecording(input);
  assert.equal(report.recordingID, 'recording');
  assert.equal(report.preparedUndeliveredSamples, 1);
  assert.equal(report.passed, true);
  assert.deepEqual(input, saved);
});
test('accepts stop with no prepared sample left', () => {
  const input = fixture();
  input.file.statistics.readCalls = '30';
  assert.equal(qualifyNativeFileRecording(input).preparedUndeliveredSamples, 0);
});
const invalid = {
  'stale export': (x) => (x.exports = ['old-export.mp4']),
  'substring-only export ownership': (x) => (x.exports = ['recording2-export.mp4']),
  'export path': (x) => (x.exports = ['../recording-export.mp4']),
  'wrong recording folder': (x) => (x.recordings[0].folder = 'other'),
  'two statuses': (x) => x.recordings.push(structuredClone(x.recordings[0])),
  'two exports': (x) => x.exports.push('recording-other.mp4'),
  'failed status': (x) => (x.recordings[0].status.failure = 'failed'),
  'missing completion': (x) => delete x.recordings[0].status.completedAt,
  'wrong file recording': (x) => (x.file.recordingID = 'other'),
  'wrong archive recording': (x) => (x.archive.recordingID = 'other'),
  'open source': (x) => (x.file.statistics.closed = false),
  'lost source frame': (x) => (x.videoFrames = 9),
  'lost archive frame': (x) => (x.archive.observations.videoAccepted = '9'),
  'audio callback loss': (x) => (x.archive.observations.audioAccepted = '19'),
  'unwritten sample': (x) => (x.archive.terminal.writtenSamples = '29'),
  'queue rejection': (x) => (x.archive.terminal.queue.rejectedCount = '1'),
  'queue loss': (x) => (x.archive.terminal.queue.droppedCount = '1'),
  'unclosed persistence': (x) => (x.archive.coverage.persistenceComplete = false),
  'invalid timings': (x) => (x.archive.validity.timingValid = false),
  'failed archive': (x) => (x.archive.terminal.state = 'failed'),
  'fractional counter': (x) => (x.file.statistics.audioSamples = '1.5'),
  'numeric counter': (x) => (x.file.statistics.videoFrames = 10),
  'overflow counter': (x) => (x.file.statistics.audioSamples = '9223372036854775808'),
  'extra prepared samples': (x) => (x.file.statistics.readCalls = '32'),
  'missing read sample': (x) => (x.file.statistics.readCalls = '29'),
  'impossible duration': (x) => (x.file.statistics.totalReadSeconds = 0.001),
  'invalid lag': (x) => (x.file.statistics.maximumSourceLagSeconds = NaN),
};
for (const [name, change] of Object.entries(invalid))
  test(`rejects ${name}`, () => {
    const input = fixture();
    change(input);
    assert.throws(() => qualifyNativeFileRecording(input));
  });
