import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { buildFfmpegArgs } from '../apps/home-daemon/src/pipeline.ts';
import { runInstrumentedWorker } from './worker-timestamp-fixture.mjs';
import { mediaTools } from './media-tools.mjs';
import {
  sourceFrameCodeFilter,
  frameCodeReadFilter,
  decodeFrameCodes,
} from './media-frame-codes.mjs';
import { parseTransport, moduloPTS, PTS_MODULUS } from './transport-clock-parser.mjs';

const execute = promisify(execFile);
const root = fileURLToPath(new URL('..', import.meta.url));

/** Finite real-media regression for native floor quantization at the worker cap. */
export async function qualifyWorkerCapQuantization({ encoder = 'software' } = {}) {
  const { ffmpeg, ffprobe, font } = mediaTools();
  const artifactRoot = join(root, 'artifacts/qa');
  await mkdir(artifactRoot, { recursive: true });
  const directory = await mkdtemp(join(artifactRoot, 'worker-cap-quantization-'));
  const report = { directory, encoder, commands: [], scenarios: [] };
  const save = () =>
    writeFile(join(directory, 'results.json'), JSON.stringify(report, null, 2) + '\n');
  async function run(binary, args) {
    const command = { binary, args };
    report.commands.push(command);
    try {
      const result = await execute(binary, args, { timeout: 20000, maxBuffer: 4 * 1024 * 1024 });
      command.exitCode = 0;
      return result;
    } catch (error) {
      command.exitCode = error.code;
      command.stderr = String(error.stderr ?? '').slice(-64000);
      throw error;
    }
  }
  async function probe(file) {
    return JSON.parse(
      (
        await run(ffprobe, [
          '-v',
          'error',
          '-show_frames',
          '-show_entries',
          'frame=media_type,best_effort_timestamp,best_effort_timestamp_time',
          '-of',
          'json',
          file,
        ])
      ).stdout,
    ).frames;
  }
  async function codes(file, target) {
    await run(ffmpeg, [
      '-v',
      'error',
      '-i',
      file,
      '-map',
      '0:v:0',
      '-vf',
      frameCodeReadFilter,
      '-fps_mode',
      'passthrough',
      '-f',
      'rawvideo',
      target,
    ]);
    return decodeFrameCodes(await readFile(target));
  }
  console.log(`Worker cap quantization artifacts: ${directory}`);
  for (const scenario of [
    { name: 'nonzero', epoch: 177000, firstCode: 0 },
    { name: 'wrap', epoch: PTS_MODULUS - 90000, firstCode: 0 },
    { name: 'late-phase', epoch: 177000, firstCode: 13 },
    { name: 'late-floor-phase', epoch: 177000, firstCode: 14 },
  ]) {
    const result = { ...scenario, worker: {} };
    report.scenarios.push(result);
    const source = join(directory, `${scenario.name}.ts`);
    const output = join(directory, `${scenario.name}.flv`);
    const score = join(directory, 'score.txt');
    try {
      await writeFile(score, 'Home 0 - 0 Away');
      // Exact integer 90 kHz source clock: each third frame is one tick early.
      // Barcode precedes select so late input retains its actual source identity.
      await run(ffmpeg, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=640x360:rate=30:duration=3',
        '-f',
        'lavfi',
        '-i',
        "aevalsrc='if(between(t,0.6,0.8)+between(t,2.6,2.8),0.5*sin(2*PI*1000*t),0)':s=48000:d=3",
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-vf',
        `${sourceFrameCodeFilter},settb=1/90000,setpts='N*3000-if(eq(mod(N,3),2),1,0)+${scenario.epoch}',select='gte(n,${scenario.firstCode})'`,
        '-af',
        `asetpts=PTS+${scenario.epoch}/90000/TB`,
        '-fps_mode',
        'passthrough',
        '-enc_time_base:v',
        '1:90000',
        '-c:v',
        'libx264',
        '-preset',
        'ultrafast',
        '-crf',
        '10',
        '-bf',
        '0',
        '-g',
        '30',
        '-c:a',
        'aac',
        '-avoid_negative_ts',
        'disabled',
        '-mpegts_copyts',
        '1',
        '-muxdelay',
        '0',
        '-muxpreload',
        '0',
        '-f',
        'mpegts',
        source,
      ]);
      const expectedCodes = Array.from(
        { length: 90 - scenario.firstCode },
        (_, i) => i + scenario.firstCode,
      );
      const expectedTicks = expectedCodes.map(
        (code) => scenario.epoch + code * 3000 - (code % 3 === 2 ? 1 : 0),
      );
      result.expectedCodes = expectedCodes;
      result.sourceCodes = await codes(source, join(directory, `${scenario.name}-source.gray`));
      assert.deepEqual(
        result.sourceCodes,
        expectedCodes,
        'Fixture must contain every intended source picture',
      );
      const transport = parseTransport(await readFile(source));
      result.transportPTS = transport.video.map((frame) => frame.pts);
      assert.deepEqual(
        result.transportPTS,
        expectedTicks.map(moduloPTS),
        'Fixture must contain exact one-tick quantization and intended epoch',
      );
      const sourceFrames = (await probe(source)).filter((frame) => frame.media_type === 'video');
      result.sourcePTS = sourceFrames.map((frame) => Number(frame.best_effort_timestamp));
      const args = buildFfmpegArgs({
        gameId: 'cap-quantization-regression',
        pullUrl: source,
        publishUrl: output,
        scoreFile: score,
        fontPath: font,
        nvenc: false,
        encoder,
        profile: { width: 640, height: 360, fps: 30, bitrateKbps: 1000 },
      });
      result.worker.args = args;
      const decodedPTS = await runInstrumentedWorker(ffmpeg, args, result.worker);
      assert.deepEqual(
        decodedPTS,
        result.sourcePTS,
        'fd3 must observe every original source PTS before the cap',
      );
      result.outputCodes = await codes(output, join(directory, `${scenario.name}-output.gray`));
      result.missingCodes = expectedCodes.filter((code) => !result.outputCodes.includes(code));
      result.decodedFrames = decodedPTS.length;
      result.outputFrames = result.outputCodes.length;
      assert.deepEqual(
        result.outputCodes,
        expectedCodes,
        '30 fps cap must retain all floor-quantized source identities',
      );
      const outputFrames = await probe(output);
      const videoTimes = outputFrames
        .filter((frame) => frame.media_type === 'video')
        .map((frame) => Number(frame.best_effort_timestamp_time));
      const audioTimes = outputFrames
        .filter((frame) => frame.media_type === 'audio')
        .map((frame) => Number(frame.best_effort_timestamp_time));
      assert.equal(videoTimes.length, expectedCodes.length);
      for (let i = 1; i < videoTimes.length; i++) {
        assert.ok(videoTimes[i] > videoTimes[i - 1], 'Output PTS must strictly increase');
        assert.ok(
          Math.abs(videoTimes[i] - videoTimes[0] - (expectedTicks[i] - expectedTicks[0]) / 90000) <
            0.002,
          'Output must retain the source PTS differences',
        );
      }
      const audioFile = join(directory, `${scenario.name}-audio.f32`);
      await run(ffmpeg, [
        '-v',
        'error',
        '-i',
        output,
        '-map',
        '0:a:0',
        '-ar',
        '48000',
        '-c:a',
        'pcm_f32le',
        '-f',
        'f32le',
        audioFile,
      ]);
      const audio = await readFile(audioFile);
      const samples = new Float32Array(audio.buffer, audio.byteOffset, audio.byteLength / 4);
      const onsets = [];
      let lastActive = -48000;
      for (let i = 0; i < samples.length; i++) {
        if (Math.abs(samples[i]) < 0.1) continue;
        if (i - lastActive > 4800) onsets.push(audioTimes[0] + i / 48000);
        lastActive = i;
      }
      assert.equal(onsets.length, 2, 'Both source audio markers must survive');
      result.avOffsets = onsets.map(
        (onset, marker) => onset - videoTimes[expectedCodes.indexOf(18 + marker * 60)],
      );
      assert.ok(
        result.avOffsets.every((offset) => Math.abs(offset) < 0.04),
        'Audio markers must remain aligned with source identities',
      );
      result.tailOffsetSeconds =
        audioTimes[0] + samples.length / 48000 - (videoTimes.at(-1) + 1 / 30);
      assert.ok(
        Math.abs(result.tailOffsetSeconds) <= 0.1,
        'Quantization fixture must retain balanced A/V EOF',
      );
      result.passed = true;
    } catch (error) {
      result.passed = false;
      result.error = String(error.stack ?? error);
    }
    await save();
    console.log(
      `${scenario.name}: ${result.decodedFrames ?? '?'} decoded, ${result.outputFrames ?? '?'} output; ${result.passed ? 'PASS' : 'FAIL'}`,
    );
  }
  assert.ok(
    report.scenarios.every((scenario) => scenario.passed),
    `Worker cap quantization failed; retained evidence: ${directory}`,
  );
  return report;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await qualifyWorkerCapQuantization({ encoder: process.argv[2] ?? 'software' });
}
