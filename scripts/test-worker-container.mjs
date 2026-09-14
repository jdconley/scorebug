import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { command } from './media-tools.mjs';
import { cancellation } from './cancellation.mjs';

const image = process.argv[2];
assert.ok(image && !image.startsWith('-'), 'Supply a built worker image name');
const name = `scorebug-worker-image-${randomUUID()}`;
const checkCancellation = cancellation();
async function docker(args, label, timeout = 30_000) {
  checkCancellation();
  const result = await command('docker', args, timeout);
  assert.ok(result.ok, `${label} failed`);
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
      '-e',
      'CONTROL_PLANE_URL=http://127.0.0.1:9',
      '-e',
      'HOME_TOKEN=qa-home-token-not-production',
      '-e',
      'WORKER_ID=container-fixture',
      '-e',
      'OUTPUT_ID=local-sink',
      '-e',
      'OUTPUT_URL=rtmp://127.0.0.1:1935/live/fixture',
      '-e',
      'ENCODER=software',
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
    assert.match(protocols.stdout, /^\\s+srt\\s*$/m);
    await exec('ffmpeg', ['-v','error','-f','lavfi','-i','testsrc2=size=320x180:rate=30',
      '-f','lavfi','-i','sine=sample_rate=48000','-t','2','-c:v','libx264','-preset','ultrafast',
      '-c:a','aac','/tmp/source.mp4']);
    await writeFile('/tmp/score.txt', 'HOME 0-0 AWAY');
    let progressed = false;
    const pipeline = startPipeline({ gameId:'image-fixture', pullUrl:'/tmp/source.mp4',
      publishUrl:'/tmp/output.flv', scoreFile:'/tmp/score.txt', nvenc:false, encoder:'software',
      profile:{width:1280,height:720,fps:30,bitrateKbps:3000} }, createLogger('error'), {
        onProgress: p => { if (p.frame > 0 && p.outTimeUs > 0) progressed = true; }
      });
    const exited = await pipeline.waitExit();
    assert.equal(exited.code, 0); assert.ok(progressed);
    const probe = JSON.parse((await exec('ffprobe', ['-v','error','-show_streams','-of','json','/tmp/output.flv'])).stdout);
    assert.ok(probe.streams.some(s => s.codec_type === 'video' && s.width === 1280 && s.height === 720));
    assert.ok(probe.streams.some(s => s.codec_type === 'audio'));
    await exec('ffmpeg', ['-v','error','-xerror','-i','/tmp/output.flv','-map','0:v:0','-map','0:a:0','-f','null','-']);
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
