/**
 * Writes PNGs of every scorebug style for a sample mid-match state, so the
 * look can be reviewed without a stream:
 *
 *   pnpm --filter @scorebug/home-daemon render-scorebug [outDir] [--frame=path.png]
 *
 * Each style is written transparent (`<style>-1080p.png`) and composited on a
 * neutral backdrop (`<style>-preview-1080p.png`); 720p transparents too.
 */
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Resvg } from '@resvg/resvg-js';
import { SCOREBUG_STYLES, type ScorebugOverlay } from '@scorebug/protocol';
import { renderScorebugPng } from '../src/scorebug/render.js';
import { buildScorebugSvg } from '../src/scorebug/layout.js';
import { SCOREBUG_FONT_FAMILY, SCOREBUG_FONT_FILES } from '../src/scorebug/fonts.js';

// What the live feed draws today: the match model has no title/division or serve
// state, so the setCard label and the bar's serve dot stay blank.
export const sampleScorebug: Omit<ScorebugOverlay, 'style'> = {
  label: null,
  bestOf: 3,
  teams: {
    home: { name: 'Spikers', shortName: 'SPK', color: '#1D4ED8' },
    away: { name: 'Diggers', shortName: 'DIG', color: '#F97316' },
  },
  score: { home: 18, away: 15, set: 3, homeSets: 1, awaySets: 1 },
  completedSets: [
    { set: 1, home: 25, away: 21, winner: 'home' },
    { set: 2, home: 19, away: 25, winner: 'away' },
  ],
  serving: null,
};

const args = process.argv.slice(2);
const outDir = resolve(args.find((arg) => !arg.startsWith('--')) ?? 'scorebug-samples');
const frame = args.find((arg) => arg.startsWith('--frame='))?.slice('--frame='.length);
await mkdir(outDir, { recursive: true });
const backdrop = frame
  ? `data:image/png;base64,${(await readFile(frame)).toString('base64')}`
  : undefined;

for (const style of SCOREBUG_STYLES) {
  const state = { ...sampleScorebug, style };
  for (const size of [
    { width: 1920, height: 1080, label: '1080p' },
    { width: 1280, height: 720, label: '720p' },
  ]) {
    await writeFile(
      resolve(outDir, `${style}-${size.label}.png`),
      await renderScorebugPng(state, size),
    );
  }
  // Preview: the same SVG over a court-ish gradient (or a supplied frame).
  const underlay = backdrop
    ? `<image href="${backdrop}" width="1920" height="1080" preserveAspectRatio="xMidYMid slice"/>`
    : '<linearGradient id="court" x1="0" y1="0" x2="0" y2="1">' +
      '<stop offset="0" stop-color="#5B6B7C"/><stop offset="0.45" stop-color="#8C6A4A"/>' +
      '<stop offset="1" stop-color="#B98A5E"/></linearGradient>' +
      '<rect width="1920" height="1080" fill="url(#court)"/>';
  const preview = new Resvg(buildScorebugSvg(state, { width: 1920, height: 1080 }, underlay), {
    font: {
      fontFiles: Object.values(SCOREBUG_FONT_FILES),
      loadSystemFonts: false,
      defaultFontFamily: SCOREBUG_FONT_FAMILY,
    },
  }).render();
  await writeFile(resolve(outDir, `${style}-preview-1080p.png`), preview.asPng());
}
console.log(`wrote ${SCOREBUG_STYLES.length * 3} PNGs to ${outDir}`);
