import { spawn } from 'node:child_process';
import type { WorkerCapabilities } from '@scorebug/protocol';
import { videoProfiles, type Config } from './config.js';
import { videoEncoderArgs } from './pipeline.js';

/** Local H264/AAC initialization only. No network, user media, or performance qualification. */
export async function probeBackend(
  config: Config,
  options: { signal?: AbortSignal; timeoutMs?: number } = {},
): Promise<WorkerCapabilities> {
  const result: WorkerCapabilities = {
    version: 1,
    outputId: config.OUTPUT_ID,
    encoder: config.ENCODER,
    outputProfile: config.VIDEO_PROFILE,
    outputMode: config.OUTPUT_MODE,
    startup: 'failed',
    sustainedPerformance: 'unqualified',
  };
  if (options.signal?.aborted) return { ...result, startup: 'cancelled' };
  if (process.platform === 'win32') return { ...result, startup: 'unsupported_platform' };
  const timeout = options.timeoutMs ?? 10000;
  if (!Number.isInteger(timeout) || timeout < 1 || timeout > 30000)
    throw new Error('invalid_probe_timeout');
  const profile = videoProfiles[config.VIDEO_PROFILE];
  return new Promise((resolve) => {
    let failure: WorkerCapabilities['startup'] | undefined,
      bytes = 0;
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(
        config.FFMPEG_PATH,
        [
          '-nostdin',
          '-hide_banner',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          `testsrc2=size=${profile.width}x${profile.height}:rate=30`,
          '-f',
          'lavfi',
          '-i',
          'anullsrc=r=48000:cl=stereo',
          '-t',
          '0.2',
          ...videoEncoderArgs(config.ENCODER),
          '-b:v',
          `${profile.bitrateKbps}k`,
          '-pix_fmt',
          'yuv420p',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-f',
          'mpegts',
          '-y',
          '/dev/null',
        ],
        { detached: true, stdio: ['ignore', 'pipe', 'pipe'] },
      );
    } catch {
      resolve(result);
      return;
    }
    const kill = () => {
      if (child.pid) {
        try {
          process.kill(-child.pid, 'SIGKILL');
        } catch {}
      }
      child.kill('SIGKILL');
    };
    const stop = (reason: WorkerCapabilities['startup']) => {
      failure ??= reason;
      kill();
    };
    const cancel = () => stop('cancelled');
    const timer = setTimeout(() => stop('timeout'), timeout);
    options.signal?.addEventListener('abort', cancel, { once: true });
    const receive = (data: Buffer) => {
      bytes += data.length;
      if (bytes > 128 * 1024) stop('failed');
    };
    child.stdout?.on('data', receive);
    child.stderr?.on('data', receive);
    child.stdout?.on('error', () => stop('failed'));
    child.stderr?.on('error', () => stop('failed'));
    child.on('error', () => {
      failure ??= 'failed';
    });
    child.once('close', (code) => {
      kill();
      clearTimeout(timer);
      options.signal?.removeEventListener('abort', cancel);
      resolve({ ...result, startup: failure ?? (code === 0 ? 'passed' : 'failed') });
    });
    if (options.signal?.aborted) cancel();
  });
}
