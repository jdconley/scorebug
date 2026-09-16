import { z } from 'zod';
import type { ReceiverProbeSnapshot } from '@scorebug/protocol';

const integer = (maximum: bigint) =>
  z
    .string()
    .min(1)
    .max(20)
    .regex(/^(?:0|[1-9][0-9]*)$/)
    .refine((s) => {
      try {
        return BigInt(s).toString() === s && BigInt(s) <= maximum;
      } catch {
        return false;
      }
    });
const nanoseconds = integer(86_400_000_000_000n);
const snapshot = z.object({
  convention: z.literal('mpegts-null-probe-v1'),
  id: z
    .string()
    .length(36)
    .regex(/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/)
    .refine((s) => s !== '00000000-0000-0000-0000-000000000000'),
  publishingGeneration: integer(18_446_744_073_709_551_615n).refine((s) => s !== '0'),
  bitRate: z.number().int().min(1).max(2_000_000),
  deliveredMessages: integer(BigInt(Math.floor((16 * 1024 * 1024) / 1316))),
  deliveredPayloadBytes: integer(16n * 1024n * 1024n),
  nextSequence: integer(BigInt(Math.floor((16 * 1024 * 1024) / 1316))),
  pendingPackets: z.number().int().min(0).max(6),
  observedAtNanoseconds: nanoseconds,
  firstDeliveredAtNanoseconds: nanoseconds.optional(),
  lastDeliveredAtNanoseconds: nanoseconds.optional(),
  invalidReason: z
    .enum(['alignment', 'shape', 'scope', 'sequence', 'byteLimit', 'clock', 'truncated'])
    .optional(),
});
/** Optional diagnostic parsing must not make ordinary publication unavailable. */
export function parseReceiverProbe(value: unknown): ReceiverProbeSnapshot | undefined {
  const parsed = snapshot.safeParse(value);
  if (!parsed.success) return undefined;
  const p = parsed.data;
  const messages = BigInt(p.deliveredMessages);
  if (
    BigInt(p.deliveredPayloadBytes) !== messages * 1316n ||
    p.nextSequence !== p.deliveredMessages
  )
    return undefined;
  // The relay reserves one whole message before accepting even its first packet.
  if (p.pendingPackets > 0 && (messages + 1n) * 1316n > 16n * 1024n * 1024n) return undefined;
  if (messages === 0n) {
    if (p.firstDeliveredAtNanoseconds !== undefined || p.lastDeliveredAtNanoseconds !== undefined)
      return undefined;
  } else {
    if (p.firstDeliveredAtNanoseconds === undefined || p.lastDeliveredAtNanoseconds === undefined)
      return undefined;
    const first = BigInt(p.firstDeliveredAtNanoseconds),
      last = BigInt(p.lastDeliveredAtNanoseconds);
    if (
      first > last ||
      last > BigInt(p.observedAtNanoseconds) ||
      (messages === 1n && first !== last)
    )
      return undefined;
  }
  const { firstDeliveredAtNanoseconds, lastDeliveredAtNanoseconds, invalidReason, ...required } = p;
  return {
    ...required,
    ...(firstDeliveredAtNanoseconds === undefined ? {} : { firstDeliveredAtNanoseconds }),
    ...(lastDeliveredAtNanoseconds === undefined ? {} : { lastDeliveredAtNanoseconds }),
    ...(invalidReason === undefined ? {} : { invalidReason }),
  };
}
