import { describe, expect, it } from 'vitest';
import type { ScorebugOverlay } from '@scorebug/protocol';
import {
  buildScorebugSvg,
  contrastText,
  escapeXml,
  fitText,
  overlayRegions,
  packRegions,
} from '../src/scorebug/layout.js';
import { demultiply, renderScorebugRgba } from '../src/scorebug/render.js';
import { scorebugFontMetrics } from '../src/scorebug/fonts.js';

const state = (overrides: Partial<ScorebugOverlay> = {}): ScorebugOverlay => ({
  style: 'bar',
  label: null,
  bestOf: 3,
  teams: {
    home: { name: 'Spikers', shortName: 'SPK', color: '#1D4ED8' },
    away: { name: 'Diggers', shortName: 'DIG', color: '#FACC15' },
  },
  score: { home: 18, away: 15, set: 3, homeSets: 1, awaySets: 1 },
  completedSets: [
    { set: 1, home: 25, away: 21, winner: 'home' },
    { set: 2, home: 19, away: 25, winner: 'away' },
  ],
  serving: null,
  ...overrides,
});
const hd = { width: 1920, height: 1080 };
const texts = (svg: string) => [...svg.matchAll(/<text[^>]*>([^<]*)<\/text>/g)].map((m) => m[1]);
const textAttributes = (svg: string, content: string) =>
  [...svg.matchAll(/<text([^>]*)>([^<]*)<\/text>/g)]
    .filter((m) => m[2] === content)
    .map((m) => m[1]!);
