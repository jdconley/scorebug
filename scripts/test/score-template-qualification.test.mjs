import assert from 'node:assert/strict';
import { test } from 'node:test';
import { qualifyScoreTemplate } from '../score-template-qualification.mjs';
function fixture() {
  const expected = Buffer.alloc(1000, 0),
    alternative = Buffer.alloc(1000, 0);
  expected.fill(255, 0, 300);
  alternative.fill(255, 0, 300);
  expected.fill(255, 400, 500);
  alternative.fill(255, 500, 600);
  const actual = Buffer.from(expected.map((x) => (x > 200 ? 235 : 35)));
  return { expected, alternative, actual };
}
test('requires the expected glyph state and rejects the other score', () => {
  const input = fixture();
  assert.equal(qualifyScoreTemplate(input).passed, true);
  input.actual = Buffer.from(input.alternative);
  assert.throws(() => qualifyScoreTemplate(input));
});
test('limited pixel compression noise still preserves a clear score', () => {
  const input = fixture();
  input.actual.fill(150, 410, 420);
  assert.equal(qualifyScoreTemplate(input).passed, true);
});
for (const [name, change] of Object.entries({
  'white court': (x) => x.actual.fill(255),
  'black court': (x) => x.actual.fill(0),
  'changed background only': (x) => {
    x.actual = Buffer.from(x.alternative);
    x.actual.fill(255, 700);
  },
  'missing common text': (x) => x.actual.fill(0, 0, 300),
  'too much glyph damage': (x) => x.actual.fill(0, 400, 430),
  'identical templates': (x) => (x.alternative = Buffer.from(x.expected)),
  'undersized templates': (x) => {
    x.expected = x.expected.slice(0, 20);
    x.alternative = x.alternative.slice(0, 20);
    x.actual = x.actual.slice(0, 20);
  },
  'mismatched crop': (x) => (x.actual = x.actual.slice(1)),
}))
  test(`rejects ${name}`, () => {
    const input = fixture();
    change(input);
    assert.throws(() => qualifyScoreTemplate(input));
  });

test('antialiased digit strokes provide distinct support while common text stays bright', () => {
  const input = fixture();
  for (const template of [input.expected, input.alternative])
    for (let i = 400; i < 600; i++) if (template[i] === 255) template[i] = 195;
  input.actual = Buffer.from(input.expected);
  assert.equal(qualifyScoreTemplate(input).passed, true);
  assert.throws(() => qualifyScoreTemplate({ ...input, actual: input.alternative }));
  input.actual.fill(150, 400, 600);
  assert.throws(() => qualifyScoreTemplate(input));
});
test('faint ambiguous digit edges cannot manufacture distinct score support', () => {
  const input = fixture();
  for (const template of [input.expected, input.alternative])
    for (let i = 400; i < 600; i++) if (template[i] === 255) template[i] = 189;
  input.actual = Buffer.from(input.expected);
  assert.throws(() => qualifyScoreTemplate(input));
});
