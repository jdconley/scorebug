import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { buildFfmpegArgs } from '../apps/home-daemon/src/pipeline.ts';
import { mediaTools } from './media-tools.mjs';
import {
  sourceFrameCodeFilter,
  frameCodeReadFilter,
  decodeFrameCodes,
} from './media-frame-codes.mjs';

const execute = promisify(execFile);
async function run(binary, args) {
  return execute(binary, args, { timeout: 20_000, maxBuffer: 4 * 1024 * 1024 });
}

/** Explicit media qualification: no FFmpeg dependency in the default unit suite. */
export async function qualifyWorkerTimestamps({
  encoder = 'software',
  includeTailExperiment = false,
} = {}) {
  const { ffmpeg, ffprobe, font } = mediaTools();
  const results = [];
  for (const { inputFPS, gap = false, lead = 0.6, tail = 0 } of [
    { inputFPS: 30, gap: false },
    { inputFPS: 60, gap: false },
    { inputFPS: 25, gap: false },
    { inputFPS: 30, gap: true },
    { inputFPS: 30, lead: 1.8 },
    ...(includeTailExperiment ? [{ inputFPS: 30, tail: 0.4 }] : []),
  ]) {
    const directory = await mkdtemp(join(tmpdir(), 'scorebug-worker-timestamps-'));
    try {
      const source = join(directory, 'source.mkv');
      const output = join(directory, 'output.flv');
      const score = join(directory, 'score.txt');
      const codesFile = join(directory, 'codes.gray');
      const audioFile = join(directory, 'audio.f32');
      await writeFile(score, 'Home 0 - 0 Away');
      // Video joins after audio. Lossless input isolates worker changes.
      // The gap case also omits twelve real source frames without shifting PTS.
      await run(ffmpeg, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        `testsrc2=size=640x360:rate=${inputFPS}:duration=3`,
        '-f',
        'lavfi',
        '-i',
        `aevalsrc='if(between(t,${lead},${lead + 0.2})+between(t,${lead + 2},${lead + 2.2}),0.5*sin(2*PI*1000*t),0)':s=48000:d=${3 + lead + tail}`,
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-vf',
        `${sourceFrameCodeFilter},${gap ? "select='not(between(n,30,41))'," : ''}setpts=PTS+${lead}/TB`,
        '-fps_mode',
        'passthrough',
        '-c:v',
        'ffv1',
        '-c:a',
        'pcm_s16le',
        source,
      ]);
      const workerArgs = buildFfmpegArgs({
        gameId: 'timestamp-regression',
        pullUrl: source,
        publishUrl: output,
        scoreFile: score,
        fontPath: font,
        nvenc: false,
        encoder,
        profile: { width: 640, height: 360, fps: 30, bitrateKbps: 1000 },
      });
      await run(ffmpeg, workerArgs);
      await run(ffmpeg, [
        '-v',
        'error',
        '-i',
        output,
        '-map',
        '0:v:0',
        '-vf',
        frameCodeReadFilter,
        '-fps_mode',
        'passthrough',
        '-f',
        'rawvideo',
        codesFile,
      ]);
      const codes = decodeFrameCodes(await readFile(codesFile));
      const probe = JSON.parse(
        (
          await run(ffprobe, [
            '-v',
            'error',
            '-show_frames',
            '-show_entries',
            'frame=media_type,best_effort_timestamp_time',
            '-of',
            'json',
            output,
          ])
        ).stdout,
      );
      const videoTimes = probe.frames
        .filter((frame) => frame.media_type === 'video')
        .map((frame) => Number(frame.best_effort_timestamp_time));
      const audioTimes = probe.frames
        .filter((frame) => frame.media_type === 'audio')
        .map((frame) => Number(frame.best_effort_timestamp_time));
      const firstAudio = audioTimes[0];
      assert.equal(codes.length, videoTimes.length);
      assert.equal(new Set(codes).size, codes.length, 'Worker synthesized duplicate source frames');
      assert.equal(codes[0], 0);
      const expectedCodes = Array.from({ length: 3 * inputFPS }, (_, index) => index).filter(
        (code) => (!gap || code < 30 || code > 41) && (inputFPS <= 30 || code % 2 === 0),
      );
      assert.deepEqual(
        codes,
        expectedCodes,
        'Cap must preserve 25/30 fps and select every other 60 fps frame',
      );
      assert.ok(
        videoTimes[0] - firstAudio >= lead - 0.02 && videoTimes[0] - firstAudio <= lead + 0.04,
        'Worker must preserve the initial video/audio acquisition offset',
      );
      for (let index = 1; index < videoTimes.length; index++) {
        const expectedInterval = (codes[index] - codes[index - 1]) / inputFPS;
        assert.ok(
          Math.abs(videoTimes[index] - videoTimes[index - 1] - expectedInterval) <= 0.002,
          'Encoded PTS must follow retained source identity, including missing-video gaps',
        );
        assert.ok(videoTimes[index] > videoTimes[index - 1]);
      }
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
      const pulseOnsets = [];
      let lastActive = -48000;
      for (let index = 0; index < samples.length; index++) {
        if (Math.abs(samples[index]) < 0.1) continue;
        if (index - lastActive > 4800) pulseOnsets.push(firstAudio + index / 48000);
        lastActive = index;
      }
      assert.equal(pulseOnsets.length, 2, 'Both audio markers must survive, including early audio');
      const offsets = pulseOnsets.map((onset, marker) => {
        const sourceCode = marker * 2 * inputFPS;
        const nearest = codes.findIndex((code) => code >= sourceCode);
        assert.ok(nearest >= 0);
        const videoMarkerTime = videoTimes[nearest] - (codes[nearest] - sourceCode) / inputFPS;
        const offset = onset - videoMarkerTime;
        assert.ok(
          Math.abs(offset) < 0.04,
          'Audio marker must remain aligned to source frame identity',
        );
        return offset;
      });
      const videoEndPTS = videoTimes.at(-1) + 1 / Math.min(inputFPS, 30);
      const audioEndPTS = firstAudio + samples.length / 48000;
      assert.ok(
        Math.abs(audioEndPTS - videoEndPTS) <= 0.1,
        `Unbalanced worker EOF tail: audio ${audioEndPTS}, video ${videoEndPTS}`,
      );
      results.push({
        encoder,
        sourceAudioTailSeconds: tail,
        inputFPS,
        gap,
        frames: codes.length,
        firstCode: codes[0],
        lastCode: codes.at(-1),
        firstVideoPTS: videoTimes[0],
        lastVideoPTS: videoTimes.at(-1),
        firstAudioPTS: firstAudio,
        audioEndPTS,
        videoEndPTS,
        tailOffsetSeconds: audioEndPTS - videoEndPTS,
        acquisitionLeadSeconds: videoTimes[0] - firstAudio,
        maxAVOffsetSeconds: Math.max(...offsets.map(Math.abs)),
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }
  return results;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  console.log(
    JSON.stringify(
      await qualifyWorkerTimestamps({
        encoder: process.argv[2] ?? 'software',
        includeTailExperiment: process.argv.includes('--tail-experiment'),
      }),
      null,
      2,
    ),
  );
}
