import type {
  BroadcastOperation,
  BroadcastSelection,
  MediaBroadcast,
  RecordingAssociation,
  RecordingReport,
} from '@scorebug/protocol';

export class MediaStateError extends Error {
  constructor(public readonly code: string) {
    super(code);
    this.name = 'MediaStateError';
  }
}

function validateId(value: unknown): asserts value is string {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(value)) {
    throw new MediaStateError('invalid_id');
  }
}

/** Require a full timestamp with an explicit zone and a real calendar date. */
function isoTime(value: unknown): number {
  if (
    typeof value !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/.test(
      value,
    )
  )
    return NaN;
  const calendar = new Date(`${value.slice(0, 19)}Z`);
  if (
    !Number.isFinite(calendar.getTime()) ||
    calendar.toISOString().slice(0, 19) !== value.slice(0, 19)
  ) {
    return NaN;
  }
  return Date.parse(value);
}

export function applyRecordingReport(
  existing: RecordingAssociation | undefined,
  gameId: string,
  deviceId: string,
  report: RecordingReport,
  serverNowISO: string,
): RecordingAssociation {
  validateId(gameId);
  validateId(deviceId);
  if (
    !report ||
    typeof report !== 'object' ||
    !['recording', 'stopped', 'interrupted'].includes(report.status)
  ) {
    throw new MediaStateError('invalid_recording_report');
  }
  validateId(report.recordingId);
  if (!Number.isSafeInteger(report.sequence) || report.sequence < 0) {
    throw new MediaStateError('invalid_sequence');
  }
  const startTime = isoTime(report.startedAt);
  const serverTime = isoTime(serverNowISO);
  if (
    !Number.isFinite(startTime) ||
    !Number.isFinite(serverTime) ||
    startTime > serverTime + 5_000
  ) {
    throw new MediaStateError('invalid_started_at');
  }
  if (existing) {
    if (
      existing.gameId !== gameId ||
      existing.deviceId !== deviceId ||
      existing.recordingId !== report.recordingId
    ) {
      throw new MediaStateError('recording_ownership_mismatch');
    }
    if (existing.startedAt !== report.startedAt) {
      throw new MediaStateError('recording_started_at_mismatch');
    }
    if (report.sequence < existing.sequence) {
      throw new MediaStateError('stale_recording_sequence');
    }
    if (report.sequence === existing.sequence) {
      if (report.status !== existing.status)
        throw new MediaStateError('recording_sequence_conflict');
      return existing;
    }
    if (existing.status === 'stopped' && report.status !== 'stopped') {
      throw new MediaStateError('recording_stopped');
    }
  }
  return {
    gameId,
    deviceId,
    recordingId: report.recordingId,
    startedAt: report.startedAt,
    updatedAt: serverNowISO,
    status: report.status,
    sequence: report.sequence,
  };
}

export function applyBroadcastOperation(
  current: MediaBroadcast,
  operation: BroadcastOperation,
  worker: Pick<BroadcastSelection, 'workerId' | 'outputId'>,
  recordings: RecordingAssociation[],
  matchStatus: 'active' | 'ended',
): MediaBroadcast {
  if (!operation || typeof operation !== 'object' || !['start', 'stop'].includes(operation.type)) {
    throw new MediaStateError('invalid_broadcast_operation');
  }
  if (
    !Number.isSafeInteger(current.generation) ||
    current.generation < 0 ||
    current.generation >= Number.MAX_SAFE_INTEGER
  ) {
    throw new MediaStateError('invalid_generation');
  }
  const generation = current.generation + 1;
  if (operation.type === 'stop') return { desired: 'stopped', generation, selection: null };
  const selection = operation.selection;
  if (!selection || typeof selection !== 'object')
    throw new MediaStateError('invalid_broadcast_operation');
  validateId(selection.captureDeviceId);
  validateId(selection.recordingId);
  if (matchStatus !== 'active') throw new MediaStateError('match_ended');
  const recording = recordings.find((candidate) => candidate.recordingId === selection.recordingId);
  if (!recording) throw new MediaStateError('recording_not_found');
  if (recording.deviceId !== selection.captureDeviceId)
    throw new MediaStateError('recording_device_mismatch');
  if (recording.status !== 'recording') throw new MediaStateError('recording_not_active');
  return {
    desired: 'running',
    generation,
    selection: {
      workerId: worker.workerId,
      outputId: worker.outputId,
      captureDeviceId: selection.captureDeviceId,
      recordingId: selection.recordingId,
    },
  };
}
