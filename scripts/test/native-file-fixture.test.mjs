import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, writeFile, readFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import {
  nativeFileFixtureOptions,
  qualifyNativeFileFixture,
  stageNativeFileFixture,
  verifyNativeFileFixtureHash,
} from '../native-file-fixture.mjs';
const environment = {
  SCOREBUG_TEST_FILE_INPUT: '/local/input.mov',
  SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
  SCOREBUG_TEST_RELAY_PUBLICATION: '1',
  SCOREBUG_TEST_WORKER_PROCESSING: '1',
};
test('file input is explicit, baseline-only and requires full-pipeline evidence', () => {
  assert.equal(
    nativeFileFixtureOptions({ environment: {}, streaming: true, holdSeconds: 12 }),
    null,
  );
  assert.deepEqual(nativeFileFixtureOptions({ environment, streaming: true, holdSeconds: 12 }), {
    path: '/local/input.mov',
    minimumDurationSeconds: 102,
    sourceOriginSeconds: 123.25,
  });
});
for (const key of [
  'SCOREBUG_TEST_MOTION_FIXTURE',
  'SCOREBUG_FIXTURE_FAIL_AFTER',
  'SCOREBUG_TEST_FILE_CAPTURE',
  'SCOREBUG_TEST_NATIVE_QUALITY',
  'SCOREBUG_TEST_NATIVE_CONFIRMATION',
  'SCOREBUG_TEST_LIVE_PROFILE',
  'SCOREBUG_TEST_PROFILE_TRANSITIONS',
  'SCOREBUG_TEST_ADAPTIVE_PROFILES',
  'SCOREBUG_TEST_SOURCE_CADENCE_PACING',
  'SCOREBUG_TEST_CANDIDATE_PROFILE',
  'SCOREBUG_TEST_CANDIDATE_HEADROOM',
  'SCOREBUG_TEST_MEASURED_TRIAL',
  'SCOREBUG_TEST_MEASURED_RECOVERY',
  'SCOREBUG_TEST_BANDWIDTH_PROBE',
  'SCOREBUG_TEST_UPLINK_PROFILE',
  'SCOREBUG_TEST_UPLINK_PROXY_PORT',
  'SCOREBUG_TEST_DECODER_STALL',
  'SCOREBUG_TEST_CADENCE_REPORTS',
  'SCOREBUG_TEST_DEADLINE_RESETS',
  'SCOREBUG_TEST_DELIVERY_DEADLINE_MS',
  'SCOREBUG_TEST_DECODER_THREADING',
  'SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS',
  'SCOREBUG_TEST_PUBLISH_PACING',
])
  test(`rejects simultaneous ${key} even when empty`, () => {
    for (const value of ['', '1'])
      assert.throws(() =>
        nativeFileFixtureOptions({
          environment: { ...environment, [key]: value },
          streaming: true,
          holdSeconds: 12,
        }),
      );
  });
