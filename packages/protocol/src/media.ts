/** A local recording survives changes to scoring and broadcasting. */
export type RecordingStatus = 'recording' | 'stopped' | 'interrupted';
export type RecordingAssociation = {
  gameId: string;
  recordingId: string;
  deviceId: string;
  startedAt: string;
  updatedAt: string;
  status: RecordingStatus;
  sequence: number;
};
export type RecordingReport = {
  recordingId: string;
  sequence: number;
  status: RecordingStatus;
  startedAt: string;
};
export type BroadcastSelection = {
  workerId: string;
  outputId: string;
  captureDeviceId: string;
  recordingId: string;
};
export type MediaBroadcast = {
  desired: 'running' | 'stopped';
  generation: number;
  selection: BroadcastSelection | null;
};
export type MediaSnapshot = {
  gameId: string;
  recordings: RecordingAssociation[];
  broadcast: MediaBroadcast;
};
/** A start command may omit workerId/outputId: the server then picks its worker
 * (WORKER_ID/OUTPUT_ID when configured, else the one connected worker). */
export type BroadcastSelectionRequest = {
  workerId?: string | undefined;
  outputId?: string | undefined;
  captureDeviceId: string;
  recordingId: string;
};
export type BroadcastOperation =
  | { type: 'start'; selection: BroadcastSelectionRequest }
  | { type: 'stop' };
export type BroadcastCommand = {
  commandId: string;
  gameId: string;
  expectedGeneration: number;
  issuedAt: string;
  operation: BroadcastOperation;
};
export type BroadcastOutcome = {
  commandId: string;
  accepted: boolean;
  error: string | null;
  snapshot: MediaSnapshot;
};
