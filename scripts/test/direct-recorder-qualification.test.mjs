import assert from 'node:assert/strict';
import { test } from 'node:test';

import { qualifyDirectRecorderDelivery as qualify } from '../direct-recorder-qualification.mjs';
const scope = {
  matchID: 'ab15af8f-494f-4f64-9c4c-21877e5e098c',
  broadcastGeneration: 1,
  publishingAttemptID: 'BB05440B-7C6B-453C-86DA-490BFC1CF28D',
  recordingID: '867DC886-2041-4BAE-BE39-5B708BA695E7',
  appliedProfileRevision: '1',
};
const pipelineScope = { gameId: scope.matchID, generation: 1, pipelineOrdinal: 1 };
function fixture({ sigterm = true, code = sigterm ? 255 : 0 } = {}) {
  const events = [
    { msg: 'worker_state', state: 'idle' },
    { msg: 'ffmpeg_spawning', ...pipelineScope },
    ...(sigterm ? [{ msg: 'ffmpeg_sigterm', ...pipelineScope }] : []),
    {
      msg: 'worker_pipeline_terminal',
      ...pipelineScope,
      decodedVideo: {
        acceptedFrames: 894,
        freshFrames: 894,
        duplicateFrames: 0,
        reorderedFrames: 0,
        firstPTS: 85920,
        lastPTS: 2764921,
        highestPTS: 2764921,
        timeBase: '1/90000',
        invalidReason: null,
        ended: true,
      },
      telemetryEOF: true,
      encoderExit: { code, signal: null },
      outputProgress: { frame: 894, outTimeUs: 30721344 },
    },
    { msg: 'ffmpeg_exited', ...pipelineScope, code, signal: null },
  ].map((event, i) => ({ sequence: i + 1, ...event }));
  return {
    recorder: {
      formatVersion: 1,
      readinessObserved: true,
      actualCode: 0,
      actualSignal: null,
      terminationRequested: false,
      recordingRelativePath: 'sink-recordings/direct.mp4',
    },
    workerEvidence: {
      formatVersion: 1,
      events,
      discardedLines: 1,
      invalidLines: 0,
      oversizedLines: 0,
      omittedEvents: 0,
      incompleteLine: false,
      workerError: false,
      stdoutEnded: true,
      workerExit: { code: 0, signal: null },
      fixtureSignals: ['SIGTERM'],
    },
    videoObservation: {
      formatVersion: 1,
      scope: { ...scope },
      isClosed: true,
      totals: { captureVideo: 954, encodedVideo: 954 },
      sourceRanges: {
        encodedVideo: { firstSourceFrame: 168, lastSourceFrame: 1121, sourceFrames: 954 },
      },
      uncompared: {
        acquisition: { firstSourceFrame: 168, lastSourceFrame: 227, sourceFrames: 60 },
        encodedTail: null,
      },
    },
    live: [
      {
        file: '/owned/artifact/sink-recordings/direct.mp4',
        frames: 894,
        firstSourceFrame: 228,
        lastSourceFrame: 1121,
        sourceLoss: 0,
      },
    ],
  };
}
const terminal = (value) =>
  value.workerEvidence.events.find((event) => event.msg === 'worker_pipeline_terminal');

test('qualifies complete direct receipt while explicitly retaining acquisition and SIGTERM outcome', () => {
  assert.deepEqual(qualify(fixture()), {
    formatVersion: 1,
    scope: { ...scope, pipelineOrdinal: 1 },
    savedFrames: 894,
    firstSavedSourceFrame: 228,
    lastSavedSourceFrame: 1121,
    finalEncodedSourceFrame: 1121,
    acquisition: { firstSourceFrame: 168, lastSourceFrame: 227, sourceFrames: 60 },
    encodedTail: null,
    decoder: {
      acceptedFrames: 894,
      freshFrames: 894,
      firstPTS: 85920,
      lastPTS: 2764921,
      highestPTS: 2764921,
      timeBase: '1/90000',
      telemetryEOF: true,
    },
    outputProgress: { frame: 894, outTimeUs: 30721344 },
    recorderExit: { code: 0, signal: null, terminationRequested: false },
    workerEncoderExit: { code: 255, signal: null, stop: 'sigterm' },
    workerExit: { code: 0, signal: null },
  });
});

