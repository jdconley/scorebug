import assert from 'node:assert/strict';
import test from 'node:test';
import * as implementation from '../recorder-packet-timing.mjs';

function row(stage, media, pts, seconds = '0.429', index = media === 'video' ? 0 : 1) {
  const prefix = `${media[0]}${stage === 'demux' ? 'ist' : 'ost'}#0:${index}/${stage === 'demux' ? 'h264' : 'copy'}`;
  return `[${prefix} @ 0x123ab] ${stage === 'demux' ? `demuxer -> ist_index:0:${index} type:${media} pkt_pts:${pts} pkt_pts_time:${seconds} pkt_dts:${pts} pkt_dts_time:${seconds}` : `muxer <- pts:${pts} pts_time:${seconds} dts:${pts} dts_time:${seconds}`} duration:1 duration_time:0.023 size:42\n`;
}

test('retains numeric packet coordinates from chunked audio and video diagnostics', () => {
  const parser = new implementation.RecorderPacketTiming();
  const input = ['demux', 'mux']
    .flatMap((stage) => ['video', 'audio'].map((media) => row(stage, media, '429')))
    .join('');
  for (const byte of Buffer.from(input)) parser.push(Buffer.from([byte]));
  const result = parser.finish();
  assert.equal(result.recognized, true);
  assert.equal(result.formatVersion, 1);
  assert.deepEqual(result.demux.audio.first, [
    { pts: '429', ptsSeconds: '0.429', dts: '429', dtsSeconds: '0.429' },
  ]);
  assert.equal(result.mux.video.packetCount, 1);
});

test('retains eight packets per lane and counts subsequent packets without storing logs', () => {
  const parser = new implementation.RecorderPacketTiming();
  for (let i = 0; i < 10000; i++) parser.push(row('demux', 'audio', String(i)));
  const result = parser.finish();
  assert.equal(result.demux.audio.first.length, 8);
  assert.equal(result.demux.audio.packetCount, 10000);
  assert.equal(result.recognized, false);
  assert.ok(JSON.stringify(result).length < 4000);
});

test('ignores unrelated logs and reports malformed, oversized and unfinished rows without retaining secrets', () => {
  const parser = new implementation.RecorderPacketTiming();
  parser.push('rtmp://secret:password@example.com/private\n');
  parser.push(row('demux', 'audio', 'NOPTS'));
  parser.push(row('mux', 'audio', '9223372036854775808'));
  parser.push(row('mux', 'audio', '0', 'NaN'));
  parser.push('secret'.repeat(10000) + '\n');
  parser.push(row('demux', 'audio', '-1024', '-0.02322'));
  parser.push('unfinished-secret');
  const result = parser.finish();
  assert.equal(result.malformedRows, 3);
  assert.equal(result.oversizedLines, 1);
  assert.equal(result.unfinishedLine, true);
  assert.equal(result.recognized, false);
  assert.equal(result.demux.audio.first[0].pts, '-1024');
  assert.doesNotMatch(JSON.stringify(result), /secret|password|example/);
});

test('ignores corrected demux rows and rejects mismatched stream identities', () => {
  const parser = new implementation.RecorderPacketTiming();
  parser.push(row('demux', 'video', '0').replace('demuxer ->', 'demuxer+ffmpeg ->'));
  parser.push(row('demux', 'audio', '0', '0', 0));
  assert.equal(parser.finish().demux.video.packetCount, 0);
  assert.equal(parser.finish().demux.audio.packetCount, 0);
});

test('finishing is idempotent and snapshots cannot mutate retained evidence', () => {
  const parser = new implementation.RecorderPacketTiming();
  parser.push(row('demux', 'video', '0', '0'));
  const first = parser.finish();
  first.demux.video.first[0].pts = '99';
  parser.push(row('demux', 'video', '1'));
  assert.equal(parser.finish().demux.video.first[0].pts, '0');
  assert.equal(parser.finish().demux.video.packetCount, 1);
});
