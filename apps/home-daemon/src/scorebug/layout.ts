import type { ScorebugOverlay, ScorebugStyle, Side, Team } from '@scorebug/protocol';
import { SCOREBUG_FONT_FAMILY, scorebugFontMetrics, type FontWeight } from './fonts.js';

/**
 * Builds the scorebug as SVG in 1080-line design units. The viewBox keeps the
 * output's aspect, so right/center anchored styles stay put at every profile;
 * the rasterizer scales to the output height (720p is exactly 2/3 of 1080p).
 */
export type OverlaySize = { width: number; height: number };

const DESIGN_HEIGHT = 1080;
const INK = '#0B0D10';
const PANEL = '#16191E';
const LIGHT = '#F2F4F7';
const MUTED = '#9AA3AE';
const HEADER_TEXT = '#C9CED6';
const DIM = '#4B525C';
const SERVE = '#FACC15';
const EN_DASH = '–';

export function escapeXml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (character) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[character]!,
  );
}

const caps = (value: string) => value.toLocaleUpperCase('en-US');

/** White or near-black, whichever contrasts more with `#RRGGBB` (WCAG luminance). */
export function contrastText(color: string): string {
  const match = /^#([0-9a-f]{6})$/i.exec(color);
  if (!match) return '#FFFFFF';
  const channel = (offset: number) => {
    const value = parseInt(match[1]!.slice(offset, offset + 2), 16) / 255;
    return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  };
  const luminance = 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
  // Contrast against white (L=1) vs. INK (L≈0.004): choose the larger ratio.
  return 1.05 / (luminance + 0.05) >= (luminance + 0.05) / 0.054 ? '#FFFFFF' : INK;
}

