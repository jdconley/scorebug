/** Negotiated optional worker processing evidence; never utilization or viewer receipt. */
export const WORKER_PROCESSING_PROTOCOL = 'source-processing-v1';
export const WORKER_FRAME_CAP_OMISSIONS_PROTOCOL = 'tokenbucket-90k-v1';
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
  /** Exact cap-policy prediction, corroborated by encoder submissions; absent if unknown. */
  intentionalFrameCapOmissions?: number | undefined;
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
