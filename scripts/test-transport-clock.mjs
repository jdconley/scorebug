import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { buildFfmpegArgs } from '../apps/home-daemon/src/pipeline.ts';
import { runInstrumentedWorker } from './test-worker-timestamps.mjs';
import { mediaTools } from './media-tools.mjs';
import {
  sourceFrameCodeFilter,
  frameCodeReadFilter,
  decodeFrameCodes,
} from './media-frame-codes.mjs';
import {
  parseTransport,
  MAX_TS_BYTES,
  MAX_FRAMES,
  PTS_MODULUS,
  moduloPTS,
} from './transport-clock-parser.mjs';

const execute = promisify(execFile);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const maxArtifactBytes = 32 * 1024 * 1024;
const errorText = (error) => (error instanceof Error ? error.message : String(error));
async function boundedRead(path, limit = maxArtifactBytes) {
  assert.ok((await stat(path)).size <= limit, `Artifact exceeded byte bound: ${path}`);
  return readFile(path);
}
function check(result, name, fn) {
  try {
    fn();
    result.checks[name] = { pass: true };
  } catch (error) {
    result.checks[name] = { pass: false, error: errorText(error) };
  }
}
function endpoints(frames, sampleRate = 44100) {
  const video = frames.filter((frame) => frame.media_type === 'video');
  const audio = frames.filter((frame) => frame.media_type === 'audio');
  assert.ok(video.length && audio.length, 'Missing output audio/video');
  const time = (frame) => Number(frame.best_effort_timestamp_time);
  assert.ok(
    [...video, ...audio].every((frame) => Number.isFinite(time(frame))),
    'Invalid frame time',
  );
  const lastAudio = audio.at(-1);
  return {
    videoTimes: video.map(time),
    audioTimes: audio.map(time),
    firstVideo: time(video[0]),
    firstAudio: time(audio[0]),
    videoEnd: time(video.at(-1)) + 1 / 30,
    audioEnd: time(lastAudio) + Number(lastAudio.nb_samples) / sampleRate,
  };
}

