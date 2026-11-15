import { expect, it } from 'vitest';
import type {
  BroadcastOperation,
  BroadcastSelection,
  MediaBroadcast,
  RecordingAssociation,
  RecordingReport,
} from '@scorebug/protocol';
import {
  applyBroadcastOperation,
  applyRecordingReport,
  MediaStateError,
} from '../src/media-state.js';

const startedAt = '2026-09-14T01:00:00.000Z';
const now = '2026-09-14T01:00:10.000Z';
const report: RecordingReport = {
  recordingId: 'recording-1',
  sequence: 0,
  status: 'recording',
  startedAt,
};
const recording: RecordingAssociation = {
  ...report,
  gameId: 'game-1',
  deviceId: 'camera-1',
  updatedAt: now,
};
const selection: BroadcastSelection = {
  workerId: 'worker-1',
  outputId: 'youtube-1',
  captureDeviceId: 'camera-1',
  recordingId: 'recording-1',
};
const stopped: MediaBroadcast = { desired: 'stopped', generation: 0, selection: null };
const start: BroadcastOperation = { type: 'start', selection };

it('associates a recording with its authenticated device and server update time', () => {
  expect(applyRecordingReport(undefined, 'game-1', 'camera-1', report, now)).toEqual(recording);
});

it.each([-1, 0.5, Number.MAX_SAFE_INTEGER + 1, Infinity, NaN])(
  'rejects invalid sequence %s',
  (sequence) => {
    expect(() =>
      applyRecordingReport(undefined, 'game-1', 'camera-1', { ...report, sequence }, now),
    ).toThrow(new MediaStateError('invalid_sequence'));
  },
);

it.each(['', 'not-a-date', '2026-09-14', '2026-02-30T01:00:00.000Z', '2026-09-14T01:00:15.001Z'])(
  'rejects invalid or excessively future start time %s',
  (time) => {
    expect(() =>
      applyRecordingReport(undefined, 'game-1', 'camera-1', { ...report, startedAt: time }, now),
    ).toThrow(new MediaStateError('invalid_started_at'));
  },
);

it('permits a start exactly five seconds ahead of the server', () => {
  const future = '2026-09-14T01:00:15.000Z';
  expect(
    applyRecordingReport(undefined, 'game-1', 'camera-1', { ...report, startedAt: future }, now)
      .startedAt,
  ).toBe(future);
});

it.each(['', 'a'.repeat(129), 'camera with spaces', '../camera', 'cámara'])(
  'rejects unsafe IDs %s',
  (id) => {
    for (const [gameId, deviceId, recordingId] of [
      [id, 'camera-1', 'recording-1'],
      ['game-1', id, 'recording-1'],
      ['game-1', 'camera-1', id],
    ]) {
      expect(() =>
        applyRecordingReport(
          undefined,
          gameId!,
          deviceId!,
          { ...report, recordingId: recordingId! },
          now,
        ),
      ).toThrow(new MediaStateError('invalid_id'));
    }
  },
);

it('rejects invalid runtime report status', () => {
  expect(() =>
    applyRecordingReport(
      undefined,
      'game-1',
      'camera-1',
      { ...report, status: 'live' } as unknown as RecordingReport,
      now,
    ),
  ).toThrow(new MediaStateError('invalid_recording_report'));
});

it('returns the original association for an exact report retry without refreshing its timestamp', () => {
  expect(
    applyRecordingReport(recording, 'game-1', 'camera-1', report, '2026-09-14T02:00:00.000Z'),
  ).toBe(recording);
});

it.each([
  ['game-2', 'camera-1', 'recording-1'],
  ['game-1', 'camera-2', 'recording-1'],
  ['game-1', 'camera-1', 'recording-2'],
])('rejects reassignment to %s %s %s even for exact retries', (gameId, deviceId, recordingId) => {
  expect(() =>
    applyRecordingReport(recording, gameId, deviceId, { ...report, recordingId }, now),
  ).toThrow(new MediaStateError('recording_ownership_mismatch'));
});

it('keeps the original start time immutable across newer reports', () => {
  expect(() =>
    applyRecordingReport(
      recording,
      'game-1',
      'camera-1',
      { ...report, sequence: 1, startedAt: now },
      now,
    ),
  ).toThrow(new MediaStateError('recording_started_at_mismatch'));
});

it('rejects changed content at the same sequence', () => {
  expect(() =>
    applyRecordingReport(recording, 'game-1', 'camera-1', { ...report, status: 'stopped' }, now),
  ).toThrow(new MediaStateError('recording_sequence_conflict'));
});

it('rejects stale reports', () => {
  expect(() =>
    applyRecordingReport(
      { ...recording, sequence: 2 },
      'game-1',
      'camera-1',
      { ...report, sequence: 1 },
      now,
    ),
  ).toThrow(new MediaStateError('stale_recording_sequence'));
});

it('updates a recording on a newer sequence without mutating the previous association', () => {
  const nextTime = '2026-09-14T02:00:00.000Z';
  const next = applyRecordingReport(
    recording,
    'game-1',
    'camera-1',
    { ...report, sequence: 3, status: 'interrupted' },
    nextTime,
  );
  expect(next).toEqual({ ...recording, sequence: 3, status: 'interrupted', updatedAt: nextTime });
  expect(recording.status).toBe('recording');
  expect(recording.updatedAt).toBe(now);
});

it('allows an interrupted recording to resume with a newer report', () => {
  expect(
    applyRecordingReport(
      { ...recording, status: 'interrupted' },
      'game-1',
      'camera-1',
      { ...report, sequence: 1 },
      now,
    ).status,
  ).toBe('recording');
});

