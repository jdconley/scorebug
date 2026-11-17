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
/** What a start command selects; the server fills in its worker and output. */
export type BroadcastSelectionRequest = Pick<BroadcastSelection, 'captureDeviceId' | 'recordingId'>;
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
