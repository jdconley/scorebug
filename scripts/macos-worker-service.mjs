#!/usr/bin/env node
// launchd stores paths only. Secrets are read by the foreground supervisor.
import { readFile, writeFile, lstat, access, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { isAbsolute, join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { parseEnv } from 'node:util';
import { pathToFileURL } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';

const required = [
  'CONTROL_PLANE_URL',
  'HOME_TOKEN',
  'WORKER_ID',
  'OUTPUT_ID',
  'OUTPUT_MODE',
  'ENCODER',
  'VIDEO_PROFILE',
  'FFMPEG_PATH',
  'FFPROBE_PATH',
  'FONT_PATH',
  'SCORE_DIR',
];
const allowed = new Set([
  ...required,
  'OUTPUT_URL',
  'OUTPUT_RECORDING_DIR',
  'LOG_LEVEL',
  'WORKER_REPORT_INTERVAL_MS',
  'WORKER_PROCESSING',
  'DECODER_THREADING',
]);
function requireValue(condition, key) {
  if (!condition) throw new Error(`Invalid or missing ${key}`);
}
function absolute(value, key) {
  requireValue(
    typeof value === 'string' && isAbsolute(value) && !/[\x00-\x1f\x7f]/.test(value),
    key,
  );
}
function url(value, protocols, key) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`Invalid or missing ${key}`);
  }
  requireValue(protocols.includes(parsed.protocol) && parsed.hostname, key);
}
export function validateSettings(env) {
  for (const key of Object.keys(env)) requireValue(allowed.has(key), 'environment key');
  for (const key of required) requireValue(typeof env[key] === 'string' && env[key].trim(), key);
  requireValue(env.HOME_TOKEN.length >= 16, 'HOME_TOKEN');
  for (const key of ['WORKER_ID', 'OUTPUT_ID'])
    requireValue(/^[A-Za-z0-9_-]{1,128}$/.test(env[key]), key);
  url(env.CONTROL_PLANE_URL, ['http:', 'https:'], 'CONTROL_PLANE_URL');
  requireValue(['rtmp', 'record', 'rtmp+record'].includes(env.OUTPUT_MODE), 'OUTPUT_MODE');
  if (env.OUTPUT_MODE !== 'record' || env.OUTPUT_URL !== undefined)
    url(env.OUTPUT_URL, ['rtmp:', 'rtmps:'], 'OUTPUT_URL');
  if (env.OUTPUT_MODE !== 'rtmp' || env.OUTPUT_RECORDING_DIR !== undefined)
    absolute(env.OUTPUT_RECORDING_DIR, 'OUTPUT_RECORDING_DIR');
  requireValue(['software', 'videotoolbox', 'nvenc'].includes(env.ENCODER), 'ENCODER');
  requireValue(
    ['240p30', '360p30', '540p30', '720p30', '1080p30', '2160p30'].includes(env.VIDEO_PROFILE),
    'VIDEO_PROFILE',
  );
  for (const key of ['FFMPEG_PATH', 'FFPROBE_PATH', 'FONT_PATH', 'SCORE_DIR'])
    absolute(env[key], key);
  if (env.LOG_LEVEL)
    requireValue(['debug', 'info', 'warn', 'error'].includes(env.LOG_LEVEL), 'LOG_LEVEL');
  if (env.WORKER_PROCESSING)
    requireValue(['auto', 'off'].includes(env.WORKER_PROCESSING), 'WORKER_PROCESSING');
  if (env.DECODER_THREADING)
    requireValue(['automatic', 'slice'].includes(env.DECODER_THREADING), 'DECODER_THREADING');
  if (env.WORKER_REPORT_INTERVAL_MS)
    requireValue(
      /^\d+$/.test(env.WORKER_REPORT_INTERVAL_MS) &&
        Number(env.WORKER_REPORT_INTERVAL_MS) >= 100 &&
        Number(env.WORKER_REPORT_INTERVAL_MS) <= 5000,
      'WORKER_REPORT_INTERVAL_MS',
    );
  return env;
}
function validateOptions(options) {
  for (const key of ['repo', 'env', 'logs', 'node']) absolute(options[key], key);
  requireValue(/^[A-Za-z0-9][A-Za-z0-9.-]{0,100}$/.test(options.label), 'label');
}
const xml = (value) =>
  value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
