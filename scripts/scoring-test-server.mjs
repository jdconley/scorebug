import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const scoringTestToken = 'qa-phone-token-not-production';
const root = fileURLToPath(new URL('..', import.meta.url));

/** Starts a real API on an OS-selected loopback port; owns only this child. */
export async function startScoringTestServer(databasePath) {
  const child = spawn(
    process.execPath,
    [
      '--import',
      './apps/control-plane/node_modules/tsx/dist/loader.mjs',
      'apps/control-plane/src/index.ts',
    ],
    {
      cwd: root,
      env: {
        ...process.env,
        PORT: '0',
        HOST: '127.0.0.1',
        DATABASE_PATH: databasePath,
        PHONE_TOKEN: scoringTestToken,
        HOME_TOKEN: 'qa-home-token-not-production',
        INTERNAL_TOKEN: 'qa-internal-token-not-production',
        LOG_LEVEL: 'info',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  const exited = new Promise((resolve) => child.once('close', resolve));
  async function stop() {
    child.kill('SIGKILL');
    await exited;
  }
  try {
    const baseURL = await new Promise((resolve, reject) => {
      let output = '';
      let errors = '';
      const timer = setTimeout(() => reject(new Error('API readiness timed out')), 20_000);
      child.once('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
      child.once('exit', (code) => {
        clearTimeout(timer);
        reject(new Error(`API exited (${code}): ${errors.slice(-1000)}`));
      });
      child.stderr.on('data', (chunk) => {
        errors = (errors + chunk).slice(-4000);
      });
      child.stdout.on('data', (chunk) => {
        output += chunk;
        const lines = output.split('\n');
        output = lines.pop() ?? '';
        for (const line of lines) {
          try {
            const item = JSON.parse(line);
            if (item.msg === 'control_plane_listening') {
              clearTimeout(timer);
              resolve(`http://127.0.0.1:${item.port}`);
            }
          } catch {
            /* unrelated diagnostic */
          }
        }
      });
    });
    return { baseURL, stop };
  } catch (error) {
    await stop();
    throw error;
  }
}
