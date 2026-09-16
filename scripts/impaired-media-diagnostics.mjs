import { decodeFrameCodes } from './media-frame-codes.mjs';

// Best-effort observations for deliberately degraded media, never a qualification gate.
// Each complete 16-byte raw sample represents one frame emitted by the decoder even
// when damage prevents its source identity from being recovered.
export function inspectFrameCodeSamples(bytes, times) {
  const decodedFrames = bytes === null ? null : Math.floor(bytes.length / 16);
  let codes = null;
  let sourceIdentityError = null;
  try {
    if (bytes === null) throw new Error('Frame-code samples unavailable');
    codes = decodeFrameCodes(bytes);
    if (codes.some((id) => id < 0 || id >= 420))
      throw new Error('Source frame code outside fixture range');
  } catch (error) {
    codes = null;
    sourceIdentityError = error.message;
  }
  const validTimes =
    codes !== null &&
    times.length === codes.length &&
    times.length > 1 &&
    times.every(
      (time, i) => typeof time === 'number' && Number.isFinite(time) && (!i || time > times[i - 1]),
    );
  const freshFrames = codes === null ? null : new Set(codes).size;
  return {
    decodedFrames,
    validSourceIDs: codes !== null,
    sourceIdentityError,
    firstSourceFrame: codes?.[0] ?? null,
    lastSourceFrame: codes?.at(-1) ?? null,
    freshFrames,
    freshFps: validTimes ? freshFrames / (times.at(-1) - times[0] + 1 / 30) : null,
    sourceFrameLoss: codes === null ? null : 1 - freshFrames / (codes.at(-1) - codes[0] + 1),
  };
}