export function generatePlist(options) {
  validateOptions(options);
  const { repo, env, logs, node, label } = options;
  const args = [
    node,
    join(repo, 'scripts/macos-worker-service.mjs'),
    'run',
    '--repo',
    repo,
    '--env',
    env,
    '--logs',
    logs,
    '--node',
    node,
    '--label',
    label,
  ];
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${xml(label)}</string>
<key>ProgramArguments</key><array>${args.map((arg) => `<string>${xml(arg)}</string>`).join('')}</array>
<key>WorkingDirectory</key><string>${xml(repo)}</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>30</integer>
<key>ExitTimeOut</key><integer>30</integer><key>Umask</key><integer>63</integer>
<key>StandardOutPath</key><string>${xml(join(logs, 'worker.log'))}</string>
<key>StandardErrorPath</key><string>${xml(join(logs, 'worker-error.log'))}</string>
</dict></plist>
`;
}
async function privatePath(path, directory) {
  const info = await lstat(path);
  requireValue(
    !info.isSymbolicLink() &&
      (directory ? info.isDirectory() : info.isFile()) &&
      info.uid === process.getuid() &&
      (info.mode & 0o077) === 0,
    'private file/directory permissions',
  );
}
async function load(options) {
  await privatePath(dirname(options.env), true);
  await privatePath(options.env, false);
  await privatePath(options.logs, true);
  let env;
  try {
    env = parseEnv(await readFile(options.env, 'utf8'));
  } catch {
    throw new Error('Cannot parse protected worker environment file');
  }
  validateSettings(env);
  for (const path of [options.node, env.FFMPEG_PATH, env.FFPROBE_PATH])
    await access(path, constants.X_OK);
  for (const path of [env.FONT_PATH, join(options.repo, 'apps/home-daemon/dist/index.js')])
    await access(path, constants.R_OK);
  for (const path of [
    env.SCORE_DIR,
    ...(env.OUTPUT_MODE === 'rtmp' ? [] : [env.OUTPUT_RECORDING_DIR]),
  ]) {
    requireValue((await lstat(path)).isDirectory(), 'worker state directory');
    await access(path, constants.W_OK);
  }
  return env;
}
async function run(options, config) {
  process.umask(0o077);
  // Do not inherit NODE_OPTIONS, fixture switches, or shell credentials.
  const env = { HOME: homedir(), PATH: '/usr/bin:/bin:/usr/sbin:/sbin', ...config };
  const child = spawn(options.node, [join(options.repo, 'apps/home-daemon/dist/index.js')], {
    cwd: options.repo,
    env,
    stdio: 'inherit',
  });
  const stop = (signal) => child.kill(signal);
  const term = () => stop('SIGTERM'),
    interrupt = () => stop('SIGINT');
  process.on('SIGTERM', term);
  process.on('SIGINT', interrupt);
  await new Promise((resolve, reject) => {
    child.once('error', () => reject(new Error('Cannot start worker executable')));
    child.once('exit', (code, signal) => {
      console.log(JSON.stringify({ event: 'macos_worker_exit', code, signal }));
      process.exitCode = code ?? (signal ? 1 : 0);
      resolve();
    });
  });
  process.removeListener('SIGTERM', term);
  process.removeListener('SIGINT', interrupt);
}
async function main(argv) {
  const [mode, ...args] = argv;
  requireValue(
    ['plist', 'check', 'run', 'install', 'uninstall'].includes(mode),
    'mode (plist/check/run/install/uninstall)',
  );
  const options = { label: 'live.scorebug.worker' };
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i].slice(2);
    requireValue(
      args[i].startsWith('--') &&
        ['repo', 'env', 'logs', 'node', 'label'].includes(key) &&
        args[i + 1] &&
        (key === 'label' || options[key] === undefined),
      'command options',
    );
    options[key] = args[i + 1];
  }
  const plist = generatePlist(options);
  if (mode === 'plist') {
    process.stdout.write(plist);
    return;
  }
  requireValue(process.platform === 'darwin', 'macOS platform');
  if (mode === 'uninstall') {
    const path = join(homedir(), 'Library/LaunchAgents', `${options.label}.plist`);
    requireValue((await readFile(path, 'utf8')) === plist, 'matching owned plist');
    const status = spawnSync(
      '/bin/launchctl',
      ['print', `gui/${process.getuid()}/${options.label}`],
      { stdio: 'ignore' },
    );
    requireValue(
      status.status !== 0 && !status.error,
      'service must be booted out before uninstall',
    );
    await unlink(path);
    console.log('Removed matching plist; configuration, logs and recordings retained.');
    return;
  }
  const config = await load(options);
  if (mode === 'run') {
    await run(options, config);
    return;
  }
  if (mode === 'install') {
    const path = join(homedir(), 'Library/LaunchAgents', `${options.label}.plist`);
    await writeFile(path, plist, { flag: 'wx', mode: 0o600 });
    console.log('Installed plist only; launch it explicitly with launchctl bootstrap.');
  } else console.log('Worker paths and protected configuration validated; no process started.');
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(() => {
    // Native filesystem/parser errors can contain private paths or values.
    console.error(
      'Worker service command failed. Check mode/options, required paths, private permissions, configuration and existing service state.',
    );
    process.exitCode = 1;
  });
}
