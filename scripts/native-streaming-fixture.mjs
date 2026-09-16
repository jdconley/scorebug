import assert from 'node:assert/strict';
import { recordReceiverProbeEvidence } from './receiver-probe-evidence.mjs';
import { createUDPImpairmentProxy } from './udp-impairment.mjs';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:net';
import { createSocket } from 'node:dgram';
import { copyFile, mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { mediaTools } from './media-tools.mjs';
import { observeNativeWorkerEvidence } from './native-worker-evidence.mjs';
import { startDirectRTMPRecorder } from './direct-rtmp-recorder.mjs';
import { scoringTestToken } from './scoring-test-server.mjs';
import { immutableWindow, remoteWindowIdentity } from './worker-report-age-qualification.mjs';
import { recordWorkerProcessingEvidence } from './worker-processing-qualification.mjs';
import { recordWorkerPublicationEvidence } from './worker-publication-evidence.mjs';
import { recordPublishingAttemptEvidence } from './publishing-attempt-evidence.mjs';
import { saveNativeStatusEvidence } from './native-status-evidence.mjs';

/** Owned, loopback-only proxy fixtures. No ambient worker or relay is used. */
export async function nativeStreamingFixture({
  artifact,
  root,
  run,
  decodedWindowLimit = 64,
  requirePublication = false,
  requireReceiverProbe = false,
  uplinkProfile = null,
  liveProfile = '1080p30',
  decoderThreading = 'automatic',
  publishPeerLatencyMs,
  publishPacing,
}) {
  assert.ok(
    publishPeerLatencyMs === undefined ||
      (Number.isInteger(publishPeerLatencyMs) &&
        publishPeerLatencyMs >= 120 &&
        publishPeerLatencyMs <= 2000),
    'Unsupported fixture publish peer latency',
  );
  assert.ok(
    publishPacing === undefined || publishPacing === 'relative',
    'Unsupported fixture publish pacing',
  );
  assert.ok(['1080p30', '540p30', '360p30'].includes(liveProfile));
  assert.ok(['automatic', 'slice'].includes(decoderThreading), 'Unsupported decoder threading');
  assert.ok([64, 128].includes(decodedWindowLimit), 'Unsupported decoder evidence bound');
  assert.ok(
    uplinkProfile === null || ['passthrough', 'rate4m'].includes(uplinkProfile),
    'Unsupported uplink profile',
  );
  assert.equal(typeof requireReceiverProbe, 'boolean');
  assert.ok(!requireReceiverProbe || requirePublication);
  const names = [];
  let worker, done, workerEvidence, directRecorder, uplink;
  const useDirectRecorder = process.env.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1';
  let matchID;
  let statusTask, statusAbort, statusError;
  const decodedWindows = new Map();
  const publications = new Map();
  const receiverProbes = new Map();
  const workerPublications = new Map();
  const workerProcessing = new Map();
  async function stopStatus() {
    statusAbort?.abort();
    await statusTask;
  }
  async function saveStatus() {
    await saveNativeStatusEvidence({
      artifact,
      decodedWindowLimit,
      requirePublication,
      requireReceiverProbe,
      receiverProbes,
      collectorError: statusError,
      publications,
      workerPublications,
      workerProcessing,
      decodedWindows,
    });
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
    if (!worker) {
      await workerEvidence?.save();
      return;
    }
    workerEvidence.signal('SIGTERM');
    await Promise.race([done, delay(5000)]);
    if (worker.exitCode === null && worker.signalCode === null) workerEvidence.signal('SIGKILL');
    await done;
    worker = undefined;
    await workerEvidence.save();
  }
  async function stopUplink() {
    if (!uplink) return;
    try {
      await uplink.close();
    } finally {
      await writeFile(
        join(artifact, 'uplink-proxy.json'),
        JSON.stringify(uplink.snapshot(), null, 2),
      );
    }
  }
  async function stop() {
    const errors = [];
    try {
      await stopStatus();
    } catch (error) {
      errors.push(error);
    }
    try {
      await saveStatus();
    } catch (error) {
      errors.push(error);
    }
    try {
      await stopWorker();
    } catch (error) {
      errors.push(error);
    }
    try {
      await stopUplink();
    } catch (error) {
      errors.push(error);
    }
    try {
      await directRecorder?.stop();
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
    let ingestImage = 'bluenviron/mediamtx:1.21.0';
    if (requirePublication) {
      const tag = requireReceiverProbe
        ? 'scorebug/ingest:receiver-probe-v1'
        : 'scorebug/ingest:recovery-v1';
      ingestImage = await run(
        'docker',
        ['image', 'inspect', tag, '--format', '{{.Id}}'],
        'publication-relay-image',
      );
      assert.match(ingestImage, /^sha256:[0-9a-f]{64}$/);
      await writeFile(
        join(artifact, 'publication-relay-image.json'),
        JSON.stringify({ tag, id: ingestImage }, null, 2),
      );
    }
    const ingestPort = await port(true),
      relayPort = await port();
    const sinkPort = await port(),
      sinkApiPort = await port();
    const sinkName = `scorebug-native-sink-${randomUUID()}`;
    for (const [kind, media, apiPort, name] of [
      ['ingest', ingestPort, relayPort, `scorebug-native-ingest-${randomUUID()}`],
      ['sink', sinkPort, sinkApiPort, sinkName],
    ].filter(([kind]) => !useDirectRecorder || kind !== 'sink')) {
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
          kind === 'ingest' ? ingestImage : 'bluenviron/mediamtx:1.21.0',
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
    if (uplinkProfile)
      uplink = await createUDPImpairmentProxy({
        receiverPort: ingestPort,
        forward: { recordTimeline: true },
        reverse: { recordTimeline: true },
        ...(uplinkProfile === 'rate4m'
          ? {
              forwardRateSchedule: [
                { atMilliseconds: 0, rateBitsPerSecond: null },
                { atMilliseconds: 60000, rateBitsPerSecond: 4000000 },
                { atMilliseconds: 120000, rateBitsPerSecond: null },
              ],
            }
          : {}),
      });
    if (useDirectRecorder)
      directRecorder = await startDirectRTMPRecorder({
        artifact,
        ffmpeg: mediaTools().ffmpeg,
        port: sinkPort,
      });
    return {
      publishingProxyPort: uplink?.port,
      get matchID() {
        return matchID;
      },
      environment: {
        RELAY_API_URL: `http://127.0.0.1:${relayPort}`,
        RELAY_API_USERNAME: 'qa-admin',
        RELAY_API_PASSWORD: 'qa-admin-not-production',
        INGEST_HOST: '127.0.0.1',
        INGEST_PORT: String(ingestPort),
        SRT_PUBLISH_PACING: publishPacing,
        SRT_PUBLISH_PEER_LATENCY_MS:
          publishPeerLatencyMs === undefined ? undefined : String(publishPeerLatencyMs),
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
        matchID = created.snapshot.id;
        // One owned request at a time, bounded history, and joined on every exit.
        // Keep only scoped scalar evidence; credentials never enter artifacts.
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
            recordDecodedVideoEvidence(decodedWindows, status, decodedWindowLimit);
            recordWorkerProcessingEvidence(workerProcessing, status, decodedWindowLimit);
            if (status.generation > 0 && status.workerId) {
              const mediaResponse = await fetch(`${baseURL}/v1/matches/${matchID}/media`, {
                headers: { authorization: `Bearer ${created.credential.token}` },
                signal: AbortSignal.any([statusAbort.signal, AbortSignal.timeout(1500)]),
              });
              assert.ok(mediaResponse.ok, 'Read publication scope');
              const { snapshot } = await mediaResponse.json();
              if (
                snapshot.broadcast.desired === 'running' &&
                snapshot.broadcast.generation === status.generation &&
                snapshot.broadcast.selection
              ) {
                const receiverRequestStarted = performance.now();
                const connections = await fetch(
                  `http://127.0.0.1:${relayPort}/v3/srtconns/list?itemsPerPage=100&page=0`,
                  {
                    headers: {
                      authorization: `Basic ${Buffer.from('qa-admin:qa-admin-not-production').toString('base64')}`,
                    },
                    signal: AbortSignal.any([statusAbort.signal, AbortSignal.timeout(1500)]),
                  },
                );
                assert.ok(connections.ok, 'Read private publication evidence');
                const listing = await connections.json();
                if (requireReceiverProbe)
                  recordReceiverProbeEvidence(
                    receiverProbes,
                    listing,
                    {
                      gameId: matchID,
                      generation: snapshot.broadcast.generation,
                      selection: snapshot.broadcast.selection,
                    },
                    scoringTestToken,
                    {
                      startedAtMilliseconds: receiverRequestStarted,
                      receivedAtMilliseconds: performance.now(),
                    },
                  );
                recordPublishingAttemptEvidence(
                  publications,
                  listing,
                  {
                    gameId: matchID,
                    generation: snapshot.broadcast.generation,
                    selection: snapshot.broadcast.selection,
                  },
                  scoringTestToken,
                );
                if (requirePublication)
                  recordWorkerPublicationEvidence(
                    workerPublications,
                    status,
                    listing,
                    {
                      gameId: matchID,
                      generation: snapshot.broadcast.generation,
                      selection: snapshot.broadcast.selection,
                    },
                    scoringTestToken,
                  );
              }
            }
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
              OUTPUT_URL:
                directRecorder?.url ??
                `rtmp://127.0.0.1:${sinkPort}/live/fixture?user=qa-worker&pass=qa-output-not-production`,
              ENCODER: 'videotoolbox',
              DECODER_THREADING: decoderThreading,
              WORKER_REPORT_INTERVAL_MS:
                process.env.SCOREBUG_TEST_NATIVE_QUALITY === '1' ? '100' : '1000',
              VIDEO_PROFILE: liveProfile,
              SCORE_DIR: join(artifact, 'worker'),
              FFMPEG_PATH: ffmpeg,
              FFPROBE_PATH: ffprobe,
              FONT_PATH: font,
              LOG_LEVEL: 'info',
              SCOREBUG_TEST_WORKER_TERMINAL: '1',
            },
            stdio: ['ignore', 'pipe', 'ignore'],
          },
        );
        workerEvidence = observeNativeWorkerEvidence(worker, (evidence) =>
          writeFile(
            join(artifact, 'worker-terminal-evidence.json'),
            JSON.stringify(evidence, null, 2),
          ),
        );
        done = workerEvidence.closed;
      },
      async collect() {
        await stopStatus();
        await saveStatus();
        const evidence = [...decodedWindows.values()];
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
        await stopUplink();
        assert.ok(
          (await readFile(join(artifact, 'worker/score.txt'), 'utf8')).includes('HOME 1-0 AWAY'),
          'Worker did not receive the native scoring update',
        );
        if (directRecorder) return [await directRecorder.finish()];
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
    try {
      await stop();
    } catch (cleanupError) {
      throw new AggregateError([error, cleanupError], 'Native fixture setup and cleanup failed');
    }
    throw error;
  }
}

export function recordDecodedVideoEvidence(decodedWindows, status, decodedWindowLimit = 64) {
  assert.ok([64, 128].includes(decodedWindowLimit), 'Unsupported decoder evidence bound');
  const observation = status.observation;
  const video = observation?.decodedVideo;
  assert.ok(
    !video || (video.invalidReason === null && (!video.completed || video.completed.valid)),
    'Native stream produced invalid decoder telemetry',
  );
  if (video?.completed) {
    assert.equal(observation.gameId, status.gameId, 'Decoder game scope mismatch');
    assert.equal(observation.generation, status.generation, 'Decoder generation scope mismatch');
    const sample = structuredClone({
      gameId: status.gameId,
      generation: observation.generation,
      workerId: status.workerId,
      attempt: observation.attempt,
      decodedVideoAgeUpperBoundMs: status.decodedVideoAgeUpperBoundMs ?? null,
      ...video,
    });
    const key = remoteWindowIdentity(sample);
    const prior = decodedWindows.get(key);
    if (prior) {
      assert.deepEqual(
        immutableWindow(sample.completed),
        immutableWindow(prior.completed),
        'Reused decoder identity changed immutable window content',
      );
    }
    // Stopping/ended observations still undergo invalidity and immutable-reuse
    // checks, but cannot replace the usable sample this collector witnessed.
    if (status.state !== 'producing_output' || video.ended) return;
    if (prior) {
      if (prior.decodedVideoAgeUpperBoundMs == null && sample.decodedVideoAgeUpperBoundMs != null)
        decodedWindows.set(key, sample);
    } else {
      assert.ok(
        decodedWindows.size < decodedWindowLimit,
        'Decoder evidence exceeded fixture bound',
      );
      decodedWindows.set(key, sample);
    }
  }
}
