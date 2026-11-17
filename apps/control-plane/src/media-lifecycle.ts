export type PublishRequest = {
  gameId: string;
  deviceId: string;
  recordingId: string;
  generation: number;
  publishingAttemptId?: string;
};
export type PublishAssignment = {
  gameId: string;
  generation: number;
  recordingId: string;
  publishUrl: string;
  publishingAttemptId?: string;
};
/** What the ingest reports about the phone's feed. */
export type SourceObservation = { ready: boolean; inboundBytes: number; tracks: string[] };
export type WorkerIngestAssignment = {
  gameId: string;
  generation: number;
  readUrl: string;
  source: SourceObservation;
};
/** What the match routes need from an ingest. The hosted Worker's is `HostedMedia`. */
export type IngestLifecycle = {
  publish(request: PublishRequest): Promise<PublishAssignment>;
  worker(workerId: string): Promise<WorkerIngestAssignment | null>;
};

/** An ingest refusal with a stable, safe code. The match routes map it to an HTTP status. */
export class RelayLifecycleError extends Error {
  constructor(public readonly code: string) {
    super(code);
    this.name = 'RelayLifecycleError';
  }
}
