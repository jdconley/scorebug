import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import assert from 'node:assert/strict';

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'scorebug-doctor-'));
  const binary = join(dir, 'media');
  writeFileSync(
    binary,
    `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args.includes('-protocols')) console.log(process.env.QA_NO_SRT ? '  srtp\\n  rtmps' : '  srt\\n  rtmps');
else if (args.includes('-filters')) console.log(' T. drawtext V->V');
else if (args.includes('-encoders')) console.log(' V....D libx264\\n V....D h264_videotoolbox');
else if (args.includes('h264_videotoolbox')) { console.error('Hardware encoder unavailable'); process.exit(1); }
else if (args.includes('-version')) console.log('ffmpeg version test');
`,
  );
  chmodSync(binary, 0o755);
  const font = join(dir, 'font.ttf');
  writeFileSync(font, 'fixture');
  return {
    dir,
    env: { ...process.env, FFMPEG_PATH: binary, FFPROBE_PATH: binary, FONT_PATH: font },
  };
}

function run(env) {
  return spawnSync(process.execPath, ['scripts/doctor.mjs', '--media-only', '--json'], {
    env,
    encoding: 'utf8',
    timeout: 10_000,
  });
}

test('doctor distinguishes advertised hardware from a working encoder', () => {
  const f = fixture();
  try {
    const res = run(f.env);
    assert.equal(res.status, 0, res.stderr);
    const report = JSON.parse(res.stdout);
    assert.equal(report.media.encoders.h264_videotoolbox.advertised, true);
    assert.equal(report.media.encoders.h264_videotoolbox.usable, false);
    assert.equal(report.media.encoders.libx264.usable, true);
    assert.equal(report.media.ffmpeg, f.env.FFMPEG_PATH);
  } finally {
    rmSync(f.dir, { recursive: true, force: true });
  }
});

test('srtp does not satisfy the SRT prerequisite', () => {
  const f = fixture();
  try {
    const res = run({ ...f.env, QA_NO_SRT: '1' });
    assert.equal(res.status, 1);
    assert.equal(JSON.parse(res.stdout).checks.find((c) => c.id === 'srt').ok, false);
  } finally {
    rmSync(f.dir, { recursive: true, force: true });
  }
});

test('an explicit missing binary is an error rather than a silent fallback', () => {
  const f = fixture();
  try {
    const missing = join(f.dir, 'missing');
    const res = run({ ...f.env, FFMPEG_PATH: missing });
    assert.equal(res.status, 1);
    assert.equal(JSON.parse(res.stdout).media.ffmpeg, missing);
  } finally {
    rmSync(f.dir, { recursive: true, force: true });
  }
});
