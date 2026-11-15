import assert from 'node:assert/strict';
import { sanitizeWorkerPacketTimingEvent } from './native-worker-evidence.mjs';

const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const count = (value) => Number.isSafeInteger(value) && value >= 0;
const positive = (value) => count(value) && value > 0;
const uuid = (value) =>
  typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const requireEvidence = (condition, message) => assert.ok(condition, message);
const range = (firstSourceFrame, lastSourceFrame) => ({
  firstSourceFrame,
  lastSourceFrame,
  sourceFrames: lastSourceFrame - firstSourceFrame + 1,
});

// Diagnostics remain separate from delivery counts. The explicit route validates
// every chunk, scope, prefix and terminal position before admitting its event kind.
function validatePacketTiming(pipeline, terminal, exit) {
  const rows = pipeline.filter((event) => event.msg === 'worker_packet_timing');
  const commonKeys = [
    'formatVersion',
    'diagnosticOnly',
    'maximumPacketsPerLane',
    'ended',
    'pipeError',
    'drainTimedOut',
    'incompleteLine',
    'malformedRows',
    'oversizedLines',
  ];
  let cursor = 0,
    common;
  for (const stage of ['demux', 'mux'])
    for (const media of ['video', 'audio']) {
      const first = rows[cursor];
      requireEvidence(first, 'Missing packet diagnostic lane');
      const head = sanitizeWorkerPacketTimingEvent(first);
      for (let index = 0; index < Math.max(1, head.retainedPackets); index += 8) {
        const original = rows[cursor++];
        const row = sanitizeWorkerPacketTimingEvent(original);
        requireEvidence(
          row.stage === stage && row.media === media && row.firstPacketIndex === index,
          'Packet diagnostic prefix missing, duplicated or reordered',
        );
        requireEvidence(
          row.packetCount === head.packetCount && row.retainedPackets === head.retainedPackets,
          'Packet diagnostic lane counts changed',
        );
        requireEvidence(
          row.ended && original.sequence > terminal.sequence && original.sequence < exit.sequence,
          'Packet diagnostic did not join terminal drain',
        );
        const flags = commonKeys.map((key) => row[key]);
        if (common === undefined) common = flags;
        else assert.deepEqual(flags, common, 'Packet diagnostic snapshot flags changed');
      }
    }
  requireEvidence(cursor === rows.length, 'Extra packet diagnostic chunks');
}

/** Additional direct-receiver gate after video observation and media qualification.
 * Count agreement localizes delivery after acquisition; decoder PTS is not mapped
 * to native source identity or compared with an unsynchronized host clock. */
