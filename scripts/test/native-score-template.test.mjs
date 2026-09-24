import test from 'node:test';
import assert from 'node:assert/strict';
import { nativeScoreTemplate } from '../native-score-template.mjs';
const font = '/local/Arial.ttf';
for (const [profile, size, fontSize, border, x, bottom, crop, bytes] of [
  ['1080p30', '1920x1080', 42, 18, 40, 100, '750:120:0:930', 90000],
  ['540p30', '960x540', 21, 9, 20, 50, '375:60:0:465', 22500],
  ['360p30', '640x360', 14, 6, 13, 33, '250:40:0:310', 10000],
  ['240p30', '426x240', 14, 4, 9, 22, '166:26:0:206', 4316],
])
  test(`${profile} score raster uses actual worker dimensions and minimum font size`, () => {
    for (const score of ['0-0', '1-0']) {
      const result = nativeScoreTemplate({ profile, font, score });
      assert.equal(result.input, `color=black:s=${size}:r=30`);
      assert.equal(
        result.filter,
        `drawtext=text='HOME ${score} AWAY · Set 1 · Sets 0-0':expansion=none:fontcolor=white:fontsize=${fontSize}:box=1:boxcolor=black@0.55:boxborderw=${border}:x=${x}:y=h-${bottom}:fontfile=${font},format=gray,crop=${crop}`,
      );
      assert.equal(result.byteLength, bytes);
    }
  });
test('score renderer rejects unsupported profiles, scores and filter path syntax', () => {
  const input = { profile: '240p30', font, score: '0-0' };
  for (const patch of [
    { profile: '720p30' },
    { profile: '' },
    { score: '2-0' },
    { score: null },
    { font: '' },
    { font: '/path:inject' },
    { font: '/path\nnewline' },
  ])
    assert.throws(() => nativeScoreTemplate({ ...input, ...patch }));
});
