import assert from 'node:assert/strict';
import { nativeMediaGeometry } from './native-live-profile.mjs';

/** Independent expected score raster, using the worker's declared drawing contract. */
export function nativeScoreTemplate({ profile, font, score }) {
  assert(['2160p30', '1080p30', '540p30', '360p30', '240p30'].includes(profile));
  assert(typeof font === 'string' && font.length > 0 && !/[\\':;,\[\]\n]/.test(font));
  assert(['0-0', '1-0', '0-1', '1-1', '2-1', '1-2'].includes(score));
  const { width, height, overlay } = nativeMediaGeometry(profile, true);
  const ratio = height / 1080;
  return {
    input: `color=black:s=${width}x${height}:r=30`,
    filter: `drawtext=text='HOME ${score} AWAY · Set 1 · Sets 0-0':expansion=none:fontcolor=white:fontsize=${Math.max(14, Math.round(42 * ratio))}:box=1:boxcolor=black@0.55:boxborderw=${Math.round(18 * ratio)}:x=${Math.round(40 * ratio)}:y=h-${Math.round(100 * ratio)}:fontfile=${font},format=gray,crop=${overlay.width}:${overlay.height}:0:${overlay.y}`,
    byteLength: overlay.width * overlay.height,
  };
}
