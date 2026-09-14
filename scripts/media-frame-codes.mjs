// Sixteen binary cells, each 20 pixels wide, in the source's top-left 320x32 strip.
// Insert before encoding or frame-rate conversion. N is the source frame number.
export const sourceFrameCodeFilter =
  "geq=lum='if(lt(Y,32)*lt(X,320),16+219*mod(floor(N/pow(2,floor(X/20))),2),lum(X,Y))':" +
  "cb='if(lt(Y,16)*lt(X,160),128,cb(X,Y))':" +
  "cr='if(lt(Y,16)*lt(X,160),128,cr(X,Y))'";

// Point sampling lands in each cell's center, away from lossy block edges.
export const frameCodeReadFilter = 'crop=320:32:0:0,scale=16:1:flags=neighbor,format=gray';

export function decodeFrameCodes(bytes) {
  if (!bytes.length || bytes.length % 16) throw new Error('Invalid frame-code sample length');
  const codes = [];
  for (let offset = 0; offset < bytes.length; offset += 16) {
    let code = 0;
    for (let bit = 0; bit < 16; bit++) {
      const value = bytes[offset + bit];
      if (value > 64 && value < 192) throw new Error('Ambiguous frame-code cell');
      if (value >= 192) code |= 1 << bit;
    }
    const previous = codes.at(-1);
    if (previous !== undefined && (code < previous || code - previous > 30))
      throw new Error('Source frame codes regressed or jumped');
    codes.push(code);
  }
  return codes;
}