export async function qualifyTransportClock() {
  const { ffmpeg, ffprobe, font } = mediaTools();
  const base = join(root, 'artifacts/qa');
  await mkdir(base, { recursive: true });
  const directory = await mkdtemp(join(base, 'transport-clock-'));
  const reportPath = join(directory, 'results.json');
  const report = {
    scope:
      'Finite FFmpeg MPEG-TS worker transport-clock characterization; not native muxer or source-loss denominator qualification',
    directory,
    startedAt: new Date().toISOString(),
    modulus: PTS_MODULUS,
    invocation: {
      executable: process.execPath,
      argv: process.argv,
      cwd: process.cwd(),
      nodeVersion: process.version,
    },
    candidateRationale:
      'copyts preserves transport timestamps; observed negative wrap PTS require testing output-only make_zero, then passthrough to avoid pre-mux VFR frame removal. All remain experiment-only.',
    commands: [],
    fixtures: [],
    errors: [],
  };
  const save = () => writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
  async function run(binary, args) {
    const command = { binary, args, startedAt: new Date().toISOString() };
    report.commands.push(command);
    await save();
    try {
      const result = await execute(binary, args, {
        timeout: 20_000,
        killSignal: 'SIGKILL',
        maxBuffer: 4 * 1024 * 1024,
      });
      Object.assign(command, {
        terminal: { code: 0, signal: null },
        stdout: result.stdout,
        stderr: result.stderr,
      });
      return result;
    } catch (error) {
      Object.assign(command, {
        terminal: { code: error.code ?? null, signal: error.signal ?? null },
        error: errorText(error),
        stdout: error.stdout,
        stderr: error.stderr,
      });
      throw error;
    } finally {
      await save();
    }
  }
  async function probe(path) {
    const result = JSON.parse(
      (
        await run(ffprobe, [
          '-v',
          'error',
          '-show_frames',
          '-show_entries',
          'frame=media_type,pts,best_effort_timestamp,best_effort_timestamp_time,pkt_pos,key_frame,nb_samples,sample_rate',
          '-of',
          'json',
          path,
        ])
      ).stdout,
    );
    assert.ok(result.frames.length <= MAX_FRAMES * 4, 'Probe frame bound');
    return result.frames;
  }
  async function codes(path, output) {
    await run(ffmpeg, [
      '-v',
      'error',
      '-i',
      path,
      '-map',
      '0:v:0',
      '-vf',
      frameCodeReadFilter,
      '-fps_mode',
      'passthrough',
      '-f',
      'rawvideo',
      output,
    ]);
    return decodeFrameCodes(await boundedRead(output, MAX_FRAMES * 16));
  }
  async function pulseOffsets(path, output, media, identities, expectedIdentities) {
    await run(ffmpeg, [
      '-v',
      'error',
      '-i',
      path,
      '-map',
      '0:a:0',
      '-ac',
      '1',
      '-ar',
      '48000',
      '-c:a',
      'pcm_f32le',
      '-f',
      'f32le',
      output,
    ]);
    const bytes = await boundedRead(output, 48000 * 6 * 4);
    const onsets = [];
    let lastActive = -48000;
    for (let index = 0; index < bytes.length / 4; index++) {
      if (Math.abs(bytes.readFloatLE(index * 4)) < 0.1) continue;
      if (index - lastActive > 4800) onsets.push(media.firstAudio + index / 48000);
      lastActive = index;
    }
    const markerCodes = [0, 60].filter(
      (code) => code >= expectedIdentities[0] && code <= expectedIdentities.at(-1),
    );
    return {
      onsets,
      markerCodes,
      missingVideoMarkers: markerCodes.filter((code) => !identities.includes(code)),
      offsets: markerCodes.map((code, index) => {
        const retainedIndex = identities.indexOf(code);
        return retainedIndex < 0 ? null : onsets[index] - media.videoTimes[retainedIndex];
      }),
      decodedAudioEnd: media.firstAudio + bytes.length / 4 / 48000,
    };
  }
  async function characterize(name, input, wire, expectedCodes, suffix) {
    const fixture = { name, input, suffix, wire, expectedCodes, checks: {}, candidates: [] };
    fixture.inputSHA256 = createHash('sha256')
      .update(await boundedRead(input))
      .digest('hex');
    report.fixtures.push(fixture);
    await save();
    try {
      fixture.sourceFrames = await probe(input);
      fixture.sourceCodes = await codes(input, join(directory, `${name}-source.gray`));
      fixture.sourceVideoPTS = fixture.sourceFrames
        .filter((frame) => frame.media_type === 'video')
        .map((frame) => Number(frame.pts));
      fixture.sourceEndpoints = endpoints(fixture.sourceFrames, 48000);
      check(fixture, 'oneSecondKeyframes', () =>
        assert.deepEqual(
          fixture.sourceFrames
            .filter((frame) => frame.media_type === 'video')
            .map((frame, index) => (frame.key_frame ? expectedCodes[index] : null))
            .filter((value) => value !== null),
          expectedCodes.filter((code) => code % 30 === 0),
        ),
      );
      check(fixture, 'sourceFrameIdentities', () =>
        assert.deepEqual(fixture.sourceCodes, expectedCodes),
      );
      check(fixture, 'decodedSourceWirePTS', () =>
        assert.deepEqual(
          fixture.sourceVideoPTS.map(moduloPTS),
          wire.video.map((frame) => frame.pts),
        ),
      );
      if (Object.values(fixture.checks).some((item) => !item.pass))
        throw new Error('Source qualification failed');
      for (const candidate of [
        'current',
        'copyts',
        ...(name.startsWith('wrap') ? ['copyts-make-zero'] : []),
        'copyts-passthrough-make-zero',
      ]) {
        const output = join(directory, `${name}-${candidate}.flv`);
        const args = buildFfmpegArgs({
          gameId: 'transport-clock',
          pullUrl: input,
          publishUrl: output,
          scoreFile: join(directory, 'score.txt'),
          fontPath: font,
          nvenc: false,
          encoder: 'software',
          profile: { width: 640, height: 360, fps: 30, bitrateKbps: 1000 },
        });
        if (candidate.startsWith('copyts')) args.unshift('-copyts');
        if (candidate.includes('make-zero'))
          args.splice(args.length - 3, 0, '-avoid_negative_ts', 'make_zero');
        if (candidate.includes('passthrough')) args[args.indexOf('-fps_mode') + 1] = 'passthrough';
        const result = { candidate, output, args, checks: {}, diagnostics: {} };
        fixture.candidates.push(result);
        report.commands.push({
          binary: ffmpeg,
          args,
          worker: true,
          diagnostics: result.diagnostics,
        });
        await save();
        try {
          result.decoderPTS = await runInstrumentedWorker(ffmpeg, args, result.diagnostics);
          result.decoderWireDifferences = result.decoderPTS.map((pts, index) =>
            index < wire.video.length ? moduloPTS(pts - wire.video[index].pts) : null,
          );
          check(result, 'decoderFrameCount', () =>
            assert.equal(result.decoderPTS.length, wire.video.length),
          );
          check(result, 'decoderWireCorrespondence', () =>
            assert.deepEqual(
              result.decoderPTS.map(moduloPTS),
              wire.video.map((frame) => frame.pts),
            ),
          );
        } catch (error) {
          result.workerError = errorText(error);
        }
        await save();
        try {
          result.outputBytes = (await stat(output)).size;
          assert.ok(result.outputBytes <= maxArtifactBytes, 'Output exceeded byte bound');
          result.outputFrames = await probe(output);
          result.outputCodes = await codes(output, join(directory, `${name}-${candidate}.gray`));
          result.endpoints = endpoints(result.outputFrames);
          check(result, 'allFrameIdentitiesRetained', () =>
            assert.deepEqual(result.outputCodes, expectedCodes),
          );
          check(result, 'noDuplicateFrames', () =>
            assert.equal(new Set(result.outputCodes).size, result.outputCodes.length),
          );
          check(result, 'frameTimestampCount', () =>
            assert.equal(result.outputCodes.length, result.endpoints.videoTimes.length),
          );
          check(result, 'sourceFrameTiming', () => {
            for (let i = 1; i < result.outputCodes.length; i++) {
              const interval = result.endpoints.videoTimes[i] - result.endpoints.videoTimes[i - 1];
              assert.ok(
                interval > 0 &&
                  Math.abs(interval - (result.outputCodes[i] - result.outputCodes[i - 1]) / 30) <=
                    0.002,
                'Output PTS must follow retained source identity',
              );
            }
          });
          const sourceLead =
            fixture.sourceEndpoints.firstVideo - fixture.sourceEndpoints.firstAudio;
          result.acquisitionLead = result.endpoints.firstVideo - result.endpoints.firstAudio;
          check(result, 'acquisitionOffset', () =>
            assert.ok(
              result.acquisitionLead >= sourceLead - 0.02 &&
                result.acquisitionLead <= sourceLead + 0.04,
              'Changed A/V acquisition offset',
            ),
          );
          result.audioMarkers = await pulseOffsets(
            output,
            join(directory, `${name}-${candidate}.f32`),
            result.endpoints,
            result.outputCodes,
            expectedCodes,
          );
          check(result, 'audioMarkerCount', () =>
            assert.equal(result.audioMarkers.onsets.length, result.audioMarkers.markerCodes.length),
          );
          check(result, 'audioMarkerAlignment', () =>
            assert.ok(
              result.audioMarkers.offsets.every(
                (offset) => Number.isFinite(offset) && Math.abs(offset) < 0.04,
              ),
              'Audio markers lost source-frame alignment',
            ),
          );
          check(result, 'balancedEOFTail', () =>
            assert.ok(
              Math.abs(result.audioMarkers.decodedAudioEnd - result.endpoints.videoEnd) <= 0.1,
              'Unbalanced worker EOF tail',
            ),
          );
        } catch (error) {
          result.outputError = errorText(error);
        }
        result.mappingPass =
          result.checks.decoderWireCorrespondence?.pass === true && !result.workerError;
        result.mediaPass =
          !result.workerError &&
          !result.outputError &&
          Object.entries(result.checks)
            .filter(([key]) => key !== 'decoderWireCorrespondence')
            .every(([, value]) => value.pass);
        await save();
        console.log(
          JSON.stringify({
            fixture: name,
            candidate,
            mappingPass: result.mappingPass,
            mediaPass: result.mediaPass,
            firstDecoderPTS: result.decoderPTS?.[0],
            firstWirePTS: wire.video[0].pts,
            frames: result.outputCodes?.length,
            workerError: result.workerError,
            outputError: result.outputError,
          }),
        );
      }
    } catch (error) {
      fixture.error = errorText(error);
      await save();
    }
  }
  try {
    report.ffmpegVersion = (await run(ffmpeg, ['-version'])).stdout;
    report.ffprobeVersion = (await run(ffprobe, ['-version'])).stdout;
    await writeFile(join(directory, 'score.txt'), 'Home 0 - 0 Away');
    for (const { name, origin } of [
      { name: 'ordinary', origin: 0 },
      { name: 'origin', origin: 123.25 },
      { name: 'wrap', origin: PTS_MODULUS / 90000 - 1.5 },
    ]) {
      const input = join(directory, `${name}.ts`);
      try {
        await run(ffmpeg, [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=640x360:rate=30:duration=4',
          '-f',
          'lavfi',
          '-i',
          "aevalsrc='if(between(t,0.1,0.3)+between(t,2.1,2.3),0.5*sin(2*PI*1000*t),0)':s=48000:d=4.1",
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-vf',
          `${sourceFrameCodeFilter},setpts=PTS+0.1/TB`,
          '-fps_mode',
          'passthrough',
          '-c:v',
          'libx264',
          '-preset',
          'veryfast',
          '-tune',
          'zerolatency',
          '-crf',
          '16',
          '-g',
          '30',
          '-keyint_min',
          '30',
          '-sc_threshold',
          '0',
          '-bf',
          '0',
          '-pix_fmt',
          'yuv420p',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-ar',
          '48000',
          '-output_ts_offset',
          String(origin),
          '-avoid_negative_ts',
          'disabled',
          '-mpegts_copyts',
          '1',
          '-mpegts_flags',
          '+resend_headers',
          '-muxdelay',
          '0',
          '-muxpreload',
          '0',
          '-f',
          'mpegts',
          input,
        ]);
        const bytes = await boundedRead(input, MAX_TS_BYTES);
        const wire = parseTransport(bytes);
        assert.equal(wire.video.length, 120, 'Expected 120 source frame PES');
        if (name === 'wrap')
          assert.ok(
            wire.video.some((frame, index) => index > 0 && frame.pts < wire.video[index - 1].pts),
            'Fixture must cross 33-bit wire wrap',
          );
        await characterize(
          name,
          input,
          wire,
          Array.from({ length: 120 }, (_, index) => index),
        );
        // Exactly the same transport bytes starting at the last repeated PAT before
        // the second IDR. No demux/remux or timestamp editing occurs here.
        assert.ok(wire.video[30].randomAccess, 'Expected one-second random-access frame');
        const cut = wire.patOffsets.filter((offset) => offset < wire.video[30].packetOffset).at(-1);
        assert.ok(cut > wire.video[29].packetOffset, 'PAT must follow preceding video PES');
        const suffixBytes = bytes.subarray(cut);
        const suffixPath = join(directory, `${name}-late.ts`);
        await writeFile(suffixPath, suffixBytes);
        const suffixWire = parseTransport(suffixBytes);
        assert.deepEqual(
          suffixWire.video.map((frame) => frame.pts),
          wire.video.slice(30).map((frame) => frame.pts),
          'Suffix changed original wire PTS',
        );
        await characterize(
          `${name}-late`,
          suffixPath,
          suffixWire,
          Array.from({ length: 90 }, (_, index) => index + 30),
          {
            original: input,
            byteOffset: cut,
            packetIndex: cut / 188,
            originalFirstFrame: 30,
            unchangedBytes: true,
          },
        );
      } catch (error) {
        report.errors.push({ name, error: errorText(error) });
        await save();
      }
    }
  } catch (error) {
    report.errors.push({ stage: 'setup', error: errorText(error) });
  }
  report.finishedAt = new Date().toISOString();
  report.characterizationComplete =
    report.errors.length === 0 &&
    report.fixtures.length === 6 &&
    report.fixtures.every(
      (fixture) =>
        !fixture.error &&
        fixture.candidates.length === (fixture.name.startsWith('wrap') ? 4 : 3) &&
        fixture.candidates.every((result) => !result.workerError && !result.outputError),
    );
  report.copytsQualified =
    report.characterizationComplete &&
    report.fixtures.every(
      (fixture) =>
        fixture.candidates.find((result) => result.candidate === 'copyts')?.mappingPass &&
        fixture.candidates.find((result) => result.candidate === 'copyts')?.mediaPass,
    );
  report.copytsPassthroughMuxzeroQualified =
    report.characterizationComplete &&
    report.fixtures.every((fixture) => {
      const candidate = fixture.candidates.find(
        (result) => result.candidate === 'copyts-passthrough-make-zero',
      );
      return candidate?.mappingPass && candidate?.mediaPass;
    });
  report.copytsMuxzeroWrapQualified =
    report.characterizationComplete &&
    report.fixtures
      .filter((fixture) => fixture.name.startsWith('wrap'))
      .every((fixture) => {
        const candidate = fixture.candidates.find(
          (result) => result.candidate === 'copyts-make-zero',
        );
        return candidate?.mappingPass && candidate?.mediaPass;
      });
  report.chosenCandidate = 'copyts-passthrough-make-zero';
  report.qualifiedCandidates = [
    'current',
    'copyts',
    'copyts-make-zero',
    report.chosenCandidate,
  ].filter(
    (candidate) =>
      report.characterizationComplete &&
      report.fixtures.every((fixture) => {
        const result = fixture.candidates.find((result) => result.candidate === candidate);
        return result?.mappingPass && result?.mediaPass;
      }),
  );
  await save();
  console.log(
    JSON.stringify({
      reportPath,
      qualifiedCandidates: report.qualifiedCandidates,
      copytsPassthroughMuxzeroQualified: report.copytsPassthroughMuxzeroQualified,
      copytsMuxzeroWrapQualified: report.copytsMuxzeroWrapQualified,
      characterizationComplete: report.characterizationComplete,
      copytsQualified: report.copytsQualified,
      errors: report.errors,
    }),
  );
  return report;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const report = await qualifyTransportClock();
  if (!report.qualifiedCandidates.includes(report.chosenCandidate)) process.exitCode = 1;
}
