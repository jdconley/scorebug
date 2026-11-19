// pnpm --filter @scorebug/home-daemon exec tsx scripts/render-sample.ts <out-dir>
// The scorebug exactly as the match container draws it on the stream, for the website: one
// transparent 1920x1080 PNG per score in a short end-of-set sequence (bar style), plus one still per
// style. ios/AppStore/site-media.sh composites them over the gym clip.
import { renderAsync } from '@resvg/resvg-js';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { ScorebugOverlay, ScorebugStyle } from '@scorebug/protocol';
import { SCOREBUG_FONT_FAMILY, SCOREBUG_FONT_FILES } from '../src/scorebug/fonts.js';
import { buildScorebugSvg } from '../src/scorebug/layout.js';

const out = process.argv[2];
if (!out) throw new Error('usage: render-sample.ts <out-dir>');
await mkdir(out, { recursive: true });
const size = { width: 1920, height: 1080 };
const options = {
  font: {
    fontFiles: Object.values(SCOREBUG_FONT_FILES),
    loadSystemFonts: false,
    defaultFontFamily: SCOREBUG_FONT_FAMILY,
  },
  background: 'rgba(0,0,0,0)',
};
const state = (home: number, away: number, style: ScorebugStyle = 'bar'): ScorebugOverlay => ({
  style,
  label: null,
  bestOf: 3,
  teams: {
    home: { name: 'Wildcats 14 Blue', shortName: 'WILDCATS', color: '#2563eb' },
    away: { name: 'Mustangs 14 Red', shortName: 'MUSTANGS', color: '#dc2626' },
  },
  score: { home, away, set: 2, homeSets: 1, awaySets: 0 },
  completedSets: [{ set: 1, home: 25, away: 21, winner: 'home' }],
  serving: null,
});
const png = async (overlay: ScorebugOverlay) =>
  (await renderAsync(buildScorebugSvg(overlay, size), options)).asPng();

// Points as they come: [home, away] after each rally.
const rallies = [
  [21, 19],
  [22, 19],
  [22, 20],
  [23, 20],
  [23, 21],
  [24, 21],
  [24, 22],
  [25, 22],
];
for (const [index, [home, away]] of rallies.entries())
  await writeFile(join(out, `score-${index}.png`), await png(state(home!, away!)));
for (const style of ['bar', 'lowerThird', 'setCard'] as ScorebugStyle[])
  await writeFile(join(out, `style-${style}.png`), await png(state(18, 15, style)));
console.log(`wrote ${rallies.length} scores and 3 styles to ${out}`);
