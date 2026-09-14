import { existsSync } from 'node:fs';
import { command, executable, mediaTools } from './media-tools.mjs';

const mediaOnly = process.argv.includes('--media-only');
const json = process.argv.includes('--json');
const media = { ...mediaTools(), encoders: {} };
const checks = [];
function check(id, ok, detail, required = true) {
  checks.push({ id, ok, required, detail });
}
const version = (result) =>
  (result.stdout || result.stderr || result.error || '').trim().split('\n')[0];
const [ffmpeg, ffprobe, protocols, filters, encoderList] = await Promise.all([
  command(media.ffmpeg, ['-hide_banner', '-version']),
  command(media.ffprobe, ['-hide_banner', '-version']),
  command(media.ffmpeg, ['-hide_banner', '-protocols']),
  command(media.ffmpeg, ['-hide_banner', '-filters']),
  command(media.ffmpeg, ['-hide_banner', '-encoders']),
]);
check('ffmpeg', ffmpeg.ok, `${media.ffmpeg}: ${version(ffmpeg)}`);
check('ffprobe', ffprobe.ok, `${media.ffprobe}: ${version(ffprobe)}`);
check(
  'srt',
  protocols.ok && /^\s*srt\s*$/m.test(protocols.stdout),
  'FFmpeg SRT protocol (not SRTP)',
);
check('rtmps', protocols.ok && /^\s*rtmps\s*$/m.test(protocols.stdout), 'FFmpeg RTMPS output');
check('drawtext', filters.ok && /\bdrawtext\s/.test(filters.stdout), 'FFmpeg text overlay filter');
check('font', existsSync(media.font), media.font);
// These paths become filter arguments, not shell text. Escape each filter parser level.
const filterPath = (path) => path.replace(/[\\':]/g, '\\$&').replace(/[\\'\[\],;]/g, '\\$&');
const overlay = `drawtext=fontfile=${filterPath(media.font)}:text=Scorebug:fontsize=24`;
for (const name of [
  'h264_videotoolbox',
  'h264_nvenc',
  'h264_qsv',
  'h264_vaapi',
  'h264_amf',
  'libx264',
]) {
  const advertised = new RegExp(`\\s${name}\\s`).test(encoderList.stdout);
  let probe;
  if (advertised && existsSync(media.font)) {
    const backend = name === 'h264_videotoolbox' ? ['-allow_sw', '0'] : [];
    probe = await command(
      media.ffmpeg,
      [
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=640x360:rate=30',
        '-vf',
        overlay,
        '-frames:v',
        '6',
        '-c:v',
        name,
        ...backend,
        '-f',
        'null',
        '-',
      ],
      20_000,
    );
  }
  media.encoders[name] = {
    advertised,
    usable: probe?.ok === true,
    detail: !advertised
      ? 'Not advertised by this binary'
      : probe?.ok
        ? 'Encoded six frames with overlay'
        : probe?.stderr.trim().slice(-500) || probe?.error || 'Font unavailable',
  };
}
const usable = Object.entries(media.encoders)
  .filter(([, value]) => value.usable)
  .map(([name]) => name);
check(
  'encoder.usable',
  usable.length > 0,
  usable.join(', ') || 'No tested encode/filter combination works',
);
if (!mediaOnly) {
  check(
    'node',
    Number(process.versions.node.split('.')[0]) > 22 ||
      (Number(process.versions.node.split('.')[0]) === 22 &&
        Number(process.versions.node.split('.')[1]) >= 13),
    `${process.execPath}: ${process.version} (requires Node 22.13+ for built-in SQLite)`,
  );
  const pnpm = await command('pnpm', ['--version']);
  check(
    'pnpm',
    pnpm.ok && pnpm.stdout.trim() === '9.15.0',
    `${executable('pnpm')}: ${version(pnpm)} (repository pins 9.15.0)`,
  );
  const docker = await command('docker', ['info', '--format', '{{.ServerVersion}}']);
  check('docker', docker.ok, `${executable('docker')}: ${version(docker)}`);
  const compose = await command('docker', ['compose', 'version', '--short']);
  check('compose', compose.ok, version(compose));
  if (process.platform === 'darwin') {
    const xcode = await command('xcodebuild', ['-version']);
    const generator = await command('xcodegen', ['--version']);
    const runtime = await command('xcrun', ['simctl', 'list', 'runtimes', '-j']);
    check('xcode', xcode.ok, version(xcode));
    check(
      'xcodegen',
      generator.ok,
      `${executable('xcodegen')}: ${version(generator)}; install with brew install xcodegen`,
    );
    let names = [];
    try {
      names = JSON.parse(runtime.stdout)
        .runtimes.filter((r) => r.isAvailable)
        .map((r) => r.name);
    } catch {
      /* report below */
    }
    for (const family of ['iOS', 'watchOS']) {
      check(
        `simulator.${family}`,
        names.some((n) => n.startsWith(`${family} `)),
        names.filter((n) => n.startsWith(`${family} `)).join(', '),
      );
    }
    check(
      'simulator.watchOS11',
      names.some((n) => n.startsWith('watchOS 11')),
      'watchOS 11 coverage (download runtime before its compatibility gate)',
      false,
    );
  }
}
const report = { ok: checks.every((c) => c.ok || !c.required), media, checks };
if (json) console.log(JSON.stringify(report, null, 2));
else {
  for (const item of checks)
    console.log(`${item.ok ? 'PASS' : item.required ? 'FAIL' : 'WARN'} ${item.id}: ${item.detail}`);
  for (const [name, result] of Object.entries(media.encoders)) {
    if (result.advertised)
      console.log(`${result.usable ? 'USABLE' : 'UNUSABLE'} ${name}: ${result.detail}`);
  }
  console.log(
    report.ok
      ? 'Local prerequisites passed; this is not an end-to-end broadcast test.'
      : 'Resolve failed prerequisites before running local media tests.',
  );
}
process.exitCode = report.ok ? 0 : 1;
