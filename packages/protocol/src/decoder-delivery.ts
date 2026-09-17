/** Individual decoder arrivals, not viewer receipt or a qualified clock mapping.
 * Coverage begins strictly after the retained boundary. Ordinals include duplicates.
 * Negotiated authenticated reporting must bind this snapshot before native use. */
export type DecoderDeliverySnapshot = {
  formatVersion: 1;
  scopeID: string;
  coverageAgeMs: number;
  lastOrdinal: number;
  arrivals: { ordinal: number; pts: number; ageMs: number }[];
  invalidReason: string | null;
  ended: boolean;
};
export const DECODER_DELIVERY_MAX_ARRIVALS = 256;
