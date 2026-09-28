// Bounded real launchd + API + relay + mock RTMP check. No persistent installation.
import assert from 'node:assert/strict';
import { mkdir, writeFile, readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { startDeviceLab, deviceLabOptions } from './device-lab.mjs';
import { generatePlist, validateSettings } from './macos-worker-service.mjs';
import { command, mediaTools } from './media-tools.mjs';
import { nativeScoreTemplate } from './native-score-template.mjs';
import { qualifyScoreTemplate } from './score-template-qualification.mjs';

assert.equal(process.platform, 'darwin');
const root = fileURLToPath(new URL('..', import.meta.url));
const options = deviceLabOptions(process.argv.slice(2));
const { ffmpeg, ffprobe, font } = mediaTools();
const abort = new AbortController();
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => abort.abort());
let lab, publisher, publisherDone, serviceStop, artifact;
const report = {
  scope: 'Compiled macOS launchd worker, real local API/relay/RTMP and proxy MP4',
  passed: false,
};
async function until(check, label, timeout = 25000, cleanup = false) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (!cleanup) abort.signal.throwIfAborted();
    if (await check()) return;
    await delay(200);
  }
  throw new Error(`Timed out: ${label}`);
}
async function run(binary, args, timeout) {
  const result = await command(binary, args, timeout);
  assert(result.ok, `${binary} failed (${result.error}); inspect private service logs`);
  return result.stdout;
}
async function factory(environment, directory) {
  artifact = directory;
  environment = { ...environment };
  for (const key of Object.keys(environment).filter((key) => key.startsWith('SCOREBUG_TEST_'))) {
    assert.equal(environment[key], '', 'Service qualification must not enable worker fixtures');
    delete environment[key];
  }
  validateSettings(environment);
  const privateDir = join(directory, 'launchd');
  await mkdir(privateDir, { mode: 0o700 });
  for (const p of [environment.SCORE_DIR, environment.OUTPUT_RECORDING_DIR])
    await mkdir(p, { recursive: true, mode: 0o700 });
  const opts = {
    repo: root,
    node: process.execPath,
    logs: privateDir,
    env: join(privateDir, 'worker.env'),
    label: `live.scorebug.qa.${randomUUID()}`,
  };
  await writeFile(
    opts.env,
    Object.entries(environment)
      .map(([k, v]) => `${k}=${JSON.stringify(v)}`)
      .join('\n'),
    { mode: 0o600 },
  );
  const plist = join(privateDir, 'worker.plist');
  await writeFile(plist, generatePlist(opts), { mode: 0o600 });
  await run(process.execPath, [
    join(root, 'scripts/macos-worker-service.mjs'),
    'check',
    ...Object.entries(opts).flatMap(([k, v]) => [`--${k}`, v]),
  ]);
  const domain = `gui/${process.getuid()}`,
    target = `${domain}/${opts.label}`;
  let loaded = false,
    stopping,
    close;
  const closed = new Promise((resolve) => {
    close = resolve;
  });
  serviceStop = () =>
    (stopping ??= (async () => {
      if (loaded) {
        const before = await run('/bin/launchctl', ['print', target]);
        const pid = Number(before.match(/\bpid = (\d+)/)?.[1]);
        assert(pid > 1, 'Service supervisor PID unavailable');
        const descendants = [pid];
        for (let i = 0; i < descendants.length; i++) {
          const children = await command('/usr/bin/pgrep', ['-P', String(descendants[i])]);
          assert(children.ok || children.error === '1', 'Cannot inventory owned descendants');
          descendants.push(
            ...children.stdout
              .trim()
              .split(/\s+/)
              .map(Number)
              .filter((n) => n > 1),
          );
        }
        await run('/bin/launchctl', ['bootout', target], 35000);
        await until(
          async () =>
            descendants.every((p) => {
              try {
                process.kill(p, 0);
                return false;
              } catch (e) {
                assert.equal(e.code, 'ESRCH');
                return true;
              }
            }),
          'service and descendants stopped',
          35000,
          true,
        );
        assert(!(await command('/bin/launchctl', ['print', target])).ok, 'Service still loaded');
        const log = await readFile(join(privateDir, 'worker.log'), 'utf8');
        const exits = log.split('\n').flatMap((line) => {
          try {
            const event = JSON.parse(line);
            return event.event === 'macos_worker_exit' ? [event] : [];
          } catch {
            return [];
          }
        });
        assert.equal(
          exits.length,
          1,
          'Expected one observed worker exit, without service restarts',
        );
        assert.equal(exits[0].code, 0, 'Service worker did not exit cleanly');
        assert.equal(exits[0].signal, null, 'Service worker was killed');
        report.service = {
          label: opts.label,
          supervisorPID: pid,
          descendantsRemoved: descendants.length,
          bootedOut: true,
          workerExit: exits[0],
        };
        loaded = false;
      }
      const result = { code: 0, signal: null, forced: false };
      close(result);
      return result;
    })());
  await run('/bin/launchctl', ['bootstrap', domain, plist]);
  loaded = true;
  const ready = until(async () => {
    const log = await readFile(join(privateDir, 'worker.log'), 'utf8').catch(() => '');
    return log.split('\n').some((line) => {
      try {
        return JSON.parse(line).msg === 'worker_processing_capability';
      } catch {
        return false;
      }
    });
  }, 'compiled service readiness');
  ready.catch(() => {});
  return { ready, closed, stop: serviceStop };
}
async function request(path, token, body) {
  const response = await fetch(lab.setup.endpoint + path, {
    method: body ? 'POST' : 'GET',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(5000),
  });
  assert(response.ok, `API ${path} returned ${response.status}`);
  return response.json();
}
try {
  lab = await startDeviceLab(
    { ...options, seedMatch: false },
    { signal: abort.signal, workerFactory: factory },
  );
  console.log(JSON.stringify({ artifact, phase: 'launchd ready' }));
  const installation = lab.setup.installationToken,
    gameId = randomUUID();
  const team = (shortName) => ({ name: shortName, shortName, color: '#123456' });
  const created = await request('/v1/matches', installation, {
    id: gameId,
    deviceId: 'scorer',
    teams: { home: team('HOME'), away: team('AWAY') },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const base = `/v1/matches/${gameId}`;
  const capture = await request(`${base}/join`, installation, {
    deviceId: 'camera',
    role: 'capture',
  });
  await request(`${base}/media/recordings`, capture.credential.token, {
    recordingId: 'service-fixture',
    sequence: 0,
    status: 'recording',
    startedAt: new Date().toISOString(),
  });
  const mediaCommand = (generation, operation) =>
    request(`${base}/media/commands`, installation, {
      commandId: randomUUID(),
      gameId,
      expectedGeneration: generation,
      issuedAt: new Date().toISOString(),
      operation,
    });
  await mediaCommand(0, {
    type: 'start',
    selection: {
      workerId: 'mac',
      outputId: 'local-sink',
      captureDeviceId: 'camera',
      recordingId: 'service-fixture',
    },
  });
  const access = await request(`${base}/media/publish`, capture.credential.token, {
    recordingId: 'service-fixture',
    generation: 1,
  });
  publisher = spawn(
    ffmpeg,
    [
      '-nostdin',
      '-v',
      'error',
      '-re',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=640x360:rate=30',
      '-re',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=1000:sample_rate=48000',
      '-t',
      '45',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-tune',
      'zerolatency',
      '-g',
      '60',
      '-b:v',
      '700k',
      '-c:a',
      'aac',
      '-b:a',
      '96k',
      '-f',
      'mpegts',
      access.publishUrl,
    ],
    { stdio: 'ignore' },
  );
  publisherDone = new Promise((resolve) => {
    publisher.once('error', () => resolve());
    publisher.once('close', resolve);
  });
  const status = async () =>
    (await request(`${base}/media/status`, created.credential.token)).status;
  await until(async () => (await status()).state === 'producing_output', 'service media output');
  await request(`${base}/commands`, created.credential.token, {
    commandId: randomUUID(),
    gameId,
    deviceId: 'scorer',
    expectedRevision: 1,
    scorerEpoch: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'award_point', side: 'home' },
  });
  await until(
    async () =>
      (await readFile(join(artifact, 'worker/score.txt'), 'utf8')).includes('HOME 1-0 AWAY'),
    'score update',
  );
  await delay(6000);
  await mediaCommand(1, { type: 'stop' });
  await lab.stop();
  await serviceStop();
  const files = await readdir(artifact, { recursive: true });
  const outputs = files.filter((p) => p.endsWith('/direct.mp4') || p.endsWith('/overlay.mp4'));
  assert.equal(outputs.length, 2, 'Both mock RTMP and optional proxy MP4 required');
  const pixels = (args) => execFileSync(ffmpeg, args, { timeout: 30000, maxBuffer: 1024 * 1024 });
  const template = (score) => {
    const t = nativeScoreTemplate({ profile: '1080p30', font, score });
    return pixels([
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      t.input,
      '-vf',
      t.filter,
      '-frames:v',
      '1',
      '-f',
      'rawvideo',
      'pipe:1',
    ]);
  };
  const expected = template('1-0'),
    alternative = template('0-0');
  report.outputs = [];
  for (const file of outputs) {
    const path = join(artifact, file);
    const data = JSON.parse(
      await run(ffprobe, ['-v', 'error', '-show_streams', '-of', 'json', path]),
    );
    const video = data.streams.find((s) => s.codec_type === 'video');
    const audio = data.streams.find((s) => s.codec_type === 'audio');
    assert.equal(video?.codec_name, 'h264');
    assert.equal(audio?.codec_name, 'aac');
    assert(Number(video.duration) >= 5);
    assert(Number(audio.duration) >= 5);
    const endOffsetMs =
      1000 *
      (Number(audio.start_time ?? 0) +
        Number(audio.duration) -
        Number(video.start_time ?? 0) -
        Number(video.duration));
    assert(Math.abs(endOffsetMs) <= 100, 'Output A/V ends differ by more than 100 ms');
    await run(ffmpeg, ['-nostdin', '-v', 'error', '-xerror', '-i', path, '-f', 'null', '-'], 60000);
    const actual = pixels([
      '-v',
      'error',
      '-sseof',
      '-4',
      '-i',
      path,
      '-vf',
      'format=gray,crop=750:120:0:930',
      '-frames:v',
      '1',
      '-f',
      'rawvideo',
      'pipe:1',
    ]);
    qualifyScoreTemplate({ actual, expected, alternative });
    report.outputs.push({
      file,
      videoSeconds: Number(video.duration),
      audioSeconds: Number(audio.duration),
      decoded: true,
      endOffsetMs,
      sampledFinalScore: '1-0',
    });
  }
  report.passed = true;
} catch (error) {
  report.error = error.message;
  process.exitCode = 1;
} finally {
  try {
    if (publisher?.pid) {
      const exited = async () => publisher.exitCode !== null || publisher.signalCode !== null;
      if (!(await exited())) publisher.kill('SIGTERM');
      try {
        await until(exited, 'publisher exit', 5000, true);
      } catch {
        publisher.kill('SIGKILL');
        await until(exited, 'publisher forced exit', 3000, true);
      }
    }
    if (publisherDone) await publisherDone;
  } catch (error) {
    report.publisherCleanupError = error.message;
    report.passed = false;
    process.exitCode = 1;
  }
  try {
    await lab?.stop();
    await serviceStop?.();
  } catch (error) {
    report.cleanupError = error.message;
    report.passed = false;
    process.exitCode = 1;
  }
  if (artifact)
    await writeFile(
      join(artifact, 'macos-service-result.json'),
      JSON.stringify(report, null, 2) + '\n',
      { mode: 0o600 },
    );
  console.log(JSON.stringify({ artifact, ...report }));
}
