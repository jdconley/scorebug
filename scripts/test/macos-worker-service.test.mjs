import test from 'node:test';
import assert from 'node:assert/strict';
import { validateSettings, generatePlist } from '../macos-worker-service.mjs';

const settings = {
  CONTROL_PLANE_URL: 'http://127.0.0.1:9999',
  HOME_TOKEN: 'private-token-for-test',
  WORKER_ID: 'mac',
  OUTPUT_ID: 'local',
  OUTPUT_MODE: 'rtmp+record',
  OUTPUT_URL: 'rtmp://127.0.0.1/live/private-key',
  OUTPUT_RECORDING_DIR: '/tmp/recordings',
  ENCODER: 'software',
  VIDEO_PROFILE: '1080p30',
  FFMPEG_PATH: '/opt/bin/ffmpeg',
  FFPROBE_PATH: '/opt/bin/ffprobe',
  FONT_PATH: '/Library/Fonts/font.ttf',
  SCORE_DIR: '/tmp/score',
};
test('worker config supports each output mode and rejects malformed required paths/settings', () => {
  for (const OUTPUT_MODE of ['rtmp', 'record', 'rtmp+record'])
    validateSettings({ ...settings, OUTPUT_MODE });
  for (const key of [
    'FFMPEG_PATH',
    'FFPROBE_PATH',
    'FONT_PATH',
    'SCORE_DIR',
    'OUTPUT_RECORDING_DIR',
  ]) {
    assert.throws(() => validateSettings({ ...settings, [key]: '../relative' }));
    assert.throws(() => validateSettings({ ...settings, [key]: '/tmp/line\nbreak' }));
  }
  for (const bad of [
    { HOME_TOKEN: '' },
    { OUTPUT_URL: '' },
    { OUTPUT_MODE: 'other' },
    { NODE_OPTIONS: '--import=bad' },
    { ENCODER: 'automatic' },
    { CONTROL_PLANE_URL: 'file:///tmp/api' },
  ]) {
    assert.throws(() => validateSettings({ ...settings, ...bad }));
  }
});
test('plist passes paths as individual XML arguments and never embeds config secrets', () => {
  const plist = generatePlist({
    repo: '/tmp/a & b',
    env: '/tmp/private/worker.env',
    logs: '/tmp/logs',
    node: '/opt/bin/node',
    label: 'live.scorebug.worker',
  });
  assert.match(plist, /a &amp; b/);
  assert.match(plist, /<string>run<\/string>/);
  assert.match(plist, /<key>KeepAlive<\/key><true\/>/);
  assert.ok(!plist.includes(settings.HOME_TOKEN));
  assert.ok(!plist.includes(settings.OUTPUT_URL));
  assert.ok(!plist.includes('EnvironmentVariables'));
  assert.throws(() =>
    generatePlist({
      repo: 'relative',
      env: '/tmp/env',
      logs: '/tmp/logs',
      node: '/opt/node',
      label: 'x',
    }),
  );
});
