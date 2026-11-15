import test from 'node:test';
import assert from 'node:assert/strict';
import { NativeWorkerEvidence } from '../native-worker-evidence.mjs';
const fixture = () => ({
  msg: 'worker_packet_timing',
  gameId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  generation: 1,
  pipelineOrdinal: 1,
  formatVersion: 1,
  diagnosticOnly: true,
  maximumPacketsPerLane: 128,
  ended: true,
  pipeError: false,
  drainTimedOut: false,
  incompleteLine: false,
  malformedRows: 0,
  oversizedLines: 0,
  stage: 'demux',
  media: 'audio',
  firstPacketIndex: 0,
  packetCount: 1,
  retainedPackets: 1,
  packets: [{ pts: '-10919', ptsSeconds: '-0.121322', dts: '-10919', dtsSeconds: '-0.121322' }],
});
function collect(record) {
  const c = new NativeWorkerEvidence();
  c.push(Buffer.from(JSON.stringify(record) + '\n'));
  c.end();
  return c.snapshot();
}
test('retains only scoped numeric worker packet timing evidence', () => {
  const raw = fixture();
  raw.secret = 'SECRET';
  raw.packets[0].url = 'rtmp://SECRET';
  const result = collect(raw);
  assert.equal(result.events.length, 1);
  assert.deepEqual(result.events[0], { sequence: 1, ...fixture() });
  assert(!JSON.stringify(result).includes('SECRET'));
});
test('retains explicit empty and failed trace lanes as unknown diagnostics', () => {
  const raw = fixture();
  Object.assign(raw, {
    packetCount: 0,
    retainedPackets: 0,
    packets: [],
    pipeError: true,
    incompleteLine: true,
  });
  assert.deepEqual(collect(raw).events[0], { sequence: 1, ...raw });
});
for (const [name, mutate] of [
  ['authority', (r) => (r.diagnosticOnly = false)],
  ['stage', (r) => (r.stage = 'SECRET')],
  ['media', (r) => (r.media = 'subtitle')],
  ['overflow', (r) => (r.packetCount = Number.MAX_SAFE_INTEGER + 1)],
  ['prefixSize', (r) => (r.retainedPackets = 2)],
  ['chunkOrdinal', (r) => (r.firstPacketIndex = 1)],
  ['missingPrefix', (r) => (r.packets = [])],
  ['unsafePTS', (r) => (r.packets[0].pts = '9223372036854775808')],
  ['noPTS', (r) => (r.packets[0].dts = '-9223372036854775808')],
  ['nonfinite', (r) => (r.packets[0].ptsSeconds = '1e999')],
  ['secretNumeric', (r) => (r.packets[0].dtsSeconds = 'rtmp://SECRET')],
  ['missingScope', (r) => delete r.gameId],
])
  test(`rejects malformed worker packet timing ${name}`, () => {
    const raw = fixture();
    mutate(raw);
    const result = collect(raw);
    assert.equal(result.events.length, 0);
    assert.equal(result.invalidLines, 1);
    assert(!JSON.stringify(result).includes('SECRET'));
  });
