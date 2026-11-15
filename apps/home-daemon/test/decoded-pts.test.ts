import { expect, it } from 'vitest';
import { DecodedPtsParser } from '../src/decoded-pts.js';

const record = (ordinal: number, pts: number, time = '0') =>
  `frame:${ordinal}    pts:${pts}    pts_time:${time}\nscorebug.source=1\n`;

it('parses complete pairs across every byte boundary with signed ticks and diagnostic times', () => {
  const text = record(0, -9000, '-0.1') + record(1, 0, '0') + record(2, 3000, '3.33333e-2');
  for (let split = 0; split <= text.length; split++) {
    const values: number[] = [];
    const errors: string[] = [];
    const parser = new DecodedPtsParser(
      (pts) => values.push(pts),
      (reason) => errors.push(reason),
    );
    parser.push(Buffer.from(text.slice(0, split)));
    parser.push(Buffer.from(text.slice(split)));
    parser.end();
    expect(values).toEqual([-9000, 0, 3000]);
    expect(errors).toEqual([]);
  }
});

it.each([
  record(1, 0),
  record(0, 0) + record(2, 1),
  record(0, 0) + record(0, 1),
  record(0, 9007199254740992),
  record(0, 0, 'Infinity'),
  record(0, 0, 'NaN'),
  record(0, 0).replace('frame:0', 'frame:-1'),
  record(0, 0).replace('frame:0', 'frame:9007199254740992'),
  record(0, 0).replace('pts:0', 'pts:1.5'),
  record(0, 0).replace('pts:0', 'pts:1e3'),
  record(0, 0).replace('scorebug.source=1', 'scorebug.source=1 SECRET'),
  'scorebug.source=1\n',
  'frame:0 pts:0 pts_time:0\nframe:1 pts:1 pts_time:0\nscorebug.source=1\n',
  'x'.repeat(1025),
  record(0, 0).slice(0, -1),
  'frame:0 pts:0 pts_time:0\n',
])('latches malformed or incomplete evidence without exposing input (%#)', (text) => {
  const errors: string[] = [];
  const parser = new DecodedPtsParser(
    () => {},
    (reason) => errors.push(reason),
  );
  parser.push(Buffer.from(text));
  parser.end();
  expect(errors).toHaveLength(1);
  expect(JSON.stringify(errors)).not.toContain('SECRET');
  expect(() => parser.push(Buffer.alloc(1_000_000, 65))).not.toThrow();
  expect(errors).toHaveLength(1);
});

it('contains callback exceptions and keeps draining after failure', () => {
  const errors: string[] = [];
  const parser = new DecodedPtsParser(
    () => {
      throw new Error('SECRET');
    },
    (reason) => {
      errors.push(reason);
      throw new Error('ANOTHER_SECRET');
    },
  );
  expect(() => parser.push(Buffer.from(record(0, 0) + record(1, 1)))).not.toThrow();
  expect(errors).toEqual(['callback']);
  parser.end();
});

it.each(['0x10', '0b1', '0o7'])('rejects non-decimal diagnostic timestamp syntax %s', (time) => {
  const errors: string[] = [];
  const values: number[] = [];
  const parser = new DecodedPtsParser(
    (value) => values.push(value),
    (reason) => errors.push(reason),
  );
  parser.push(Buffer.from(record(0, 0, time)));
  expect(errors).toEqual(['numeric']);
  expect(values).toEqual([]);
});
