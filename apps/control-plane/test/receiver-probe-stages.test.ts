import { readFileSync } from 'node:fs';
import { expect, it } from 'vitest';
import { parseReceiverProbe } from '../src/receiver-probe.js';

const golden = (version: number) =>
  JSON.parse(
    readFileSync(
      new URL(
        `../../../packages/protocol/fixtures/receiver-probe-status-v${version}.json`,
        import.meta.url,
      ),
      'utf8',
    ),
  );
const v2 = () => golden(2).status.receiverProbe.snapshot;

it('allows bounded HD probe rates only for staged v2', () => {
  for (const bitRate of [2_000_001, 6_000_000, 12_000_000])
    expect(parseReceiverProbe({ ...v2(), bitRate })?.bitRate).toBe(bitRate);
  for (const bitRate of [0, 12_000_001, Infinity, 1.5])
    expect(parseReceiverProbe({ ...v2(), bitRate })).toBeUndefined();
  const legacy = golden(1).status.receiverProbe.snapshot;
  expect(parseReceiverProbe({ ...legacy, bitRate: 2_000_000 })).toBeDefined();
  for (const bitRate of [2_000_001, 12_000_000])
    expect(parseReceiverProbe({ ...legacy, bitRate })).toBeUndefined();
});

it('preserves the complete staged identity and cumulative accounting', () => {
  const value = v2();
  expect(parseReceiverProbe(value)).toEqual(value);
  for (const stage of [1, 32]) expect(parseReceiverProbe({ ...value, stage })?.stage).toBe(stage);
  expect(parseReceiverProbe(golden(1).status.receiverProbe.snapshot)).toEqual(
    golden(1).status.receiverProbe.snapshot,
  );
});

it.each([
  ['stage', undefined],
  ['stage', null],
  ['stage', 0],
  ['stage', 33],
  ['stage', 1.5],
  ['stage', '3'],
  ['stage', NaN],
  ['stage', Infinity],
  ['stage', 4_294_967_295],
  ['totalDeliveredPayloadBytes', undefined],
  ['totalDeliveredPayloadBytes', null],
  ['totalDeliveredPayloadBytes', 5264],
  ['totalDeliveredPayloadBytes', '05264'],
  ['totalDeliveredPayloadBytes', '+5264'],
  ['totalDeliveredPayloadBytes', '5264\n'],
  ['totalDeliveredPayloadBytes', '5265'],
  ['totalDeliveredPayloadBytes', '1316'],
  ['totalDeliveredPayloadBytes', '16777684'],
  ['totalDeliveredPayloadBytes', '18446744073709551616'],
  ['totalDeliveredPayloadBytes', '16776368'], // Pending packets cannot exceed the connection cap.
])('rejects invalid or omitted v2 %s (%s)', (field, value) => {
  expect(parseReceiverProbe({ ...v2(), [field]: value })).toBeUndefined();
});

it('accepts exactly the complete-message cap without pending packets', () => {
  expect(
    parseReceiverProbe({ ...v2(), pendingPackets: 0, totalDeliveredPayloadBytes: '16776368' }),
  ).toBeDefined();
});

it.each([
  { stage: 1 },
  { stage: null },
  { totalDeliveredPayloadBytes: '2632' },
  { totalDeliveredPayloadBytes: null },
  { stage: 1, totalDeliveredPayloadBytes: '2632' },
])('never strips staged identity from a legacy envelope: %j', (extra) => {
  expect(
    parseReceiverProbe({ ...golden(1).status.receiverProbe.snapshot, ...extra }),
  ).toBeUndefined();
});

it('preserves explicit relay invalidity in a staged diagnostic', () => {
  expect(parseReceiverProbe({ ...v2(), invalidReason: 'scope' })?.invalidReason).toBe('scope');
});

it('v4 bounds UHD campaigns without widening v1-v3', () => {
  const count = Math.floor((64 * 1024 * 1024) / 1316);
  const bytes = String(count * 1316);
  const value = {
    ...golden(3).status.receiverProbe.snapshot,
    convention: 'mpegts-null-probe-v4',
    bitRate: 48_000_000,
    campaign: '1',
    stage: 1,
    deliveredMessages: String(count),
    nextSequence: String(count),
    pendingPackets: 0,
    deliveredPayloadBytes: bytes,
    campaignDeliveredPayloadBytes: bytes,
    totalDeliveredPayloadBytes: bytes,
  };
  expect(parseReceiverProbe(value)).toEqual(value);
  for (const changed of [
    { bitRate: 48_000_001 },
    { pendingPackets: 1 },
    { campaign: undefined },
    { convention: 'mpegts-null-probe-v3', bitRate: 12_000_000 },
    { totalDeliveredPayloadBytes: String((count + 1) * 1316) },
    { campaign: '0' },
  ])
    expect(parseReceiverProbe({ ...value, ...changed })).toBeUndefined();
});
