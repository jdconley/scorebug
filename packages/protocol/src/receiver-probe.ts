/** Relay pre-demux read accounting, not viewer delivery or available capacity.
 * Integer strings preserve UInt64 identity on JS and watchOS arm64_32. */
type ReceiverProbeFields = {
  id: string;
  publishingGeneration: string;
  bitRate: number;
  deliveredMessages: string;
  deliveredPayloadBytes: string;
  nextSequence: string;
  pendingPackets: number;
  observedAtNanoseconds: string;
  firstDeliveredAtNanoseconds?: string;
  lastDeliveredAtNanoseconds?: string;
  invalidReason?:
    | 'alignment'
    | 'shape'
    | 'scope'
    | 'sequence'
    | 'byteLimit'
    | 'clock'
    | 'truncated';
};
export type ReceiverProbeSnapshot = ReceiverProbeFields &
  (
    | { convention: 'mpegts-null-probe-v1'; stage?: never; totalDeliveredPayloadBytes?: never }
    | { convention: 'mpegts-null-probe-v2'; stage: number; totalDeliveredPayloadBytes: string }
  );
/** Server-owned, attached atomically with the enclosing status.publication.
 * Age bounds snapshot creation, not last delivery; changing counters are not identity. */
export type WorkerReceiverProbe = {
  snapshot: ReceiverProbeSnapshot;
  ageUpperBoundMs: number;
};
