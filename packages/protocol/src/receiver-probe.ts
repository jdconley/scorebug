/** Relay pre-demux read accounting, not viewer delivery or available capacity.
 * Target-rate ceilings are 2 Mbps for legacy v1 and 12 Mbps for staged v2;
 * v3 repeats bounded 16 MiB campaigns with publication-wide accounting.
 * v4 explicitly supports48Mbps/64MiB campaigns; legacy bounds are unchanged.
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
    | {
        convention: 'mpegts-null-probe-v1';
        stage?: never;
        totalDeliveredPayloadBytes?: never;
        campaign?: never;
        campaignDeliveredPayloadBytes?: never;
      }
    | {
        convention: 'mpegts-null-probe-v2';
        stage: number;
        totalDeliveredPayloadBytes: string;
        campaign?: never;
        campaignDeliveredPayloadBytes?: never;
      }
    | {
        convention: 'mpegts-null-probe-v3' | 'mpegts-null-probe-v4';
        stage: number;
        totalDeliveredPayloadBytes: string;
        campaign: string;
        campaignDeliveredPayloadBytes: string;
      }
  );
/** Server-owned, attached atomically with the enclosing status.publication.
 * Age bounds snapshot creation, not last delivery; changing counters are not identity. */
export type WorkerReceiverProbe = {
  snapshot: ReceiverProbeSnapshot;
  ageUpperBoundMs: number;
};
