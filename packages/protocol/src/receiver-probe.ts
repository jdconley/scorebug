/** Relay pre-demux read accounting, not viewer delivery or available capacity.
 * Integer strings preserve UInt64 identity on JS and watchOS arm64_32. */
export type ReceiverProbeSnapshot = {
  convention: 'mpegts-null-probe-v1';
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
/** Server-owned, attached atomically with the enclosing status.publication.
 * Age bounds snapshot creation, not last delivery; changing counters are not identity. */
export type WorkerReceiverProbe = {
  snapshot: ReceiverProbeSnapshot;
  ageUpperBoundMs: number;
};