test('qualifies an unrequested encoder exit and a stream with no acquisition gap', () => {
  const value = fixture({ sigterm: false });
  value.videoObservation.sourceRanges.encodedVideo = {
    firstSourceFrame: 228,
    lastSourceFrame: 1121,
    sourceFrames: 894,
  };
  value.videoObservation.totals.encodedVideo = 894;
  value.videoObservation.uncompared.acquisition = null;
  const result = qualify(value);
  assert.equal(result?.acquisition, null);
  assert.deepEqual(result?.workerEncoderExit, { code: 0, signal: null, stop: 'unrequested-exit' });
});

const mutations = [
  [
    'missing recorder',
    (v) => {
      delete v.recorder;
    },
  ],
  [
    'recorder not ready',
    (v) => {
      v.recorder.readinessObserved = false;
    },
  ],
  [
    'failed recorder',
    (v) => {
      v.recorder.actualCode = 1;
    },
  ],
  [
    'signaled recorder',
    (v) => {
      v.recorder.actualSignal = 'SIGTERM';
    },
  ],
  [
    'forced recorder',
    (v) => {
      v.recorder.terminationRequested = true;
    },
  ],
  [
    'different live file',
    (v) => {
      v.live[0].file = '/owned/another.mp4';
    },
  ],
  [
    'no live file',
    (v) => {
      v.live = [];
    },
  ],
  [
    'multiple live files',
    (v) => {
      v.live.push({ ...v.live[0] });
    },
  ],
  [
    'interior frame missing',
    (v) => {
      v.live[0].frames--;
    },
  ],
  [
    'source loss',
    (v) => {
      v.live[0].sourceLoss = 1;
    },
  ],
  [
    'missing final tail',
    (v) => {
      v.live[0].lastSourceFrame--;
      v.live[0].frames--;
    },
  ],
  [
    'uncompared tail',
    (v) => {
      v.videoObservation.uncompared.encodedTail = { sourceFrames: 1 };
    },
  ],
  [
    'acquisition mismatch',
    (v) => {
      v.videoObservation.uncompared.acquisition.sourceFrames--;
    },
  ],
  [
    'invalid native UUID',
    (v) => {
      v.videoObservation.scope.recordingID = 'secret';
    },
  ],
  [
    'missing native scope',
    (v) => {
      delete v.videoObservation.scope;
    },
  ],
  [
    'unclosed observation',
    (v) => {
      v.videoObservation.isClosed = false;
    },
  ],
  [
    'mismatched generation',
    (v) => {
      terminal(v).generation++;
    },
  ],
  [
    'mismatched game',
    (v) => {
      terminal(v).gameId = scope.recordingID;
    },
  ],
  [
    'multiple attempts',
    (v) => {
      v.workerEvidence.events.splice(2, 0, {
        sequence: 3,
        msg: 'ffmpeg_spawning',
        ...pipelineScope,
        pipelineOrdinal: 2,
      });
      v.workerEvidence.events.forEach((e, i) => {
        e.sequence = i + 1;
      });
    },
  ],
  [
    'missing evidence',
    (v) => {
      delete v.workerEvidence;
    },
  ],
  [
    'missing terminal',
    (v) => {
      terminal(v).msg = 'worker_state';
    },
  ],
  [
    'missing actual exit',
    (v) => {
      v.workerEvidence.events.at(-1).msg = 'worker_state';
    },
  ],
  [
    'invalid evidence',
    (v) => {
      v.workerEvidence.invalidLines++;
    },
  ],
  [
    'oversized evidence',
    (v) => {
      v.workerEvidence.oversizedLines++;
    },
  ],
  [
    'omitted evidence',
    (v) => {
      v.workerEvidence.omittedEvents++;
    },
  ],
  [
    'incomplete evidence',
    (v) => {
      v.workerEvidence.incompleteLine = true;
    },
  ],
  [
    'missing integrity counter',
    (v) => {
      delete v.workerEvidence.invalidLines;
    },
  ],
  [
    'noncontiguous evidence',
    (v) => {
      terminal(v).sequence++;
    },
  ],
  [
    'missing worker EOF',
    (v) => {
      v.workerEvidence.stdoutEnded = false;
    },
  ],
  [
    'worker error',
    (v) => {
      v.workerEvidence.workerError = true;
    },
  ],
  [
    'failed wrapper',
    (v) => {
      v.workerEvidence.workerExit.code = 1;
    },
  ],
  [
    'wrapper KILL',
    (v) => {
      v.workerEvidence.fixtureSignals.push('SIGKILL');
    },
  ],
  [
    'decoder duplicate',
    (v) => {
      terminal(v).decodedVideo.duplicateFrames++;
    },
  ],
  [
    'decoder reorder',
    (v) => {
      terminal(v).decodedVideo.reorderedFrames++;
    },
  ],
  [
    'invalid decoder',
    (v) => {
      terminal(v).decodedVideo.invalidReason = 'incomplete';
    },
  ],
  [
    'decoder not ended',
    (v) => {
      terminal(v).decodedVideo.ended = false;
    },
  ],
  [
    'missing telemetry EOF',
    (v) => {
      terminal(v).telemetryEOF = false;
    },
  ],
  [
    'unsafe PTS',
    (v) => {
      terminal(v).decodedVideo.lastPTS = Infinity;
    },
  ],
  [
    'wrong timebase',
    (v) => {
      terminal(v).decodedVideo.timeBase = '1/1000';
    },
  ],
  [
    'decoder accepted mismatch',
    (v) => {
      terminal(v).decodedVideo.acceptedFrames++;
    },
  ],
  [
    'decoder fresh mismatch',
    (v) => {
      terminal(v).decodedVideo.freshFrames--;
    },
  ],
  [
    'progress mismatch',
    (v) => {
      terminal(v).outputProgress.frame++;
    },
  ],
  [
    'missing progress',
    (v) => {
      terminal(v).outputProgress = null;
    },
  ],
  [
    'unknown encoder exit',
    (v) => {
      terminal(v).encoderExit = null;
    },
  ],
  [
    'exit disagreement',
    (v) => {
      v.workerEvidence.events.at(-1).code = 0;
    },
  ],
  [
    'unsupported encoder code',
    (v) => {
      terminal(v).encoderExit.code = 2;
      v.workerEvidence.events.at(-1).code = 2;
    },
  ],
  [
    '255 without SIGTERM',
    (v) => {
      v.workerEvidence.events[2].msg = 'worker_state';
    },
  ],
  [
    'SIGTERM scope mismatch',
    (v) => {
      v.workerEvidence.events[2].pipelineOrdinal = 2;
    },
  ],
  [
    'SIGTERM after terminal',
    (v) => {
      const e = v.workerEvidence.events;
      [e[2], e[3]] = [e[3], e[2]];
      e.forEach((event, i) => {
        event.sequence = i + 1;
      });
    },
  ],
  [
    'pipeline KILL',
    (v) => {
      v.workerEvidence.events[2].msg = 'ffmpeg_sigkill';
    },
  ],
  [
    'pipeline fault',
    (v) => {
      v.workerEvidence.events[2].msg = 'ffmpeg_guardian_lost';
    },
  ],
];
for (const [name, mutate] of mutations)
  test(`rejects ${name}`, () => {
    const value = fixture();
    mutate(value);
    assert.throws(() => qualify(value));
  });

