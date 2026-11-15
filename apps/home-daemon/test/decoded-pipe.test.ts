import { PassThrough } from 'node:stream';
import { expect, it } from 'vitest';
import { observeDecodedPipe } from '../src/decoded-pipe.js';
import { DecodedPtsParser } from '../src/decoded-pts.js';

const record = (ordinal: number, pts: number) =>
  `frame:${ordinal} pts:${pts} pts_time:0\nscorebug.source=1\n`;

it.each(['end', 'error', 'close'])(
  'ends the observer once on pipe %s and ignores later data',
  (event) => {
    const pipe = new PassThrough();
    const values: number[] = [];
    const errors: string[] = [];
    const parser = new DecodedPtsParser(
      (pts) => values.push(pts),
      (reason) => errors.push(reason),
    );
    let ends = 0;
    observeDecodedPipe(pipe, {
      push: (chunk) => parser.push(chunk),
      end: () => {
        ends++;
        parser.end();
      },
    });
    pipe.emit('data', Buffer.from(record(0, 3000)));
    expect(() => pipe.emit(event, new Error('SECRET'))).not.toThrow();
    pipe.emit('close');
    pipe.emit('data', Buffer.from(record(1, 6000)));
    expect(ends).toBe(1);
    expect(values).toEqual([3000]);
    expect(errors).toEqual([]);
  },
);

it('drains a pipe with no observer', () => {
  const pipe = new PassThrough();
  observeDecodedPipe(pipe);
  expect(pipe.readableFlowing).toBe(true);
});
