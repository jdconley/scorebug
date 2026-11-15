import { renderAsync } from '@resvg/resvg-js';
import type { ScorebugOverlay } from '@scorebug/protocol';
import { SCOREBUG_FONT_FAMILY, SCOREBUG_FONT_FILES } from './fonts.js';
import { buildScorebugSvg, type OverlaySize } from './layout.js';

const options = {
  font: {
    fontFiles: Object.values(SCOREBUG_FONT_FILES),
    loadSystemFonts: false,
    defaultFontFamily: SCOREBUG_FONT_FAMILY,
  },
  background: 'rgba(0,0,0,0)',
};

/** Rasterize on the libuv pool; resvg returns premultiplied RGBA at exactly `size`. */
async function rasterize(state: ScorebugOverlay, size: OverlaySize) {
  const image = await renderAsync(buildScorebugSvg(state, size), options);
  if (image.width !== size.width || image.height !== size.height)
    throw new Error('scorebug_render_size');
  return image;
}

/**
 * Straight-alpha RGBA, the convention FFmpeg's rawvideo `rgba` and `overlay`
 * (alpha=straight) assume. resvg's tiny-skia output is premultiplied.
 */
export async function renderScorebugRgba(
  state: ScorebugOverlay,
  size: OverlaySize,
): Promise<Buffer> {
  return demultiply((await rasterize(state, size)).pixels);
}

/** In place: premultiplied RGBA to straight RGBA. */
export function demultiply(pixels: Buffer): Buffer {
  for (let index = 0; index < pixels.length; index += 4) {
    const alpha = pixels[index + 3]!;
    if (alpha === 0 || alpha === 255) continue;
    for (let channel = 0; channel < 3; channel++)
      pixels[index + channel] = Math.min(255, Math.round((pixels[index + channel]! * 255) / alpha));
  }
  return pixels;
}

export async function renderScorebugPng(
  state: ScorebugOverlay,
  size: OverlaySize,
): Promise<Buffer> {
  return (await rasterize(state, size)).asPng();
}

export function transparentFrame(size: OverlaySize): Buffer {
  return Buffer.alloc(size.width * size.height * 4);
}