test('returns only sanitized scalar summaries without copying unknown fields', () => {
  const value = fixture();
  value.videoObservation.scope.secret = 'SECRET';
  terminal(value).decodedVideo.secret = 'SECRET';
  terminal(value).outputProgress.secret = 'SECRET';
  value.recorder.secret = 'SECRET';
  const result = qualify(value);
  assert.ok(result);
  assert.ok(!JSON.stringify(result).includes('SECRET'));
});

function withPacketTiming({ full = false } = {}) {
  const value = fixture();
  const records = [];
  for (const stage of ['demux', 'mux'])
    for (const media of ['video', 'audio']) {
      const retainedPackets = full ? 128 : 0;
      for (
        let firstPacketIndex = 0;
        firstPacketIndex < Math.max(1, retainedPackets);
        firstPacketIndex += 8
      ) {
        records.push({
          msg: 'worker_packet_timing',
          ...pipelineScope,
          formatVersion: 1,
          diagnosticOnly: true,
          maximumPacketsPerLane: 128,
          ended: true,
          pipeError: false,
          drainTimedOut: false,
          incompleteLine: false,
          malformedRows: 0,
          oversizedLines: 0,
          stage,
          media,
          firstPacketIndex,
          packetCount: full ? 200 : 0,
          retainedPackets,
          packets: Array.from({ length: full ? 8 : 0 }, (_, i) => ({
            pts: String(firstPacketIndex + i),
            ptsSeconds: String((firstPacketIndex + i) / 30),
            dts: String(firstPacketIndex + i),
            dtsSeconds: String((firstPacketIndex + i) / 30),
          })),
        });
      }
    }
  const index = value.workerEvidence.events.findIndex((e) => e.msg === 'ffmpeg_exited');
  value.workerEvidence.events.splice(index, 0, ...records);
  value.workerEvidence.events.forEach((e, i) => (e.sequence = i + 1));
  return value;
}
for (const full of [false, true])
  test(`explicit diagnostic route retains strict delivery proof with full=${full}`, () => {
    const value = withPacketTiming({ full });
    assert.throws(() => qualify(value), /failed or forced lifecycle/);
    assert.deepEqual(qualify(value, { packetTimingDiagnostics: true }), qualify(fixture()));
  });
