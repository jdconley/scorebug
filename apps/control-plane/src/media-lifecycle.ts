export type PublishRequest = {
  gameId: string;
  deviceId: string;
  recordingId: string;
  generation: number;
  publishingAttemptId: string;
};
export type PublishAssignment = {
  gameId: string;
  generation: number;
  recordingId: string;
  publishUrl: string;
  publishingAttemptId: string;
};
/** Where the worker reads the phone's video: the match's Stream input. */
export type WorkerConnection = {
  gameId: string;
  generation: number;
  readUrl: string;
};
/** What the match routes need from the match's media. The hosted Worker's is `HostedMedia`. */
export type MediaLifecycle = {
  publish(request: PublishRequest): Promise<PublishAssignment>;
  worker(workerId: string): Promise<WorkerConnection | null>;
};

/** A media refusal with a stable, safe code. The match routes map it to an HTTP status. */
export class MediaLifecycleError extends Error {
  constructor(public readonly code: string) {
    super(code);
    this.name = 'MediaLifecycleError';
  }
}