export function qualifyDirectRecorderDelivery(
  { recorder, workerEvidence, videoObservation, live },
  { packetTimingDiagnostics = false } = {},
) {
  requireEvidence(typeof packetTimingDiagnostics === 'boolean', 'Invalid packet diagnostic mode');
  requireEvidence(
    object(recorder) && recorder.formatVersion === 1,
    'Missing direct recorder manifest',
  );
  requireEvidence(
    recorder.readinessObserved === true &&
      recorder.actualCode === 0 &&
      recorder.actualSignal === null &&
      recorder.terminationRequested === false,
    'Direct recorder must finish successfully without requested termination',
  );
  requireEvidence(
    recorder.recordingRelativePath === 'sink-recordings/direct.mp4',
    'Unexpected direct recording path',
  );
  requireEvidence(
    Array.isArray(live) && live.length === 1,
    'Direct delivery requires one live file',
  );
  const saved = live[0];
  requireEvidence(
    object(saved) &&
      typeof saved.file === 'string' &&
      saved.file.endsWith(`/${recorder.recordingRelativePath}`),
    'Live file does not match direct recorder',
  );
  requireEvidence(
    positive(saved.frames) &&
      count(saved.firstSourceFrame) &&
      count(saved.lastSourceFrame) &&
      saved.lastSourceFrame >= saved.firstSourceFrame &&
      saved.sourceLoss === 0 &&
      saved.frames === saved.lastSourceFrame - saved.firstSourceFrame + 1,
    'Saved source frames must be complete and consecutive',
  );

  requireEvidence(
    object(videoObservation) &&
      videoObservation.formatVersion === 1 &&
      videoObservation.isClosed === true &&
      object(videoObservation.scope),
    'Missing qualified native observation',
  );
  const native = videoObservation.scope;
  requireEvidence(
    uuid(native.matchID) &&
      uuid(native.recordingID) &&
      uuid(native.publishingAttemptID) &&
      positive(native.broadcastGeneration) &&
      native.appliedProfileRevision === '1',
    'Invalid native observation scope',
  );
  const encoded = videoObservation.sourceRanges?.encodedVideo;
  requireEvidence(
    object(encoded) &&
      count(encoded.firstSourceFrame) &&
      count(encoded.lastSourceFrame) &&
      positive(encoded.sourceFrames) &&
      encoded.sourceFrames === encoded.lastSourceFrame - encoded.firstSourceFrame + 1 &&
      videoObservation.totals?.encodedVideo === encoded.sourceFrames,
    'Missing complete encoded source range',
  );
  requireEvidence(
    saved.firstSourceFrame >= encoded.firstSourceFrame &&
      saved.lastSourceFrame === encoded.lastSourceFrame &&
      videoObservation.uncompared?.encodedTail === null,
    'Direct receiver must save the final encoded source frame',
  );
  const acquisition =
    saved.firstSourceFrame > encoded.firstSourceFrame
      ? range(encoded.firstSourceFrame, saved.firstSourceFrame - 1)
      : null;
  const reportedAcquisition = videoObservation.uncompared.acquisition;
  requireEvidence(
    acquisition === null
      ? reportedAcquisition === null
      : object(reportedAcquisition) &&
          ['firstSourceFrame', 'lastSourceFrame', 'sourceFrames'].every(
            (key) => reportedAcquisition[key] === acquisition[key],
          ),
    'Acquisition evidence does not match saved range',
  );

  requireEvidence(
    object(workerEvidence) && workerEvidence.formatVersion === 1,
    'Missing worker terminal evidence',
  );
  requireEvidence(
    ['invalidLines', 'oversizedLines', 'omittedEvents'].every((key) => workerEvidence[key] === 0) &&
      count(workerEvidence.discardedLines) &&
      workerEvidence.incompleteLine === false,
    'Worker evidence must be complete and valid',
  );
  requireEvidence(
    workerEvidence.workerError === false &&
      workerEvidence.stdoutEnded === true &&
      workerEvidence.workerExit?.code === 0 &&
      workerEvidence.workerExit?.signal === null,
    'Worker evidence must join successful wrapper close and stdout EOF',
  );
  requireEvidence(
    Array.isArray(workerEvidence.fixtureSignals) &&
      workerEvidence.fixtureSignals.length <= 1 &&
      workerEvidence.fixtureSignals.every((signal) => signal === 'SIGTERM'),
    'Worker wrapper must not require KILL',
  );
  const events = workerEvidence.events;
  requireEvidence(
    Array.isArray(events) &&
      events.length > 0 &&
      events.length <= 256 &&
      events.every((event, index) => object(event) && event.sequence === index + 1),
    'Worker event sequence is incomplete',
  );
  const pipeline = events.filter((event) => event.msg !== 'worker_state');
  const allowed = new Set([
    'ffmpeg_spawning',
    'ffmpeg_sigterm',
    'worker_pipeline_terminal',
    'ffmpeg_exited',
  ]);
  if (packetTimingDiagnostics) allowed.add('worker_packet_timing');
  requireEvidence(
    pipeline.every((event) => allowed.has(event.msg)),
    'Worker pipeline has a failed or forced lifecycle',
  );
  const starts = pipeline.filter((event) => event.msg === 'ffmpeg_spawning');
  const terminals = pipeline.filter((event) => event.msg === 'worker_pipeline_terminal');
  const exits = pipeline.filter((event) => event.msg === 'ffmpeg_exited');
  const stops = pipeline.filter((event) => event.msg === 'ffmpeg_sigterm');
  requireEvidence(
    starts.length === 1 && terminals.length === 1 && exits.length === 1 && stops.length <= 1,
    'Direct delivery requires one complete worker pipeline',
  );
  const start = starts[0],
    terminal = terminals[0],
    exit = exits[0];
  requireEvidence(
    positive(start.pipelineOrdinal) &&
      pipeline.every(
        (event) =>
          event.gameId === native.matchID &&
          event.generation === native.broadcastGeneration &&
          event.pipelineOrdinal === start.pipelineOrdinal,
      ),
    'Worker pipeline scope mismatch',
  );
  requireEvidence(
    events
      .filter((event) => event.msg === 'worker_state')
      .every(
        (event) =>
          (event.gameId === undefined && event.generation === undefined) ||
          (event.gameId === native.matchID && event.generation === native.broadcastGeneration),
      ),
    'Worker state scope mismatch',
  );
  requireEvidence(
    start.sequence < terminal.sequence &&
      terminal.sequence < exit.sequence &&
      stops.every((event) => event.sequence > start.sequence && event.sequence < terminal.sequence),
    'Worker lifecycle events are out of order',
  );
  if (packetTimingDiagnostics) validatePacketTiming(pipeline, terminal, exit);
  const encoderExit = terminal.encoderExit;
  requireEvidence(
    object(encoderExit) &&
      encoderExit.signal === null &&
      exit.signal === null &&
      encoderExit.code === exit.code &&
      (exit.code === 0 || (exit.code === 255 && stops.length === 1)),
    'Worker actual encoder exit must agree and be successful or an observed SIGTERM outcome',
  );
  const decoded = terminal.decodedVideo;
  requireEvidence(
    object(decoded) &&
      decoded.ended === true &&
      decoded.invalidReason === null &&
      terminal.telemetryEOF === true &&
      decoded.timeBase === '1/90000' &&
      decoded.acceptedFrames === saved.frames &&
      decoded.freshFrames === saved.frames &&
      decoded.duplicateFrames === 0 &&
      decoded.reorderedFrames === 0,
    'All fresh worker decoder frames must be saved without duplicates or reordering',
  );
  requireEvidence(
    ['firstPTS', 'lastPTS', 'highestPTS'].every((key) => Number.isSafeInteger(decoded[key])) &&
      decoded.highestPTS === decoded.lastPTS &&
      decoded.lastPTS >= decoded.firstPTS &&
      (saved.frames === 1 || decoded.lastPTS > decoded.firstPTS),
    'Invalid lifetime decoder PTS',
  );
  const progress = terminal.outputProgress;
  requireEvidence(
    object(progress) && progress.frame === saved.frames && count(progress.outTimeUs),
    'Final worker output frame count must equal saved frame count',
  );

  return {
    formatVersion: 1,
    scope: {
      matchID: native.matchID,
      broadcastGeneration: native.broadcastGeneration,
      publishingAttemptID: native.publishingAttemptID,
      recordingID: native.recordingID,
      appliedProfileRevision: native.appliedProfileRevision,
      pipelineOrdinal: start.pipelineOrdinal,
    },
    savedFrames: saved.frames,
    firstSavedSourceFrame: saved.firstSourceFrame,
    lastSavedSourceFrame: saved.lastSourceFrame,
    finalEncodedSourceFrame: encoded.lastSourceFrame,
    acquisition,
    encodedTail: null,
    decoder: {
      acceptedFrames: decoded.acceptedFrames,
      freshFrames: decoded.freshFrames,
      firstPTS: decoded.firstPTS,
      lastPTS: decoded.lastPTS,
      highestPTS: decoded.highestPTS,
      timeBase: '1/90000',
      telemetryEOF: true,
    },
    outputProgress: { frame: progress.frame, outTimeUs: progress.outTimeUs },
    recorderExit: { code: 0, signal: null, terminationRequested: false },
    workerEncoderExit: {
      code: encoderExit.code,
      signal: null,
      stop: stops.length ? 'sigterm' : 'unrequested-exit',
    },
    workerExit: { code: 0, signal: null },
  };
}
