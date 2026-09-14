import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:net';
import { createSocket } from 'node:dgram';
import { copyFile, mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { mediaTools } from './media-tools.mjs';
import { scoringTestToken } from './scoring-test-server.mjs';

/** Owned, loopback-only proxy fixtures. No ambient worker or relay is used. */
export async function nativeStreamingFixture({ artifact, root, run }) {
  const names = [];
  let worker, done;
  let statusTask, statusAbort, statusError;
  const decodedWindows = new Map();
  async function stopStatus() {
    statusAbort?.abort();
    await statusTask;
  }
  async function port(udp = false) {
    const socket = udp ? createSocket('udp4') : createServer();
    await new Promise((resolve, reject) => {
      socket.once('error', reject);
      if (udp) socket.bind(0, '127.0.0.1', resolve);
      else socket.listen(0, '127.0.0.1', resolve);
    });
    const value = socket.address().port;
    await new Promise((resolve) => socket.close(resolve));
    return value;
  }
  async function stopWorker() {
    if (!worker) return;
    worker.kill('SIGTERM');
    await Promise.race([done, delay(5000)]);
    if (worker.exitCode === null && worker.signalCode === null) worker.kill('SIGKILL');
    await done;
    worker = undefined;
  }
  async function stop() {
    const errors = [];
    await stopStatus();
    try {
      await stopWorker();
    } catch (error) {
      errors.push(error);
    }
    for (const name of [...names].reverse()) {
      try {
        await run('docker', ['rm', '-f', name], `remove-${name}`, { cleanup: true });
      } catch (error) {
        errors.push(error);
      }
    }
    if (errors.length) throw new AggregateError(errors, 'Owned proxy cleanup failed');
  }
  try {
    const ingestPort = await port(true),
      relayPort = await port();
    const sinkPort = await port(),
      sinkApiPort = await port();
    const sinkName = `scorebug-native-sink-${randomUUID()}`;
    for (const [kind, media, apiPort, name] of [
      ['ingest', ingestPort, relayPort, `scorebug-native-ingest-${randomUUID()}`],
      ['sink', sinkPort, sinkApiPort, sinkName],
    ]) {
      const config = join(artifact, `${kind}.yml`);
      await copyFile(join(root, `infra/local/${kind}.yml`), config);
      names.push(name);
      await run(
        'docker',
        [
          'run',
          '-d',
          '--name',
          name,
          '-p',
          `127.0.0.1:${apiPort}:9997`,
          '-p',
          `127.0.0.1:${media}:${kind === 'ingest' ? '8890/udp' : '1935'}`,
          '-v',
          `${config}:/mediamtx.yml:ro`,
          'bluenviron/mediamtx:1.21.0',
        ],
        `start-${kind}`,
      );
      let ready = false;
      for (let attempt = 0; attempt < 50 && !ready; attempt++) {
        try {
          ready = (
            await fetch(`http://127.0.0.1:${apiPort}/v3/config/paths/list`, {
              headers: {
                authorization: `Basic ${Buffer.from('qa-admin:qa-admin-not-production').toString('base64')}`,
              },
              signal: AbortSignal.timeout(1000),
            })
          ).ok;
        } catch {}
        if (!ready) await delay(200);
      }
      assert.ok(ready, `${kind} readiness`);
    }
    return {
      environment: {
        RELAY_API_URL: `http://127.0.0.1:${relayPort}`,
        RELAY_API_USERNAME: 'qa-admin',
        RELAY_API_PASSWORD: 'qa-admin-not-production',
        INGEST_HOST: '127.0.0.1',
        INGEST_PORT: String(ingestPort),
      },
      async startWorker(baseURL) {
        const team = (shortName) => ({ name: shortName, shortName, color: '#123456' });
        const response = await fetch(`${baseURL}/v1/matches`, {
          method: 'POST',
          headers: {
            authorization: `Bearer ${scoringTestToken}`,
            'content-type': 'application/json',
          },
          body: JSON.stringify({
            id: randomUUID(),
            deviceId: 'fixture-scorer',
            teams: { home: team('HOME'), away: team('AWAY') },
            rules: {
              bestOf: 3,
              pointsToWin: 25,
              decidingPointsToWin: 15,
              winBy: 2,
              pointCap: null,
            },
          }),
          signal: AbortSignal.timeout(5000),
        });
        assert.ok(response.ok, `Create fixture match: ${response.status}`);
        const created = await response.json();
        // One owned request at a time, bounded history, and joined on every exit.
        // Keep only numeric evidence; credentials never enter artifacts.
        statusAbort = new AbortController();
        statusTask = (async () => {
          while (!statusAbort.signal.aborted) {
            const result = await fetch(
              `${baseURL}/v1/matches/${created.snapshot.id}/media/status`,
              {
                headers: { authorization: `Bearer ${created.credential.token}` },
                signal: AbortSignal.any([statusAbort.signal, AbortSignal.timeout(1500)]),
              },
            );
            assert.ok(result.ok, `Read fixture worker status: ${result.status}`);
            const { status } = await result.json();
            recordDecodedVideoEvidence(decodedWindows, status);
            await delay(500, undefined, { signal: statusAbort.signal });
          }
        })().catch((error) => {
          if (!statusAbort.signal.aborted) statusError = error;
        });
        const { ffmpeg, ffprobe, font } = mediaTools();
        worker = spawn(
          process.execPath,
          [
            '--import',
            './apps/home-daemon/node_modules/tsx/dist/loader.mjs',
            'apps/home-daemon/src/index.ts',
          ],
          {
            cwd: root,
            env: {
              ...process.env,
              CONTROL_PLANE_URL: baseURL,
              HOME_TOKEN: 'qa-home-token-not-production',
              WORKER_ID: 'mac',
              OUTPUT_ID: 'local-sink',
              OUTPUT_URL: `rtmp://127.0.0.1:${sinkPort}/live/fixture?user=qa-worker&pass=qa-output-not-production`,
              ENCODER: 'videotoolbox',
              VIDEO_PROFILE: '1080p30',
              SCORE_DIR: join(artifact, 'worker'),
              FFMPEG_PATH: ffmpeg,
              FFPROBE_PATH: ffprobe,
              FONT_PATH: font,
              LOG_LEVEL: 'info',
            },
            stdio: ['ignore', 'ignore', 'ignore'],
          },
        );
        done = new Promise((resolve) => {
          worker.once('error', resolve);
          worker.once('close', resolve);
        });
      },
      async collect() {
        await stopStatus();
        if (statusError) throw statusError;
        const evidence = [...decodedWindows.values()];
        await writeFile(
          join(artifact, 'decoded-video-status.json'),
          JSON.stringify(evidence, null, 2),
        );
        assert.ok(
          evidence.every((sample) => sample.invalidReason === null && sample.completed.valid),
          'Native stream produced invalid decoder telemetry',
        );
        assert.ok(
          evidence.filter(
            ({ ended, completed: window }) =>
              !ended &&
              window.durationMs === 5000 &&
              window.freshFrames >= 120 &&
              window.duplicateFrames === 0 &&
              window.reorderedFrames === 0,
          ).length >= 2,
          'Native stream must report at least two complete decoder windows at >=24 fresh FPS',
        );
        await stopWorker();
        assert.ok(
          (await readFile(join(artifact, 'worker/score.txt'), 'utf8')).includes('HOME 1-0 AWAY'),
          'Worker did not receive the native scoring update',
        );
        // Stopping MediaMTX flushes its final fragmented MP4 before copying.
        await run('docker', ['stop', '-t', '10', sinkName], 'flush-sink');
        const directory = join(artifact, 'sink-recordings');
        await mkdir(directory);
        await run('docker', ['cp', `${sinkName}:/recordings/.`, directory], 'copy-sink');
        const files = [];
        async function walk(path) {
          for (const item of await readdir(path, { withFileTypes: true })) {
            const next = join(path, item.name);
            if (item.isDirectory()) await walk(next);
            else if (item.name.endsWith('.mp4')) files.push(next);
          }
        }
        await walk(directory);
        assert.ok(files.length, 'Worker output recording missing');
        return files;
      },
      stop,
    };
  } catch (error) {
    await stop();
    throw error;
  }
}

export function recordDecodedVideoEvidence(decodedWindows, status) {
  const observation = status.observation;
  const video = observation?.decodedVideo;
  assert.ok(
    !video || (video.invalidReason === null && (!video.completed || video.completed.valid)),
    'Native stream produced invalid decoder telemetry',
  );
  if (video?.completed && status.state === 'producing_output') {
    const key = `${observation.generation}:${observation.attempt}:${video.completed.sequence}`;
    if (!decodedWindows.has(key)) {
      assert.ok(decodedWindows.size < 64, 'Decoder evidence exceeded fixture bound');
      decodedWindows.set(
        key,
        structuredClone({
          generation: observation.generation,
          attempt: observation.attempt,
          ...video,
        }),
      );
    }
  }
}
