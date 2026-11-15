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
  ).status.receiverProbe.snapshot;
const v3 = () => golden(3);
const cap = 16n * 1024n * 1024n;

it('preserves v3 campaign identity and publication totals beyond the old connection cap', () => {
  expect(parseReceiverProbe(v3())).toEqual(v3());
  expect(BigInt(v3().totalDeliveredPayloadBytes)).toBeGreaterThan(cap);
});

it('retains exact UInt32 campaign and large publication counters', () => {
  const total = (((4_294_967_294n * cap + 5264n) / 1316n) * 1316n).toString();
  const value = {
    ...v3(),
    campaign: '4294967295',
    totalDeliveredPayloadBytes: total,
    pendingPackets: 0,
  };
  expect(parseReceiverProbe(value)).toEqual(value);
});

it.each([
  ['campaign', undefined],
  ['campaign', null],
  ['campaign', 2],
  ['campaign', '0'],
  ['campaign', '02'],
  ['campaign', '+2'],
  ['campaign', '2\n'],
  ['campaign', '4294967296'],
  ['campaignDeliveredPayloadBytes', undefined],
  ['campaignDeliveredPayloadBytes', null],
  ['campaignDeliveredPayloadBytes', '05264'],
  ['campaignDeliveredPayloadBytes', '5265'],
  ['campaignDeliveredPayloadBytes', '1316'],
  ['campaignDeliveredPayloadBytes', '16777684'],
  ['campaignDeliveredPayloadBytes', '16776368'],
  ['totalDeliveredPayloadBytes', '2632'],
  ['totalDeliveredPayloadBytes', '16781633'],
  ['totalDeliveredPayloadBytes', '33555000'],
  ['totalDeliveredPayloadBytes', '18446744073709551616'],
  ['stage', undefined],
  ['stage', 0],
  ['stage', 33],
  ['stage', '1'],
  ['stage', null],
  ['bitRate', 0],
  ['bitRate', 12_000_001],
])('rejects malformed v3 %s (%s)', (field, value) => {
  expect(parseReceiverProbe({ ...v3(), [field]: value })).toBeUndefined();
});

it('checks campaign and publication pending reservations separately', () => {
  const completed = '16776368';
  const full = {
    ...v3(),
    campaignDeliveredPayloadBytes: completed,
    totalDeliveredPayloadBytes: completed,
  };
  expect(parseReceiverProbe({ ...full, pendingPackets: 0 })).toBeDefined();
  expect(parseReceiverProbe({ ...full, pendingPackets: 1 })).toBeUndefined();
  expect(
    parseReceiverProbe({
      ...v3(),
      campaign: '1',
      totalDeliveredPayloadBytes: completed,
      pendingPackets: 0,
    }),
  ).toBeUndefined();
  expect(
    parseReceiverProbe({
      ...v3(),
      campaign: '1',
      totalDeliveredPayloadBytes: completed,
      pendingPackets: 1,
    }),
  ).toBeUndefined();
});

it.each([1, 2])('never strips campaign identity from a v%s snapshot', (version) => {
  for (const extra of [
    { campaign: '1' },
    { campaign: null },
    { campaignDeliveredPayloadBytes: '0' },
    { campaignDeliveredPayloadBytes: null },
    { campaign: '1', campaignDeliveredPayloadBytes: '2632' },
  ])
    expect(parseReceiverProbe({ ...golden(version), ...extra })).toBeUndefined();
  expect(parseReceiverProbe(golden(version))).toEqual(golden(version));
});

it('preserves explicit v3 diagnostic invalidity', () => {
  expect(parseReceiverProbe({ ...v3(), invalidReason: 'scope' })?.invalidReason).toBe('scope');
});

it('rejects impossible campaign and first-stage carry', () => {
  expect(parseReceiverProbe({ ...v3(), campaign: '1' })).toBeUndefined();
  expect(parseReceiverProbe({ ...v3(), stage: 1 })).toBeUndefined();
  expect(
    parseReceiverProbe({
      ...v3(),
      campaign: '1',
      stage: 1,
      campaignDeliveredPayloadBytes: '2632',
      totalDeliveredPayloadBytes: '2632',
    }),
  ).toBeDefined();
});
