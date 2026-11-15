import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { command, mediaTools } from './media-tools.mjs';
import { cancellation } from './cancellation.mjs';
import {
  sourceFrameCodeFilter,
  frameCodeReadFilter,
  decodeFrameCodes,
} from './media-frame-codes.mjs';
import {
  sourceAudioExpression,
  analyzeMediaSync,
  assertMediaSync,
  assertMediaCoverage,
} from './media-sync.mjs';
import { measureFreshCadence } from './media-soak.mjs';

assert.equal(
  process.platform,
  'darwin',
  'Native archive qualification requires macOS/AVFoundation',
);
const root = fileURLToPath(new URL('..', import.meta.url));
const checkCancellation = cancellation();
const { ffmpeg, ffprobe } = mediaTools();
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/archive-'));
const binary = join(root, 'tools/media-harness/.build/debug/ArchiveHarness');
const children = new Set();

async function run(binary, args, label, timeout = 60_000) {
  checkCancellation();
  const result = await command(binary, args, timeout);
  assert.ok(
    result.ok,
    `${label} failed (${result.error ?? 'unknown'}): ${(result.stdout + result.stderr).slice(-4000)}`,
  );
  return result.stdout;
}

function record(input, directory, options) {
  const child = spawn(binary, ['record', input, directory, ...options], {
    cwd: root,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const item = {
    child,
    exited: false,
    code: null,
    signal: null,
    lastVideoEnd: 0,
    checkpoint: false,
    output: '',
    error: '',
  };
  children.add(item);
  let pending = '';
  child.stdout.on('data', (chunk) => {
    item.output = (item.output + chunk).slice(-128_000);
    pending += chunk;
    let newline;
    while ((newline = pending.indexOf('\n')) >= 0) {
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      try {
        const event = JSON.parse(line);
        if (event.event === 'accepted') item.lastVideoEnd = event.videoEnd;
        if (event.event === 'checkpoint') item.checkpoint = true;
      } catch {
        /* Runtime diagnostics are retained, never interpreted as progress. */
      }
    }
  });
  child.stderr.on('data', (chunk) => {
    item.error = (item.error + chunk).slice(-16_000);
  });
  item.done = new Promise((resolve) => {
    const finish = (code, signal) => {
      if (item.exited) return;
      item.exited = true;
      item.code = code;
      item.signal = signal;
      children.delete(item);
      resolve();
    };
    child.once('error', () => finish(null, null));
    child.once('close', finish);
  });
  return item;
}

async function until(predicate, label, timeout = 25_000) {
  const deadline = performance.now() + timeout;
  while (performance.now() < deadline) {
    checkCancellation();
    if (await predicate()) return;
    await delay(10);
  }
  throw new Error(`Timed out: ${label}`);
}

async function analyze(path, label, full = false) {
  const probe = JSON.parse(
    await run(ffprobe, ['-v', 'error', '-show_streams', '-of', 'json', path], `${label} streams`),
  );
  const video = probe.streams.find((stream) => stream.codec_type === 'video');
  const audio = probe.streams.find((stream) => stream.codec_type === 'audio');
  assert.equal(video?.codec_name, 'h264');
  assert.equal(video.width, 1920);
  assert.equal(video.height, 1080);
  assert.equal(audio?.codec_name, 'aac');
  assert.equal(Number(audio.sample_rate), 48000);
  await run(
    ffmpeg,
    ['-v', 'error', '-xerror', '-i', path, '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-'],
    `${label} full decode`,
  );
  const codesFile = join(artifact, `${label}-codes.raw`);
  await run(
    ffmpeg,
    [
      '-v',
      'error',
      '-y',
      '-i',
      path,
      '-an',
      '-vf',
      frameCodeReadFilter,
      '-fps_mode',
      'passthrough',
      '-f',
      'rawvideo',
      codesFile,
    ],
    `${label} source codes`,
  );
  const codes = decodeFrameCodes(await readFile(codesFile));
  assert.ok(codes.length >= 30, `${label} no usable recovered video`);
  assert.ok(
    codes.every((code, i) => code === i),
    `${label} lost or repeated source frames inside completed fragments`,
  );
  const result = { frames: codes.length, sourceEnd: (codes.at(-1) + 1) / 30 };
  const videoFrames = JSON.parse(
    await run(
      ffprobe,
      [
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_frames',
        '-show_entries',
        'frame=best_effort_timestamp_time',
        '-of',
        'json',
        path,
      ],
      'Archive video timestamps',
    ),
  ).frames;
  const videoTimes = videoFrames.map((frame) => Number(frame.best_effort_timestamp_time));
  assert.equal(videoTimes.length, codes.length);
  for (let i = 1; i < videoTimes.length; i++) {
    assert.ok(
      Math.abs(videoTimes[i] - videoTimes[i - 1] - 1 / 30) <= 0.002,
      'Recovered video has a timestamp discontinuity',
    );
  }
  const audioFrames = JSON.parse(
    await run(
      ffprobe,
      [
        '-v',
        'error',
        '-select_streams',
        'a:0',
        '-show_frames',
        '-show_entries',
        'frame=best_effort_timestamp_time,nb_samples',
        '-of',
        'json',
        path,
      ],
      'Archive audio timestamps',
    ),
  ).frames;
  const audioStartTime = Number(audioFrames[0].best_effort_timestamp_time);
  let samples = 0;
  for (const frame of audioFrames) {
    assert.ok(
      Math.abs(Number(frame.best_effort_timestamp_time) - audioStartTime - samples / 48000) < 0.002,
      'Archive audio discontinuity',
    );
    samples += frame.nb_samples;
  }
  result.coverage = assertMediaCoverage({
    videoTimes,
    audioStartTime,
    audioSampleCount: samples,
    sampleRate: 48000,
  });
  if (!full) return result;
  assert.equal(codes.length, 420, 'Normal archive did not preserve all input video frames');
  result.cadence = measureFreshCadence(codes, videoTimes);
  const rawAudio = join(artifact, `${label}-audio.f32`);
  await run(
    ffmpeg,
    [
      '-v',
      'error',
      '-y',
      '-i',
      path,
      '-vn',
      '-ac',
      '1',
      '-ar',
      '48000',
      '-c:a',
      'pcm_f32le',
      '-f',
      'f32le',
      rawAudio,
    ],
    'Archive PCM decode',
  );
  const bytes = await readFile(rawAudio);
  assert.equal(bytes.length, samples * 4, 'PCM extraction lost timestamp/sample correspondence');
  result.sync = analyzeMediaSync({
    codes,
    videoTimes,
    audioSamples: new Float32Array(bytes.buffer, bytes.byteOffset, samples),
    sampleRate: 48000,
    audioStartTime,
  });
  assertMediaSync(result.sync);
  const clean = join(artifact, 'clean-archive.raw');
  await run(
    ffmpeg,
    [
      '-v',
      'error',
      '-y',
      '-ss',
      '7',
      '-i',
      path,
      '-frames:v',
      '1',
      '-vf',
      'crop=500:80:0:980,format=gray',
      '-f',
      'rawvideo',
      clean,
    ],
    'Clean archive pixels',
  );
  assert.ok(
    (await readFile(clean)).every((value) => value < 20),
    'Archive contains graphics in the clean video region',
  );
  return result;
}

async function bundleHashes(directory) {
  const hashes = {};
  for (const bundle of (await readdir(directory))
    .filter((name) => name.endsWith('.segment'))
    .sort()) {
    for (const name of ['payload.bin', 'metadata.json']) {
      hashes[`${bundle}/${name}`] = createHash('sha256')
        .update(await readFile(join(directory, bundle, name)))
        .digest('hex');
    }
  }
  return hashes;
}

async function encodedPackets(path) {
  const { packets } = JSON.parse(
    await run(
      ffprobe,
      [
        '-v',
        'error',
        '-show_packets',
        '-show_data_hash',
        'sha256',
        '-show_entries',
        'packet=stream_index,data_hash',
        '-of',
        'json',
        path,
      ],
      'Encoded packet hashes',
    ),
  );
  return [0, 1].map((index) =>
    packets.filter((packet) => packet.stream_index === index).map((packet) => packet.data_hash),
  );
}

try {
  await run(
    'swift',
    ['build', '--package-path', 'tools/media-harness'],
    'Native harness build',
    120_000,
  );
  const source = join(artifact, 'source.mp4');
  await run(
    ffmpeg,
    [
      '-v',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=1920x1080:rate=30',
      '-f',
      'lavfi',
      '-i',
      sourceAudioExpression(),
      '-t',
      '14',
      '-vf',
      `drawbox=x=0:y=900:w=iw:h=180:color=black:t=fill,${sourceFrameCodeFilter}`,
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-b:v',
      '12000k',
      '-g',
      '60',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-ar',
      '48000',
      '-b:a',
      '128k',
      source,
    ],
    'Raw-decoding source fixture',
  );
  const results = [];
  const scenarios = [
    { name: 'normal', options: [] },
    { name: 'before-commit', options: ['--pause-before-commit'], checkpoint: true },
    { name: 'after-rename', options: ['--pause-after-rename'], checkpoint: true },
    ...[6.3, 8.3, 10.3].map((killAt) => ({
      name: `kill-${killAt}`,
      options: ['--realtime'],
      killAt,
    })),
  ];
  for (const scenario of scenarios) {
    const directory = join(artifact, scenario.name);
    const item = record(source, directory, scenario.options);
    const crashed = scenario.checkpoint || scenario.killAt;
    let committedBeforeKill = [];
    if (crashed) {
      await until(() => {
        assert.ok(!item.exited, `${scenario.name} exited before crash: ${item.output}`);
        return scenario.checkpoint ? item.checkpoint : item.lastVideoEnd >= scenario.killAt;
      }, `${scenario.name} boundary`);
      committedBeforeKill = (await readdir(directory))
        .filter((entry) => entry.endsWith('.segment'))
        .sort();
      assert.ok(item.child.kill('SIGKILL'), 'Could not kill owned archive process');
    }
    await until(() => item.exited, `${scenario.name} exit`, 30_000);
    if (crashed) assert.equal(item.signal, 'SIGKILL');
    else assert.equal(item.code, 0, item.output + item.error);
    await writeFile(join(artifact, `${scenario.name}.log`), item.output + item.error);
    const completed = (await readdir(directory))
      .filter((entry) => entry.endsWith('.segment'))
      .sort();
    for (const entry of committedBeforeKill)
      assert.ok(completed.includes(entry), 'Completed fragment disappeared');
    const output = join(artifact, `${scenario.name}.fragmented.mp4`);
    await run(binary, ['recover', directory, output], `${scenario.name} recovery`);
    const measured = await analyze(output, scenario.name, !crashed);
    const originals = await bundleHashes(directory);
    const mp4 = join(artifact, `${scenario.name}.mp4`);
    const exportStatus = JSON.parse(
      await run(binary, ['export', directory, mp4], `${scenario.name} MP4 export`),
    );
    assert.equal(exportStatus.event, 'exported');
    assert.equal(exportStatus.videoFrames, measured.frames);
    const exported = await analyze(mp4, `${scenario.name}-export`, !crashed);
    assert.equal(exported.frames, measured.frames, 'MP4 export changed recovered video length');
    assert.deepEqual(
      await encodedPackets(mp4),
      await encodedPackets(output),
      'Export changed encoded media packets',
    );
    assert.deepEqual(
      await bundleHashes(directory),
      originals,
      'Export modified original archive fragments',
    );
    if (!crashed) {
      const failures = JSON.parse(
        await run(
          binary,
          ['check-export-failures', directory, join(artifact, 'export-failures')],
          'Native export cancellation and destination race',
        ),
      );
      assert.equal(failures.event, 'export-failures-checked');
      assert.equal(failures.cases, 2);
      assert.deepEqual(
        await bundleHashes(directory),
        originals,
        'Failed export modified original fragments',
      );
    }
    // A kill may land after append returns but before its progress line is written.
    // One source frame is a conservative bound for that unreported tail.
    const tailLossUpperBound = crashed
      ? Math.max(0, item.lastVideoEnd + 1 / 30 - measured.sourceEnd)
      : 0;
    assert.ok(tailLossUpperBound <= 5, `${scenario.name} lost over five seconds of tail`);
    if (scenario.name === 'after-rename') {
      const cache = JSON.parse(await readFile(join(directory, 'manifest.json'), 'utf8'));
      assert.ok(
        completed.length > cache.length,
        'Crash did not leave a committed fragment beyond the manifest',
      );
    }
    results.push({
      scenario: scenario.name,
      completedSegments: completed.length,
      ...measured,
      tailLossUpperBound,
      exported,
    });
    console.log(
      `${scenario.name}: ${measured.frames} decoded fresh frames; tail-loss bound ${tailLossUpperBound.toFixed(3)}s.`,
    );
  }
  await writeFile(join(artifact, 'results.json'), JSON.stringify(results, null, 2) + '\n');
  console.log(
    `PASS: native 1080p archive, A/V timing, and five forced terminations; evidence in ${artifact}`,
  );
} finally {
  for (const item of children) {
    item.child.kill('SIGKILL');
    await Promise.race([item.done, delay(3000)]);
    assert.ok(item.exited, 'Owned archive process did not exit during cleanup');
  }
}
