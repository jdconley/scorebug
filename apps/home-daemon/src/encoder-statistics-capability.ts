import { spawn } from 'node:child_process';
export type EncoderStatisticsCapability = {
  available: boolean;
  reason:
    | 'supported'
    | 'unsupported'
    | 'unsupported_platform'
    | 'spawn'
    | 'exit'
    | 'timeout'
    | 'output_limit'
    | 'cancelled';
};
/** Option availability only, never encoder compatibility or capacity. No media input or destination. */
export async function probeEncoderStatistics(
  binary: string,
  options: { timeoutMs?: number; signal?: AbortSignal } = {},
): Promise<EncoderStatisticsCapability> {
  const timeoutMs = options.timeoutMs ?? 3000;
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30_000)
    throw new RangeError('invalid_probe_timeout');
  if (options.signal?.aborted) return { available: false, reason: 'cancelled' };
  // Native Windows needs job-object ownership before probing configured wrappers.
  // WSL uses the POSIX path; publication itself does not depend on this optional probe.
  if (process.platform === 'win32') return { available: false, reason: 'unsupported_platform' };
  return new Promise((resolve) => {
    let reason: EncoderStatisticsCapability['reason'] | undefined;
    let stdout = '',
      stderr = '',
      bytes = 0;
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(binary, ['-hide_banner', '-h', 'full'], {
        stdio: ['ignore', 'pipe', 'pipe'],
        detached: true,
      });
    } catch {
      resolve({ available: false, reason: 'spawn' });
      return;
    }
    const killOwnedGroup = () => {
      if (child.pid !== undefined) {
        try {
          process.kill(-child.pid, 'SIGKILL');
        } catch {
          /* Group already reaped. */
        }
      }
      child.kill('SIGKILL');
    };
    const stop = (failure: EncoderStatisticsCapability['reason']) => {
      reason ??= failure;
      killOwnedGroup();
    };
    const cancel = () => stop('cancelled');
    const timer = setTimeout(() => stop('timeout'), timeoutMs);
    options.signal?.addEventListener('abort', cancel, { once: true });
    const receive = (chunk: Buffer, stream: 'stdout' | 'stderr') => {
      if (reason) return;
      bytes += chunk.length;
      if (bytes > 4 * 1024 * 1024) {
        stop('output_limit');
        return;
      }
      if (stream === 'stdout') stdout += chunk.toString('utf8');
      else stderr += chunk.toString('utf8');
    };
    child.stdout!.on('data', (chunk) => receive(chunk, 'stdout'));
    child.stderr!.on('data', (chunk) => receive(chunk, 'stderr'));
    child.stdout!.on('error', () => stop('exit'));
    child.stderr!.on('error', () => stop('exit'));
    child.on('error', () => {
      reason ??= 'spawn';
    });
    child.once('close', (code) => {
      killOwnedGroup();
      clearTimeout(timer);
      options.signal?.removeEventListener('abort', cancel);
      if (!reason && code !== 0) reason = 'exit';
      if (!reason) {
        const help = stdout + '\n' + stderr;
        const supported = ['pre', 'post', 'pre_fmt', 'post_fmt'].every((key) =>
          new RegExp(`^\\s*-stats_enc_${key}(?:\\s|\\[|:)`, 'm').test(help),
        );
        reason = supported ? 'supported' : 'unsupported';
      }
      resolve({ available: reason === 'supported', reason });
    });
    if (options.signal?.aborted) cancel();
  });
}