test('rejects invalid paths, holds, offline mode and missing proof flags', () => {
  for (const path of ['', 'input.mov', 'https://example.com/input.mov', 1, null])
    assert.throws(() =>
      nativeFileFixtureOptions({
        environment: { ...environment, SCOREBUG_TEST_FILE_INPUT: path },
        streaming: true,
        holdSeconds: 12,
      }),
    );
  for (const holdSeconds of [0, 11, 601, 12.1, NaN, '12'])
    assert.throws(() => nativeFileFixtureOptions({ environment, streaming: true, holdSeconds }));
  assert.throws(() => nativeFileFixtureOptions({ environment, streaming: false, holdSeconds: 12 }));
  for (const key of [
    'SCOREBUG_TEST_DIRECT_RTMP_RECORDER',
    'SCOREBUG_TEST_RELAY_PUBLICATION',
    'SCOREBUG_TEST_WORKER_PROCESSING',
  ]) {
    const invalid = { ...environment };
    delete invalid[key];
    assert.throws(() =>
      nativeFileFixtureOptions({ environment: invalid, streaming: true, holdSeconds: 12 }),
    );
  }
  assert.throws(() =>
    nativeFileFixtureOptions({
      environment: { SCOREBUG_TEST_FILE_CAPTURE: '1' },
      streaming: true,
      holdSeconds: 12,
    }),
  );
});
function fixture() {
  const frames = [],
    count = 120,
    origin = 123.25;
  for (let i = 0; i < count; i++) {
    frames.push({
      media_type: 'video',
      best_effort_timestamp: 7395 + i * 2,
      best_effort_timestamp_time: String(origin + i / 30),
    });
    frames.push({
      media_type: 'audio',
      best_effort_timestamp_time: String(origin + i / 30),
      nb_samples: 1600,
    });
  }
  const bytes = Buffer.from(
    Array.from({ length: count * 16 }, (_, i) => (Math.floor(i / 16) & (1 << (i % 16)) ? 255 : 0)),
  );
  return {
    probe: {
      streams: [
        {
          codec_type: 'video',
          codec_name: 'h264',
          width: 1920,
          height: 1080,
          pix_fmt: 'yuv420p',
          color_transfer: 'bt709',
          color_space: 'bt709',
          color_primaries: 'bt709',
          avg_frame_rate: '30/1',
          time_base: '1/60',
        },
        { codec_type: 'audio', codec_name: 'pcm_s16le', sample_rate: '48000', channels: 1 },
      ],
      frames,
    },
    bytes,
    minimumDurationSeconds: 4,
  };
}
test('validates every barcode and exact rational PTS on the declared origin', () => {
  const result = qualifyNativeFileFixture(fixture());
  assert.equal(result.videoFrames, 120);
  assert.equal(result.sourceOriginSeconds, 123.25);
  assert.equal(result.audioStartSeconds, 0);
  assert.equal(result.durationSeconds, 4);
});
const invalid = {
  'wrong PTS origin': (x) => (x.probe.frames[0].best_effort_timestamp -= 60),
  'fractional frame PTS': (x) => (x.probe.frames[2].best_effort_timestamp += 1),
  'rounded timestamp disagrees': (x) => (x.probe.frames[2].best_effort_timestamp_time = '1'),
  'wrong identity': (x) => (x.bytes[16] = 0),
  'insufficient footage': (x) => (x.minimumDurationSeconds = 5),
  'HDR transfer': (x) => (x.probe.streams[0].color_transfer = 'arib-std-b67'),
  'wrong color primaries': (x) => (x.probe.streams[0].color_primaries = 'bt2020'),
  'portrait transform': (x) => (x.probe.streams[0].side_data_list = [{ rotation: 90 }]),
  'unexpected stream': (x) => x.probe.streams.push({ codec_type: 'subtitle' }),
  HEVC: (x) => (x.probe.streams[0].codec_name = 'hevc'),
  'wrong geometry': (x) => (x.probe.streams[0].width = 3840),
  'VFR declaration': (x) => (x.probe.streams[0].avg_frame_rate = '2997/100'),
  stereo: (x) => (x.probe.streams[1].channels = 2),
  'wrong sample rate': (x) => (x.probe.streams[1].sample_rate = '44100'),
  'one-millisecond PCM drift': (x) =>
    (x.probe.frames[3].best_effort_timestamp_time = String(123.25 + 1 / 30 + 0.001)),
  'audio gap': (x) => (x.probe.frames[3].best_effort_timestamp_time = '124'),
  'long audio tail': (x) => (x.probe.frames.at(-1).nb_samples = 20000),
};
for (const [name, change] of Object.entries(invalid))
  test(`rejects prepared ${name}`, () => {
    const input = fixture();
    change(input);
    assert.throws(() => qualifyNativeFileFixture(input));
  });
test('staging copies exact bytes, rejects stale/symlink inputs and never overwrites', async () => {
  const root = await mkdtemp(join(tmpdir(), 'scorebug-file-stage-'));
  try {
    const source = join(root, 'source.mov'),
      destination = join(root, 'app/QA/input.mov'),
      bytes = Buffer.from('local sample');
    await writeFile(source, bytes);
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    const result = await stageNativeFileFixture({ source, destination, sha256 });
    assert.equal(result.sha256, sha256);
    assert.deepEqual(await readFile(destination), bytes);
    assert.equal(await verifyNativeFileFixtureHash(destination, sha256), sha256);
    await assert.rejects(stageNativeFileFixture({ source, destination, sha256 }));
    assert.deepEqual(await readFile(destination), bytes);
    const link = join(root, 'linked.mov');
    await symlink(source, link);
    await assert.rejects(
      stageNativeFileFixture({ source: link, destination: join(root, 'copy.mov'), sha256 }),
    );
    await writeFile(source, 'changed');
    await assert.rejects(
      stageNativeFileFixture({ source, destination: join(root, 'changed.mov'), sha256 }),
    );
    await writeFile(destination, 'changed');
    await assert.rejects(verifyNativeFileFixtureHash(destination, sha256));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
