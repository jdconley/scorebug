/** Negotiated optional worker processing evidence; never utilization or viewer receipt. */
export const WORKER_PROCESSING_PROTOCOL = 'source-processing-v1';
export type WorkerEncoder = 'software' | 'videotoolbox' | 'nvenc';
export type WorkerObservedDuration = { meanMs: number; maximumMs: number };
export type WorkerProcessingInterval = {
  sourceStartExclusive: number;
  sourceEndInclusive: number;
  decodedFrames: number;
  submittedFrames: number;
  completedFrames: number;
  pendingFrames: number;
  omittedBeforeEncoderFrames: number;
  filterDuration: WorkerObservedDuration | null;
  processingDuration: WorkerObservedDuration | null;
};
export type WorkerProcessingReport = {
  scopeID: string;
  encoder: WorkerEncoder;
  previousSequence: number;
  sequence: number;
  firstPTS: number;
  interval: WorkerProcessingInterval;
};
