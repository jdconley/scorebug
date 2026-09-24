import assert from 'node:assert/strict';

/** Fixed-profile score glyph evidence; source/background motion cannot establish a score. */
export function qualifyScoreTemplate({ actual, expected, alternative }) {
  for (const bytes of [actual, expected, alternative])
    assert(
      bytes instanceof Uint8Array && bytes.length > 0 && bytes.length <= 90000,
      'Bounded gray score crop required',
    );
  assert.equal(actual.length, expected.length);
  assert.equal(alternative.length, expected.length);
  let discriminating = 0,
    expectedMatches = 0,
    alternativeMatches = 0,
    common = 0,
    commonMatches = 0;
  for (let i = 0; i < expected.length; i++) {
    const white = expected[i] >= 220,
      black = expected[i] <= 60;
    const otherWhite = alternative[i] >= 220,
      otherBlack = alternative[i] <= 60;
    if (white && otherWhite) {
      common++;
      if (actual[i] >= 180) commonMatches++;
    }
    if ((white && otherBlack) || (black && otherWhite)) {
      discriminating++;
      if (white ? actual[i] >= 180 : actual[i] <= 140) expectedMatches++;
      if (otherWhite ? actual[i] >= 180 : actual[i] <= 140) alternativeMatches++;
    }
  }
  assert(discriminating >= 20 && common >= 100, 'Insufficient distinct score glyph support');
  const report = {
    discriminatingPixels: discriminating,
    expectedAgreement: expectedMatches / discriminating,
    alternativeAgreement: alternativeMatches / discriminating,
    commonGlyphAgreement: commonMatches / common,
  };
  assert(
    report.expectedAgreement >= 0.9 &&
      report.alternativeAgreement <= 0.1 &&
      report.commonGlyphAgreement >= 0.9,
    `Score glyph mismatch: ${JSON.stringify(report)}`,
  );
  return { ...report, passed: true };
}
