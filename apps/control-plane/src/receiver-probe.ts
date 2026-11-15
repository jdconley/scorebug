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
const fields = {
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
};
const snapshot = z.discriminatedUnion('convention', [
  z.object({
    ...fields,
    convention: z.literal('mpegts-null-probe-v1'),
    stage: z.never().optional(),
    totalDeliveredPayloadBytes: z.never().optional(),
    campaign: z.never().optional(),
    campaignDeliveredPayloadBytes: z.never().optional(),
  }),
  z.object({
    ...fields,
    convention: z.literal('mpegts-null-probe-v2'),
    bitRate: z.number().int().min(1).max(12_000_000),
    stage: z.number().int().min(1).max(32),
    totalDeliveredPayloadBytes: integer(16n * 1024n * 1024n),
    campaign: z.never().optional(),
    campaignDeliveredPayloadBytes: z.never().optional(),
  }),
  z.object({
    ...fields,
    convention: z.literal('mpegts-null-probe-v3'),
    bitRate: z.number().int().min(1).max(12_000_000),
    stage: z.number().int().min(1).max(32),
    campaign: integer(4_294_967_295n).refine((s) => s !== '0'),
    campaignDeliveredPayloadBytes: integer(16n * 1024n * 1024n),
    totalDeliveredPayloadBytes: integer(4_294_967_295n * 16n * 1024n * 1024n),
  }),
  z.object({
    ...fields,
    convention: z.literal('mpegts-null-probe-v4'),
    deliveredMessages: integer(BigInt(Math.floor((64 * 1024 * 1024) / 1316))),
    deliveredPayloadBytes: integer(64n * 1024n * 1024n),
    nextSequence: integer(BigInt(Math.floor((64 * 1024 * 1024) / 1316))),
    bitRate: z.number().int().min(1).max(48_000_000),
    stage: z.number().int().min(1).max(32),
    campaign: integer(4_294_967_295n).refine((s) => s !== '0'),
    campaignDeliveredPayloadBytes: integer(64n * 1024n * 1024n),
    totalDeliveredPayloadBytes: integer(4_294_967_295n * 64n * 1024n * 1024n),
  }),
]);
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
  const total =
    p.convention !== 'mpegts-null-probe-v1'
      ? BigInt(p.totalDeliveredPayloadBytes)
      : messages * 1316n;
  if (total % 1316n !== 0n || total < messages * 1316n) return undefined;
  // The relay reserves one whole message before accepting even its first packet.
  const cap = (p.convention === 'mpegts-null-probe-v4' ? 64n : 16n) * 1024n * 1024n;
  const repeated =
    p.convention === 'mpegts-null-probe-v3' || p.convention === 'mpegts-null-probe-v4';
  const campaignTotal = repeated ? BigInt(p.campaignDeliveredPayloadBytes) : total;
  if (repeated) {
    if (
      campaignTotal % 1316n !== 0n ||
      campaignTotal < messages * 1316n ||
      campaignTotal > total ||
      total - campaignTotal > (BigInt(p.campaign) - 1n) * cap ||
      (p.stage === 1 && campaignTotal !== messages * 1316n)
    )
      return undefined;
  }
  if (p.pendingPackets > 0 && campaignTotal + 1316n > cap) return undefined;
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
  const {
    firstDeliveredAtNanoseconds,
    lastDeliveredAtNanoseconds,
    invalidReason,
    stage,
    totalDeliveredPayloadBytes,
    campaign,
    campaignDeliveredPayloadBytes,
    ...required
  } = p;
  const result = {
    ...required,
    ...(firstDeliveredAtNanoseconds === undefined ? {} : { firstDeliveredAtNanoseconds }),
    ...(lastDeliveredAtNanoseconds === undefined ? {} : { lastDeliveredAtNanoseconds }),
    ...(invalidReason === undefined ? {} : { invalidReason }),
  };
  if (repeated)
    return {
      ...result,
      convention: p.convention,
      stage: p.stage,
      campaign: p.campaign,
      campaignDeliveredPayloadBytes: p.campaignDeliveredPayloadBytes,
      totalDeliveredPayloadBytes: p.totalDeliveredPayloadBytes,
    };
  return p.convention === 'mpegts-null-probe-v2'
    ? {
        ...result,
        convention: p.convention,
        stage: p.stage,
        totalDeliveredPayloadBytes: p.totalDeliveredPayloadBytes,
      }
    : { ...result, convention: p.convention };
}