/** Team colors arrive validated, but never let a value break out of an attribute. */
const safeColor = (color: string) => (/^#[0-9a-f]{6}$/i.test(color) ? color : '#6B7280');

type TextOptions = {
  size: number;
  weight: FontWeight;
  fill: string;
  anchor?: 'start' | 'middle' | 'end';
  spacing?: number;
};

/** Text vertically centered on cap height, so caps and digits sit in the middle of a box. */
function text(x: number, centerY: number, content: string, options: TextOptions): string {
  const metrics = scorebugFontMetrics()[options.weight];
  const baseline = centerY + (metrics.capHeight * options.size) / 2;
  return (
    `<text x="${round(x)}" y="${round(baseline)}" font-family="${SCOREBUG_FONT_FAMILY}" ` +
    `font-size="${round(options.size)}" font-weight="${options.weight}" fill="${options.fill}"` +
    (options.anchor && options.anchor !== 'start' ? ` text-anchor="${options.anchor}"` : '') +
    (options.spacing ? ` letter-spacing="${options.spacing}"` : '') +
    `>${escapeXml(content)}</text>`
  );
}

const round = (value: number) => Math.round(value * 100) / 100;

/** Largest size up to `size` (not below `min`) that fits; truncates with an ellipsis at `min`. */
export function fitText(
  value: string,
  weight: FontWeight,
  size: number,
  maxWidth: number,
  min = Math.round(size * 0.6),
  spacing = 0,
): { text: string; size: number; width: number } {
  const metrics = scorebugFontMetrics()[weight];
  const width = metrics.width(value, size, spacing);
  if (width <= maxWidth) return { text: value, size, width };
  const scaled = Math.max(min, Math.floor((size * maxWidth) / width));
  let fitted = value;
  while (fitted.length > 1 && metrics.width(fitted, scaled, spacing) > maxWidth)
    fitted = `${[...fitted].slice(0, -2).join('')}…`;
  return { text: fitted, size: scaled, width: metrics.width(fitted, scaled, spacing) };
}

const rect = (x: number, y: number, width: number, height: number, attributes: string) =>
  `<rect x="${round(x)}" y="${round(y)}" width="${round(width)}" height="${round(height)}" ${attributes}/>`;
const circle = (cx: number, cy: number, r: number, fill: string) =>
  `<circle cx="${round(cx)}" cy="${round(cy)}" r="${round(r)}" fill="${fill}"/>`;

/** Shadow reach past a card (design px); the filter region clips it exactly here. */
const SHADOW_SIDE = 24;
const SHADOW_BELOW = 30;

/** A rounded card: soft shadow behind, content clipped to the same rounded rectangle. */
function card(
  id: string,
  x: number,
  y: number,
  width: number,
  height: number,
  radius: number,
  body: string,
  fill = PANEL,
  opacity = 1,
): string {
  const shape = (attributes: string) => rect(x, y, width, height, `rx="${radius}" ${attributes}`);
  // Beyond 2.4 sigma the shadow is under 1/255 alpha; clipping there keeps every
  // painted pixel inside the style's overlay box (see overlayRegions).
  const shadow =
    `<filter id="${id}-shadow" filterUnits="userSpaceOnUse" x="${round(x - SHADOW_SIDE)}" ` +
    `y="${round(y - SHADOW_SIDE)}" width="${round(width + 2 * SHADOW_SIDE)}" ` +
    `height="${round(height + SHADOW_SIDE + SHADOW_BELOW)}">` +
    '<feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000000" flood-opacity="0.45"/>' +
    '</filter>';
  return (
    `<clipPath id="${id}">${shape('')}</clipPath>${shadow}` +
    shape(`fill="${fill}" fill-opacity="${opacity}" filter="url(#${id}-shadow)"`) +
    `<g clip-path="url(#${id})">${body}</g>`
  );
}

const setsWon = (state: ScorebugOverlay, side: Side) =>
  side === 'home' ? state.score.homeSets : state.score.awaySets;
const points = (state: ScorebugOverlay, side: Side) =>
  side === 'home' ? state.score.home : state.score.away;
const team = (state: ScorebugOverlay, side: Side): Team => state.teams[side];
const SIDES: Side[] = ['home', 'away'];

export const BAR = { x: 56, y: 48, width: 472, header: 28, row: 80, separator: 2, box: 96 };

function bar(state: ScorebugOverlay): string {
  const { x, y, width, header, row, separator, box } = BAR;
  const height = header + row * 2 + separator;
  const parts = [
    rect(x, y, width, header, `fill="${INK}"`),
    text(x + 16, y + header / 2, `SET ${state.score.set}`, {
      size: 17,
      weight: 600,
      fill: HEADER_TEXT,
      spacing: 1.5,
    }),
    text(
      x + width - 16,
      y + header / 2,
      `SETS ${state.score.homeSets}${EN_DASH}${state.score.awaySets}`,
      { size: 17, weight: 600, fill: HEADER_TEXT, spacing: 1.5, anchor: 'end' },
    ),
    rect(x, y + header + row, width, separator, `fill="${INK}"`),
  ];
  const dots = Math.ceil(state.bestOf / 2);
  const dotPitch = 22;
  const lastDot = x + width - box - 24;
  const firstDot = lastDot - (dots - 1) * dotPitch;
  const nameX = x + 16 + 20;
  const serveRoom = state.serving ? 30 : 0;
  SIDES.forEach((side, index) => {
    const top = y + header + index * (row + separator);
    const center = top + row / 2;
    const name = fitText(
      caps(team(state, side).shortName),
      600,
      48,
      firstDot - 6 - 16 - serveRoom - nameX,
    );
    parts.push(
      rect(x, top, 16, row, `fill="${safeColor(team(state, side).color)}"`),
      text(nameX, center, name.text, { size: name.size, weight: 600, fill: LIGHT }),
    );
    if (state.serving === side) parts.push(circle(nameX + name.width + 14 + 8, center, 8, SERVE));
    for (let dot = 0; dot < dots; dot++)
      parts.push(
        circle(firstDot + dot * dotPitch, center, 6, dot < setsWon(state, side) ? LIGHT : DIM),
      );
    parts.push(
      rect(x + width - box, top, box, row, `fill="${LIGHT}"`),
      text(x + width - box / 2, center, String(points(state, side)), {
        size: 56,
        weight: 700,
        fill: INK,
        anchor: 'middle',
      }),
    );
  });
  return card('bar', x, y, width, height, 12, parts.join(''));
}

export const LOWER_THIRD = {
  bottom: 56,
  height: 104,
  minName: 340,
  score: 128,
  center: 160,
  pad: 28,
  pill: 34,
  gap: 8,
  /** Long names shrink/ellipsize rather than widen the bar past this. */
  maxWidth: 1400,
};

function lowerThird(state: ScorebugOverlay, designWidth: number): string {
  const { bottom, height, minName, score, center, pad, pill, gap } = LOWER_THIRD;
  const available = Math.min(designWidth - 2 * 56, LOWER_THIRD.maxWidth);
  const maxName = Math.max(120, (available - 2 * score - center) / 2);
  const names = SIDES.map((side) => caps(team(state, side).name));
  const metrics = scorebugFontMetrics()[600];
  const natural = Math.max(...names.map((name) => metrics.width(name, 44, 1)));
  const block = Math.min(maxName, Math.max(minName, natural + 2 * pad));
  const total = 2 * block + 2 * score + center;
  const x = (designWidth - total) / 2;
  // The pill slot is always reserved so the bar never moves when a set completes.
  const y = DESIGN_HEIGHT - bottom - pill - gap - height;
  const middle = y + height / 2;
  const parts: string[] = [];
  SIDES.forEach((side, index) => {
    const color = safeColor(team(state, side).color);
    const blockX = index === 0 ? x : x + block + 2 * score + center;
    const scoreX = index === 0 ? x + block : x + block + score + center;
    const name = fitText(names[index]!, 600, 44, block - 2 * pad, 26, 1);
    parts.push(
      rect(blockX, y, block, height, `fill="${color}"`),
      text(index === 0 ? blockX + block - pad : blockX + pad, middle, name.text, {
        size: name.size,
        weight: 600,
        fill: contrastText(color),
        anchor: index === 0 ? 'end' : 'start',
        spacing: 1,
      }),
      rect(scoreX, y, score, height, `fill="${LIGHT}"`),
      text(scoreX + score / 2, middle, String(points(state, side)), {
        size: 64,
        weight: 700,
        fill: INK,
        anchor: 'middle',
      }),
    );
  });
  const centerX = x + block + score;
  parts.push(
    rect(centerX, y, center, height, `fill="${INK}"`),
    text(centerX + center / 2, y + 32, `SET ${state.score.set}`, {
      size: 20,
      weight: 600,
      fill: MUTED,
      anchor: 'middle',
      spacing: 2,
    }),
    text(
      centerX + center / 2,
      y + 68,
      `${state.score.homeSets} ${EN_DASH} ${state.score.awaySets}`,
      { size: 40, weight: 700, fill: LIGHT, anchor: 'middle' },
    ),
  );
  let svg = card('lowerThird', x, y, total, height, 16, parts.join(''));
  if (state.completedSets.length) {
    const label = state.completedSets.map((set) => `${set.home}${EN_DASH}${set.away}`).join(' · ');
    const width = metrics.width(label, 20, 1) + 36;
    const pillY = y + height + gap;
    svg +=
      rect(designWidth / 2 - width / 2, pillY, width, pill, `rx="${pill / 2}" fill="${INK}"`) +
      text(designWidth / 2, pillY + pill / 2, label, {
        size: 20,
        weight: 600,
        fill: HEADER_TEXT,
        anchor: 'middle',
        spacing: 1,
      });
  }
  return svg;
}

export const SET_CARD = {
  width: 600,
  right: 56,
  top: 48,
  pad: 24,
  header: 44,
  row: 64,
  now: 80,
  set: 48,
};

const setCardHeight = () => 12 + SET_CARD.header + 2 * SET_CARD.row + 14;

function setCard(state: ScorebugOverlay, designWidth: number): string {
  const { width, right, top, pad, header, row, now, set } = SET_CARD;
  const x = designWidth - right - width;
  const height = setCardHeight();
  const nowCenter = x + width - pad - now / 2;
  const lastSet = x + width - pad - now - 12 - set / 2;
  const setCenter = (number: number) => lastSet - (state.bestOf - number) * set;
  const firstSetLeft = setCenter(1) - set / 2;
  const headerY = y0(top) + header / 2;
  const heading = { size: 26, weight: 600 as const, fill: MUTED, anchor: 'middle' as const };
  const parts: string[] = [];
  if (state.label) {
    const label = fitText(caps(state.label), 600, 26, firstSetLeft - 12 - (x + pad), 18, 1);
    parts.push(
      text(x + pad, headerY, label.text, { ...heading, size: label.size, anchor: 'start' }),
    );
  }
  for (let number = 1; number <= state.bestOf; number++)
    parts.push(text(setCenter(number), headerY, `S${number}`, heading));
  parts.push(text(nowCenter, headerY, 'NOW', heading));
  const nameX = x + pad + 12 + 16;
  SIDES.forEach((side, index) => {
    const rowTop = y0(top) + header + index * row;
    const center = rowTop + row / 2;
    const name = fitText(caps(team(state, side).shortName), 600, 40, firstSetLeft - 12 - nameX);
    parts.push(
      rect(x + pad, center - 24, 12, 48, `rx="2" fill="${safeColor(team(state, side).color)}"`),
      text(nameX, center, name.text, { size: name.size, weight: 600, fill: LIGHT }),
    );
    for (let number = 1; number <= state.bestOf; number++) {
      const result = state.completedSets.find((completed) => completed.set === number);
      const won = result?.winner === side;
      parts.push(
        result
          ? text(setCenter(number), center, String(result[side]), {
              size: 30,
              weight: won ? 700 : 600,
              fill: won ? LIGHT : MUTED,
              anchor: 'middle',
            })
          : text(setCenter(number), center, EN_DASH, {
              size: 30,
              weight: 600,
              fill: DIM,
              anchor: 'middle',
            }),
      );
    }
    parts.push(
      rect(nowCenter - 36, center - 24, 72, 48, `rx="10" fill="${LIGHT}"`),
      text(nowCenter, center, String(points(state, side)), {
        size: 34,
        weight: 700,
        fill: INK,
        anchor: 'middle',
      }),
    );
  });
  return card('setCard', x, top, width, height, 16, parts.join(''), INK, 0.92);
}
const y0 = (top: number) => top + 12;

/**
 * The output-frame rectangle each style can paint (design units, soft shadow
 * included). The live feed sends only these three boxes, packed into one small
 * canvas, and FFmpeg blends each at its place: `overlay` blends every pixel of
 * its input, transparent or not, so blended area is the overlay's main cost.
 */
function designRegion(style: ScorebugStyle, designWidth: number) {
  if (style === 'bar')
    return {
      x0: BAR.x - SHADOW_SIDE,
      y0: BAR.y - SHADOW_SIDE,
      x1: BAR.x + BAR.width + SHADOW_SIDE,
      y1: BAR.y + BAR.header + 2 * BAR.row + BAR.separator + SHADOW_BELOW,
    };
  if (style === 'setCard')
    return {
      x0: designWidth - SET_CARD.right - SET_CARD.width - SHADOW_SIDE,
      y0: SET_CARD.top - SHADOW_SIDE,
      x1: designWidth - SET_CARD.right + SHADOW_SIDE,
      y1: SET_CARD.top + setCardHeight() + SHADOW_BELOW,
    };
  const { bottom, height, pill, gap, maxWidth } = LOWER_THIRD;
  const half = Math.min(designWidth - 2 * 56, maxWidth) / 2 + SHADOW_SIDE;
  const top = DESIGN_HEIGHT - bottom - pill - gap - height;
  return {
    x0: designWidth / 2 - half,
    y0: top - SHADOW_SIDE,
    x1: designWidth / 2 + half,
    y1: Math.max(top + height + SHADOW_BELOW, DESIGN_HEIGHT - bottom) + 2,
  };
}

export type PixelRect = { x: number; y: number; width: number; height: number };
export type OverlayRegion = {
  style: ScorebugStyle;
  /** Where the box sits in the output frame. */
  frame: PixelRect;
  /** Where the same box sits in the packed feed canvas. */
  canvas: { x: number; y: number };
};
export type OverlayRegions = { canvas: OverlaySize; regions: OverlayRegion[] };

/** Even-aligned pixel boxes (bar and setCard side by side, lowerThird below). */
export function overlayRegions(size: OverlaySize): OverlayRegions {
  const scale = size.height / DESIGN_HEIGHT;
  const designWidth = size.width / scale;
  const down = (value: number, limit: number) =>
    Math.max(0, Math.min(limit, 2 * Math.floor((value * scale) / 2)));
  const up = (value: number, limit: number) =>
    Math.max(0, Math.min(limit, 2 * Math.ceil((value * scale) / 2)));
  const frame = (style: ScorebugStyle): PixelRect => {
    const box = designRegion(style, designWidth);
    const x = down(box.x0, size.width);
    const y = down(box.y0, size.height);
    return { x, y, width: up(box.x1, size.width) - x, height: up(box.y1, size.height) - y };
  };
  const bar = frame('bar');
  const setCard = frame('setCard');
  const lowerThird = frame('lowerThird');
  const firstRow = Math.max(bar.height, setCard.height);
  return {
    canvas: {
      width: Math.max(bar.width + setCard.width, lowerThird.width),
      height: firstRow + lowerThird.height,
    },
    regions: [
      { style: 'bar', frame: bar, canvas: { x: 0, y: 0 } },
      { style: 'setCard', frame: setCard, canvas: { x: bar.width, y: 0 } },
      { style: 'lowerThird', frame: lowerThird, canvas: { x: 0, y: firstRow } },
    ],
  };
}

/** Copy each region of a full-frame RGBA image into a fresh packed canvas. */
export function packRegions(rgba: Buffer, size: OverlaySize, layout: OverlayRegions): Buffer {
  const canvas = Buffer.alloc(layout.canvas.width * layout.canvas.height * 4);
  for (const { frame, canvas: at } of layout.regions)
    for (let row = 0; row < frame.height; row++) {
      const source = ((frame.y + row) * size.width + frame.x) * 4;
      rgba.copy(
        canvas,
        ((at.y + row) * layout.canvas.width + at.x) * 4,
        source,
        source + frame.width * 4,
      );
    }
  return canvas;
}

/**
 * The full transparent-canvas SVG for one frame at the output size. `underlay`
 * (design-unit SVG markup) is only for review previews, never the live feed.
 */
export function buildScorebugSvg(state: ScorebugOverlay, size: OverlaySize, underlay = ''): string {
  const designWidth = (DESIGN_HEIGHT * size.width) / size.height;
  const body =
    state.style === 'lowerThird'
      ? lowerThird(state, designWidth)
      : state.style === 'setCard'
        ? setCard(state, designWidth)
        : bar(state);
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size.width}" height="${size.height}" ` +
    `viewBox="0 0 ${round(designWidth)} ${DESIGN_HEIGHT}">${underlay}${body}</svg>`
  );
}
