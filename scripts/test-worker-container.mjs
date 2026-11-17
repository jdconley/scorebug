import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { chmod, mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { command } from './media-tools.mjs';
import { cancellation } from './cancellation.mjs';

const image = process.argv[2];
assert.ok(image && !image.startsWith('-'), 'Supply a built worker image name');
const name = `scorebug-worker-image-${randomUUID()}`;
const checkCancellation = cancellation();
const artifactRoot = fileURLToPath(new URL('../artifacts/qa/', import.meta.url));
async function docker(args, label, timeout = 30_000) {
  checkCancellation();
  const result = await command('docker', args, timeout);
  if (!result.ok) {
    await mkdir(artifactRoot, { recursive: true });
    const artifact = await mkdtemp(join(artifactRoot, 'worker-container-failure-'));
    await chmod(artifact, 0o700);
    await writeFile(
      join(artifact, 'diagnostic.json'),
      JSON.stringify({ label, ...result }, null, 2),
      { mode: 0o600 },
    );
    assert.fail(`${label} failed; private diagnostic: ${artifact}`);
  }
  return result.stdout;
}
try {
  await docker(
    [
      'run',
      '-d',
      '--name',
      name,
      '--network',
      'none',
      // Run unprivileged: bundled fonts and assets must be readable.
      '--user',
      '1000:1000',
      '--cap-drop',
      'ALL',
      '--security-opt',
      'no-new-privileges:true',
      '-e',
      'CONTROL_PLANE_URL=http://127.0.0.1:9',
      '-e',
      'HOME_TOKEN=qa-home-token-not-production',
      '-e',
      'WORKER_ID=match',
      '-e',
      'OUTPUT_ID=youtube',
      image,
    ],
    'worker container startup',
  );
  let started = false;
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    assert.equal(
      (await docker(['inspect', '--format', '{{.State.Running}}', name], 'container state')).trim(),
      'true',
    );
    const logs = await docker(['logs', name], 'worker logs');
    if (logs.includes('worker_started') && logs.includes('control_unavailable')) {
      started = true;
      break;
    }
    await delay(200);
  }
  assert.ok(started, 'Compiled worker did not start and report unavailable control');
  // Run the production pipeline module inside the final image. No network is available.
  const program = `
    import assert from 'node:assert/strict';
    import { execFile } from 'node:child_process';
    import { promisify } from 'node:util';
    import { writeFile } from 'node:fs/promises';
    import { startPipeline } from './apps/home-daemon/dist/pipeline.js';
    import { createLogger } from './apps/home-daemon/dist/logger.js';
    const exec = promisify(execFile);
    const protocols = await exec('ffmpeg', ['-hide_banner', '-protocols']);
    assert.match(protocols.stdout, /^\\s+rtmps\\s*$/m);
    await exec('ffmpeg', ['-v','error','-f','lavfi','-i','testsrc2=size=320x180:rate=30',
      '-f','lavfi','-i','sine=sample_rate=48000','-t','2','-c:v','libx264','-preset','ultrafast',
      '-c:a','aac','/tmp/source.mp4']);
    // The real overlay contract: worker-serialized scorebug JSON, rendered in-image
    // with the bundled font (the image has no system fonts) and fed to FFmpeg.
    await writeFile('/tmp/scorebug.json', JSON.stringify({ style: 'bar', label: null, bestOf: 3,
      teams: { home: { name: 'Home', shortName: 'HOM', color: '#1D4ED8' },
               away: { name: 'Away', shortName: 'AWY', color: '#F97316' } },
      score: { home: 18, away: 15, set: 3, homeSets: 1, awaySets: 1 },
      completedSets: [], serving: null }));
    // Pace the finite input like a live publisher. With copyts, a clip finishing
    // before the first periodic progress report may only report out_time_us=0.
    await writeFile('/tmp/ffmpeg-paced', '#!/bin/sh\\nexec ffmpeg -re "$@"\\n', { mode: 0o700 });
    // The FLV FFmpeg would publish over RTMPS, written to a file to inspect.
    let progressed = false;
    const pipeline = startPipeline({ gameId:'image-fixture', pullUrl:'/tmp/source.mp4',
      publishUrl:'/tmp/output.flv', scoreFile:'/tmp/scorebug.json',
      profile:{width:1280,height:720,fps:30,bitrateKbps:3000}, ffmpegPath:'/tmp/ffmpeg-paced' }, createLogger('error'), {
        onProgress: p => { if (p.frame > 0 && p.outTimeUs > 0) progressed = true; }
      });
    const exited = await pipeline.waitExit();
    assert.equal(exited.code, 0); assert.ok(progressed);
    const path = '/tmp/output.flv';
    const probe = JSON.parse((await exec('ffprobe', ['-v','error','-show_streams','-of','json',path])).stdout);
    assert.ok(probe.streams.some(s => s.codec_type === 'video' && s.width === 1280 && s.height === 720));
    assert.ok(probe.streams.some(s => s.codec_type === 'audio'));
    await exec('ffmpeg', ['-v','error','-xerror','-i',path,'-map','0:v:0','-map','0:a:0','-f','null','-']);
    // Bar style score box at 720p: 1080p (432..528, 76..156) scaled by 2/3. Testsrc2
    // is busy, so require the box's flat light gray on the first and last frames.
    for (const position of [[], ['-sseof','-0.2']]) {
      const box = await exec('ffmpeg', ['-v','error',...position,'-i',path,'-vf','crop=40:30:300:56,format=gray',
        '-frames:v','1','-f','rawvideo','-'], { encoding: 'buffer' });
      assert.ok([...box.stdout].filter(v => v > 200).length > 600, 'scorebug missing from ' + path);
    }
    console.log('compiled_pipeline_decoded');
  `;
  const result = await docker(
    ['exec', name, 'node', '--input-type=module', '-e', program],
    'compiled media pipeline',
    45_000,
  );
  assert.ok(result.includes('compiled_pipeline_decoded'));
  await docker(['stop', '-t', '5', name], 'graceful container stop');
  assert.equal(
    (await docker(['inspect', '--format', '{{.State.ExitCode}}', name], 'container exit')).trim(),
    '0',
  );
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  if (!(await command('docker', ['rm', '-f', name], 30_000)).ok) {
    console.error(`Owned worker container cleanup failed: ${name}`);
    process.exitCode = 1;
  }
}
if (!process.exitCode)
  console.log(
    'PASS: final worker image starts, compiled software pipeline encodes/decodes audio/video with overlay, and container stops cleanly; owned container removed.',
  );