const circles = (svg: string) =>
  [...svg.matchAll(/<circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)" fill="([^"]+)"/g)].map(
    (m) => ({ cx: Number(m[1]), cy: Number(m[2]), r: Number(m[3]), fill: m[4] }),
  );

describe('font metrics', () => {
  it('reads Barlow Condensed advances and cap height from the bundled TTFs', () => {
    const metrics = scorebugFontMetrics();
    expect(metrics[600].capHeight).toBeGreaterThan(0.6);
    expect(metrics[600].capHeight).toBeLessThan(0.8);
    // Condensed: a 48 px cap is roughly 0.4–0.6 em wide; bold is wider than semibold.
    const semibold = metrics[600].width('SPK', 48);
    expect(semibold).toBeGreaterThan(48 * 1.1);
    expect(semibold).toBeLessThan(48 * 1.8);
    expect(metrics[700].width('SPK', 48)).toBeGreaterThan(semibold);
    expect(metrics[600].width('SPK', 48, 2)).toBeCloseTo(semibold + 4);
  });
  it('shrinks to fit, then truncates with an ellipsis at the minimum size', () => {
    expect(fitText('SPK', 600, 48, 500)).toMatchObject({ text: 'SPK', size: 48 });
    const shrunk = fitText('WOLVERINES', 600, 48, 180);
    expect(shrunk.size).toBeLessThan(48);
    expect(shrunk.width).toBeLessThanOrEqual(180);
    const truncated = fitText('MOUNTAIN VIEW HIGH SCHOOL', 600, 48, 120, 40);
    expect(truncated.size).toBe(40);
    expect(truncated.text.endsWith('…')).toBe(true);
    expect(truncated.width).toBeLessThanOrEqual(120);
  });
});

describe('bar style', () => {
  it('draws header, names, scores, set-won dots and no serve marker without serve state', () => {
    const svg = buildScorebugSvg(state(), hd);
    expect(svg).toContain('width="1920" height="1080" viewBox="0 0 1920 1080"');
    expect(texts(svg)).toEqual(['SET 3', 'SETS 1–1', 'SPK', '18', 'DIG', '15']);
    expect(svg).toContain('<rect x="56" y="48" width="472" height="190" rx="12"');
    expect(svg).toContain('<rect x="56" y="76" width="16" height="80" fill="#1D4ED8"/>');
    expect(svg).toContain('<rect x="432" y="76" width="96" height="80" fill="#F2F4F7"/>');
    expect(textAttributes(svg, '18')[0]).toMatch(/font-size="56" font-weight="700" fill="#0B0D10"/);
    const dots = circles(svg);
    expect(dots).toHaveLength(4); // ceil(3/2) per team
    expect(dots.map((dot) => dot.fill)).toEqual(['#F2F4F7', '#4B525C', '#F2F4F7', '#4B525C']);
    expect(dots.every((dot) => dot.r === 6)).toBe(true);
    expect(dots.some((dot) => dot.fill === '#FACC15')).toBe(false);
  });
  it('shows ceil(bestOf/2) dots and a yellow serve dot after the serving name', () => {
    const svg = buildScorebugSvg(
      state({ bestOf: 5, serving: 'away', score: { ...state().score, homeSets: 2 } }),
      hd,
    );
    const dots = circles(svg);
    const serve = dots.filter((dot) => dot.fill === '#FACC15');
    expect(serve).toHaveLength(1);
    expect(serve[0]).toMatchObject({ r: 8, cy: 198 }); // away row center
    const setDots = dots.filter((dot) => dot.fill !== '#FACC15');
    expect(setDots).toHaveLength(6);
    expect(setDots.slice(0, 3).map((dot) => dot.fill)).toEqual(['#F2F4F7', '#F2F4F7', '#4B525C']);
    const nameEnd = 92 + scorebugFontMetrics()[600].width('DIG', 48);
    expect(serve[0]!.cx).toBeCloseTo(nameEnd + 22, 0);
  });
  it('escapes team text and keeps unknown colors out of attributes', () => {
    const svg = buildScorebugSvg(
      state({
        teams: {
          home: { name: 'A&B', shortName: '<b>', color: '"/><script' },
          away: { name: 'Away', shortName: 'A', color: '#000000' },
        },
      }),
      hd,
    );
    expect(svg).toContain('&lt;B&gt;');
    expect(svg).not.toContain('<script');
    expect(svg).toContain('fill="#6B7280"');
    expect(escapeXml(`<&>"'`)).toBe('&lt;&amp;&gt;&quot;&apos;');
  });
});

describe('lowerThird style', () => {
  it('centers equal team blocks around scores and the set summary with contrasting text', () => {
    const svg = buildScorebugSvg(state({ style: 'lowerThird' }), hd);
    expect(texts(svg)).toEqual([
      'SPIKERS',
      '18',
      'DIGGERS',
      '15',
      'SET 3',
      '1 – 1',
      '25–21 · 19–25',
    ]);
    // 2 * 340 + 2 * 128 + 160 = 1096 wide, centered, bottom of bar at 1080 - 56 - 42.
    expect(svg).toContain('<rect x="412" y="878" width="1096" height="104" rx="16"');
    expect(textAttributes(svg, 'SPIKERS')[0]).toMatch(/fill="#FFFFFF" text-anchor="end"/);
    expect(textAttributes(svg, 'DIGGERS')[0]).toMatch(/fill="#0B0D10"/); // on yellow
    expect(textAttributes(svg, '18')[0]).toMatch(/font-size="64" font-weight="700"/);
  });
  it('grows name blocks past the minimum for long names and omits the pill before set 1 ends', () => {
    const svg = buildScorebugSvg(
      state({
        style: 'lowerThird',
        completedSets: [],
        teams: {
          home: { name: 'Mountain View Thunderbolts', shortName: 'MVT', color: '#111111' },
          away: { name: 'Diggers', shortName: 'DIG', color: '#EEEEEE' },
        },
      }),
      hd,
    );
    const card = /<rect x="([\d.]+)" y="878" width="([\d.]+)" height="104" rx="16"/.exec(svg)!;
    expect(Number(card[2])).toBeGreaterThan(1096);
    expect(Number(card[2])).toBeLessThanOrEqual(1400);
    expect(Number(card[1]) * 2 + Number(card[2])).toBeCloseTo(1920, 1);
    expect(texts(svg)).not.toContain('');
    expect(svg).not.toContain('·');
  });
});

describe('setCard style', () => {
  it('lays out S1..S{bestOf}, NOW, bold winners, muted losers and dashes for unplayed sets', () => {
    const svg = buildScorebugSvg(state({ style: 'setCard', label: 'Pool B' }), hd);
    expect(svg).toContain('<rect x="1264" y="48" width="600" height="198" rx="16"');
    expect(svg).toContain('fill-opacity="0.92"');
    expect(texts(svg)).toEqual(
      expect.arrayContaining(['POOL B', 'S1', 'S2', 'S3', 'NOW', 'SPK', 'DIG', '18', '15']),
    );
    expect(texts(svg)).not.toContain('S4');
    expect(textAttributes(svg, '25')).toHaveLength(2);
    for (const attributes of textAttributes(svg, '25'))
      expect(attributes).toMatch(/font-weight="700" fill="#F2F4F7"/);
    expect(textAttributes(svg, '21')[0]).toMatch(/font-weight="600" fill="#9AA3AE"/);
    expect(textAttributes(svg, '–')).toHaveLength(2); // set 3, both rows
  });
  it('leaves the label blank when the match has none and widens to five sets', () => {
    const svg = buildScorebugSvg(state({ style: 'setCard', bestOf: 5 }), hd);
    expect(texts(svg).slice(0, 6)).toEqual(['S1', 'S2', 'S3', 'S4', 'S5', 'NOW']);
    expect(textAttributes(svg, '–')).toHaveLength(6);
  });
});

describe('output sizes and bands', () => {
  it('keeps the 1080-line design at every profile aspect', () => {
    expect(buildScorebugSvg(state(), { width: 1280, height: 720 })).toContain(
      'width="1280" height="720" viewBox="0 0 1920 1080"',
    );
    expect(buildScorebugSvg(state(), { width: 426, height: 240 })).toContain(
      'viewBox="0 0 1917 1080"',
    );
  });
  it('packs an even-aligned box per style, scaled with the output', () => {
    expect(overlayRegions(hd)).toEqual({
      canvas: { width: 1448, height: 424 },
      regions: [
        { style: 'bar', frame: { x: 32, y: 24, width: 520, height: 244 }, canvas: { x: 0, y: 0 } },
        {
          style: 'setCard',
          frame: { x: 1240, y: 24, width: 648, height: 252 },
          canvas: { x: 520, y: 0 },
        },
        {
          style: 'lowerThird',
          frame: { x: 236, y: 854, width: 1448, height: 172 },
          canvas: { x: 0, y: 252 },
        },
      ],
    });
    for (const size of [
      { width: 426, height: 240 },
      { width: 1280, height: 720 },
      { width: 3840, height: 2160 },
    ]) {
      const { canvas, regions } = overlayRegions(size);
      for (const { frame, canvas: at } of regions) {
        for (const value of [frame.x, frame.y, frame.width, frame.height, at.x, at.y])
          expect(value % 2).toBe(0);
        expect(frame.x + frame.width).toBeLessThanOrEqual(size.width);
        expect(frame.y + frame.height).toBeLessThanOrEqual(size.height);
        expect(at.x + frame.width).toBeLessThanOrEqual(canvas.width);
        expect(at.y + frame.height).toBeLessThanOrEqual(canvas.height);
      }
      // About a quarter of the frame is ever blended.
      const area = regions.reduce((sum, { frame }) => sum + frame.width * frame.height, 0);
      expect(area / (size.width * size.height)).toBeLessThan(0.28);
    }
  });
  it('copies each frame box into its packed canvas position', () => {
    const size = { width: 4, height: 4 };
    const image = Buffer.alloc(64);
    for (let pixel = 0; pixel < 16; pixel++) image[pixel * 4] = pixel;
    const packed = packRegions(image, size, {
      canvas: { width: 2, height: 3 },
      regions: [
        { style: 'bar', frame: { x: 2, y: 1, width: 2, height: 2 }, canvas: { x: 0, y: 0 } },
        { style: 'lowerThird', frame: { x: 0, y: 3, width: 1, height: 1 }, canvas: { x: 1, y: 2 } },
      ],
    });
    expect([...packed].filter((_, index) => index % 4 === 0)).toEqual([6, 7, 10, 11, 0, 12]);
  });
  it.each(['bar', 'lowerThird', 'setCard'] as const)(
    'rasterizes %s with straight alpha and paints only inside its box',
    async (style) => {
      for (const size of [hd, { width: 1280, height: 720 }]) {
        const pixels = await renderScorebugRgba(
          state({ style, bestOf: 5, serving: 'home', label: 'Pool B' }),
          size,
        );
        expect(pixels.length).toBe(size.width * size.height * 4);
        const box = overlayRegions(size).regions.find((region) => region.style === style)!.frame;
        const stride = size.width * 4;
        let painted = 0;
        for (let row = 0; row < size.height; row++)
          for (let column = 0; column < size.width; column++) {
            if (!pixels[row * stride + column * 4 + 3]) continue;
            painted++;
            const inside =
              column >= box.x &&
              column < box.x + box.width &&
              row >= box.y &&
              row < box.y + box.height;
            if (!inside) expect({ style, size, row, column }).toBeUndefined();
          }
        expect(painted).toBeGreaterThan(box.width * box.height * 0.3);
      }
    },
  );
  it('converts resvg premultiplied pixels to straight alpha', () => {
    const pixels = Buffer.from([128, 0, 64, 128, 0, 0, 0, 0, 10, 20, 30, 255, 200, 200, 200, 100]);
    expect([...demultiply(pixels)]).toEqual([
      255, 0, 128, 128, 0, 0, 0, 0, 10, 20, 30, 255, 255, 255, 255, 100,
    ]);
  });
  it('renders the opaque light score box exactly', async () => {
    const pixels = await renderScorebugRgba(state(), hd);
    const at = (480 + 90 * 1920) * 4;
    expect([...pixels.subarray(at, at + 4)]).toEqual([242, 244, 247, 255]);
  });
});

describe('contrastText', () => {
  it('picks white on dark and near-black on light team colors', () => {
    expect(contrastText('#1D4ED8')).toBe('#FFFFFF');
    expect(contrastText('#111111')).toBe('#FFFFFF');
    expect(contrastText('#FACC15')).toBe('#0B0D10');
    expect(contrastText('#F2F4F7')).toBe('#0B0D10');
    expect(contrastText('not-a-color')).toBe('#FFFFFF');
  });
});