it.each(['recording', 'interrupted'] as const)(
  'cannot move a stopped recording back to %s',
  (status) => {
    expect(() =>
      applyRecordingReport(
        { ...recording, status: 'stopped' },
        'game-1',
        'camera-1',
        { ...report, sequence: 1, status },
        now,
      ),
    ).toThrow(new MediaStateError('recording_stopped'));
  },
);

it('allows stopped recording reports to advance without resuming', () => {
  expect(
    applyRecordingReport(
      { ...recording, status: 'stopped' },
      'game-1',
      'camera-1',
      { ...report, sequence: 1, status: 'stopped' },
      now,
    ).sequence,
  ).toBe(1);
});

it('starts a selected local recording with the next broadcast generation', () => {
  const result = applyBroadcastOperation(stopped, start, [recording], 'active');
  expect(result).toEqual({ desired: 'running', generation: 1, selection });
  expect(result.selection).not.toBe(selection);
  expect(stopped).toEqual({ desired: 'stopped', generation: 0, selection: null });
});

it('stops broadcasting without ending local recording', () => {
  const running: MediaBroadcast = { desired: 'running', generation: 7, selection };
  expect(applyBroadcastOperation(running, { type: 'stop' }, [recording], 'active')).toEqual({
    desired: 'stopped',
    generation: 8,
    selection: null,
  });
  expect(recording.status).toBe('recording');
  expect(running.desired).toBe('running');
});

it('requires an explicit stop before moving a running broadcast to another worker', () => {
  const running: MediaBroadcast = { desired: 'running', generation: 7, selection };
  expect(() =>
    applyBroadcastOperation(
      running,
      { type: 'start', selection: { ...selection, workerId: 'worker-2' } },
      [recording],
      'active',
    ),
  ).toThrow(new MediaStateError('worker_move_requires_stop'));
  expect(running).toEqual({ desired: 'running', generation: 7, selection });
  expect(recording.status).toBe('recording');
});

it('permits a new output and recording on the same worker with a new generation', () => {
  const running: MediaBroadcast = { desired: 'running', generation: 7, selection };
  const nextRecording = { ...recording, recordingId: 'recording-2', deviceId: 'camera-2' };
  const nextSelection = {
    ...selection,
    outputId: 'youtube-2',
    captureDeviceId: 'camera-2',
    recordingId: 'recording-2',
  };
  expect(
    applyBroadcastOperation(
      running,
      { type: 'start', selection: nextSelection },
      [recording, nextRecording],
      'active',
    ),
  ).toEqual({ desired: 'running', generation: 8, selection: nextSelection });
});

it('permits moving to another worker after an explicit stop while recording continues', () => {
  const running: MediaBroadcast = { desired: 'running', generation: 7, selection };
  const afterStop = applyBroadcastOperation(running, { type: 'stop' }, [recording], 'active');
  const nextSelection = { ...selection, workerId: 'worker-2' };
  expect(
    applyBroadcastOperation(
      afterStop,
      { type: 'start', selection: nextSelection },
      [recording],
      'active',
    ),
  ).toEqual({ desired: 'running', generation: 9, selection: nextSelection });
  expect(recording.status).toBe('recording');
});

it('advances generation for a new stop even when already stopped or match has ended', () => {
  expect(applyBroadcastOperation(stopped, { type: 'stop' }, [], 'ended')).toEqual({
    ...stopped,
    generation: 1,
  });
});

it('rejects starting broadcast after match end', () => {
  expect(() => applyBroadcastOperation(stopped, start, [recording], 'ended')).toThrow(
    new MediaStateError('match_ended'),
  );
});

it('rejects a selected recording that does not exist', () => {
  expect(() => applyBroadcastOperation(stopped, start, [], 'active')).toThrow(
    new MediaStateError('recording_not_found'),
  );
});

it.each(['stopped', 'interrupted'] as const)('rejects selecting a %s recording', (status) => {
  expect(() =>
    applyBroadcastOperation(stopped, start, [{ ...recording, status }], 'active'),
  ).toThrow(new MediaStateError('recording_not_active'));
});

it('rejects selecting a recording owned by another capture device', () => {
  expect(() =>
    applyBroadcastOperation(
      stopped,
      { type: 'start', selection: { ...selection, captureDeviceId: 'camera-2' } },
      [recording],
      'active',
    ),
  ).toThrow(new MediaStateError('recording_device_mismatch'));
});

it.each(['workerId', 'outputId', 'captureDeviceId', 'recordingId'] as const)(
  'validates selection %s',
  (key) => {
    expect(() =>
      applyBroadcastOperation(
        stopped,
        { type: 'start', selection: { ...selection, [key]: '../unsafe' } },
        [recording],
        'active',
      ),
    ).toThrow(new MediaStateError('invalid_id'));
  },
);

it.each([-1, 1.5, Number.MAX_SAFE_INTEGER])(
  'cannot advance invalid or exhausted generation %s',
  (generation) => {
    expect(() =>
      applyBroadcastOperation({ ...stopped, generation }, { type: 'stop' }, [], 'active'),
    ).toThrow(new MediaStateError('invalid_generation'));
  },
);

it('rejects malformed runtime operations', () => {
  for (const operation of [null, {}, { type: 'start' }, { type: 'restart' }]) {
    expect(() =>
      applyBroadcastOperation(stopped, operation as BroadcastOperation, [], 'active'),
    ).toThrow(new MediaStateError('invalid_broadcast_operation'));
  }
});