for (const [name, mutate] of [
  ['missingLane', (v) => v.workerEvidence.events.splice(4, 1)],
  ['wrongScope', (v) => (v.workerEvidence.events[4].pipelineOrdinal = 2)],
  [
    'earlyTrace',
    (v) => {
      const r = v.workerEvidence.events.splice(4, 1)[0];
      v.workerEvidence.events.splice(2, 0, r);
    },
  ],
  ['duplicatePrefix', (v) => (v.workerEvidence.events[5].firstPacketIndex = 0)],
  ['differentCount', (v) => (v.workerEvidence.events[5].packetCount = 201)],
  ['differentFlags', (v) => (v.workerEvidence.events[5].pipeError = true)],
  ['unsafeNumeric', (v) => (v.workerEvidence.events[4].packets[0].pts = 'SECRET')],
  [
    'unclosed',
    (v) => {
      for (const r of v.workerEvidence.events)
        if (r.msg === 'worker_packet_timing') r.ended = false;
    },
  ],
])
  test(`diagnostic route cannot ignore malformed ${name}`, () => {
    const value = withPacketTiming({ full: true });
    mutate(value);
    value.workerEvidence.events.forEach((e, i) => (e.sequence = i + 1));
    assert.throws(() => qualify(value, { packetTimingDiagnostics: true }));
  });
test('packet diagnostics never permit a forced encoder exit', () => {
  const value = withPacketTiming();
  const ex = value.workerEvidence.events.find((e) => e.msg === 'ffmpeg_exited');
  ex.code = 137;
  terminal(value).encoderExit.code = 137;
  assert.throws(() => qualify(value, { packetTimingDiagnostics: true }));
});
