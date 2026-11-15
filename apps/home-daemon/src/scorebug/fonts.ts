import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/** Bundled Barlow Condensed (SIL OFL 1.1, see assets/fonts/OFL.txt). */
export const SCOREBUG_FONT_FAMILY = 'Barlow Condensed';
export const SCOREBUG_FONT_FILES = {
  600: fileURLToPath(new URL('../../assets/fonts/BarlowCondensed-SemiBold.ttf', import.meta.url)),
  700: fileURLToPath(new URL('../../assets/fonts/BarlowCondensed-Bold.ttf', import.meta.url)),
} as const;
export type FontWeight = keyof typeof SCOREBUG_FONT_FILES;

/**
 * Advance-width metrics read straight from the TrueType tables (cmap format 4,
 * hmtx, head, hhea, OS/2). Layout only needs widths to place markers after a
 * name and to shrink long names; kerning is ignored (a pixel or two at most).
 */
export class FontMetrics {
  private readonly unitsPerEm: number;
  readonly capHeight: number;
  private readonly advances: number[];
  private readonly glyphs = new Map<number, number>();

  constructor(font: Buffer) {
    const tables = new Map<string, number>();
    const count = font.readUInt16BE(4);
    for (let index = 0; index < count; index++) {
      const record = 12 + index * 16;
      tables.set(font.toString('ascii', record, record + 4), font.readUInt32BE(record + 8));
    }
    const table = (tag: string) => {
      const offset = tables.get(tag);
      if (offset === undefined) throw new Error(`font_table_${tag}`);
      return offset;
    };
    this.unitsPerEm = font.readUInt16BE(table('head') + 18);
    const metrics = font.readUInt16BE(table('hhea') + 34);
    const hmtx = table('hmtx');
    this.advances = Array.from({ length: metrics }, (_, index) =>
      font.readUInt16BE(hmtx + index * 4),
    );
    const os2 = table('OS/2');
    this.capHeight =
      font.readUInt16BE(os2) >= 2 ? font.readInt16BE(os2 + 88) / this.unitsPerEm : 0.7;

    const cmap = table('cmap');
    let subtable: number | undefined;
    for (let index = 0; index < font.readUInt16BE(cmap + 2); index++) {
      const record = cmap + 4 + index * 8;
      const platform = font.readUInt16BE(record);
      const encoding = font.readUInt16BE(record + 2);
      const offset = cmap + font.readUInt32BE(record + 4);
      if (font.readUInt16BE(offset) === 4 && (platform === 0 || (platform === 3 && encoding === 1)))
        subtable = offset;
    }
    if (subtable === undefined) throw new Error('font_cmap');
    const segments = font.readUInt16BE(subtable + 6) / 2;
    const ends = subtable + 14;
    const starts = ends + segments * 2 + 2;
    const deltas = starts + segments * 2;
    const ranges = deltas + segments * 2;
    for (let segment = 0; segment < segments; segment++) {
      const end = font.readUInt16BE(ends + segment * 2);
      const start = font.readUInt16BE(starts + segment * 2);
      const delta = font.readInt16BE(deltas + segment * 2);
      const rangeOffset = font.readUInt16BE(ranges + segment * 2);
      for (let code = start; code <= end && code !== 0xffff; code++) {
        let glyph: number;
        if (rangeOffset === 0) glyph = (code + delta) & 0xffff;
        else {
          const at = ranges + segment * 2 + rangeOffset + (code - start) * 2;
          glyph = font.readUInt16BE(at);
          if (glyph !== 0) glyph = (glyph + delta) & 0xffff;
        }
        if (glyph !== 0) this.glyphs.set(code, glyph);
      }
    }
  }

  /** Width in pixels of `text` at `size` px, including optional per-gap letter spacing. */
  width(text: string, size: number, letterSpacing = 0): number {
    let units = 0;
    let characters = 0;
    for (const character of text) {
      const glyph = this.glyphs.get(character.codePointAt(0)!) ?? 0;
      units += this.advances[Math.min(glyph, this.advances.length - 1)] ?? 0;
      characters++;
    }
    return (units / this.unitsPerEm) * size + letterSpacing * Math.max(0, characters - 1);
  }
}

let cached: Record<FontWeight, FontMetrics> | undefined;
export function scorebugFontMetrics(): Record<FontWeight, FontMetrics> {
  cached ??= {
    600: new FontMetrics(readFileSync(SCOREBUG_FONT_FILES[600])),
    700: new FontMetrics(readFileSync(SCOREBUG_FONT_FILES[700])),
  };
  return cached;
}
