import { expect, it } from 'vitest';
import { EncoderDiagnostics } from '../src/encoder-diagnostics.mjs';

it('classifies split lines without retaining diagnostic text or credentials', () => {
  const parser = new EncoderDiagnostics();
  parser.push(Buffer.from('[in#0 @ 0x12] Error during demu'));
  parser.push(
    Buffer.from(
      'xing: Input/output error\n[tcp @ 0x12] Connection to rtmp://SECRET failed: Connection refused\n',
    ),
  );
  parser.push(Buffer.from('Error opening output rtmp://SECRET\nUnknown SECRET\n'));
  parser.end();
  expect(parser.snapshot()).toEqual({
    counts: {
      inputReadError: 1,
      outputOpenError: 1,
      connectionRefused: 1,
      connectionTimeout: 0,
      ioError: 1,
      invalidData: 0,
      corruptPacket: 0,
      decodeError: 0,
      endOfFile: 0,
      missingReference: 0,
      invalidSlice: 0,
      concealment: 0,
    },
    unmatchedLines: 1,
    oversizedLines: 0,
    incompleteLine: false,
    ended: true,
    pipeError: false,
    drainTimedOut: false,
  });
  expect(JSON.stringify(parser.snapshot())).not.toContain('SECRET');
});

it('bounds framing, counts unmatched tails, freezes at EOF and copies snapshots', () => {
  const parser = new EncoderDiagnostics();
  for (let i = 0; i < 20; i++) parser.push(Buffer.from('SECRET'.repeat(1000)));
  parser.push(
    Buffer.from(
      '\nInvalid data found when processing input\nPacket corrupt\nError submitting packet to decoder\nConnection timed out\nEnd of file\nSECRET',
    ),
  );
  parser.end();
  const snapshot = parser.snapshot();
  expect(snapshot).toMatchObject({
    oversizedLines: 1,
    unmatchedLines: 0,
    incompleteLine: true,
    ended: true,
    counts: {
      invalidData: 1,
      corruptPacket: 1,
      decodeError: 1,
      connectionTimeout: 1,
      endOfFile: 1,
    },
  });
  parser.push(Buffer.from('Connection refused\n'));
  parser.end();
  expect(parser.snapshot()).toEqual(snapshot);
  snapshot.counts.invalidData = 999;
  expect(parser.snapshot().counts.invalidData).toBe(1);
  expect(JSON.stringify(parser.snapshot())).not.toContain('SECRET');
});

it('absorbs pipe errors before and after finalization without retaining error text', async () => {
  const { PassThrough } = await import('node:stream');
  const { observeEncoderDiagnostics } = await import('../src/encoder-diagnostics.mjs');
  const parser = new EncoderDiagnostics();
  const pipe = new PassThrough();
  observeEncoderDiagnostics(pipe, parser);
  expect(() => pipe.emit('error', new Error('SECRET'))).not.toThrow();
  parser.end();
  expect(parser.snapshot()).toMatchObject({ pipeError: true, ended: true, drainTimedOut: false });
  expect(() => pipe.emit('error', new Error('LATE_SECRET'))).not.toThrow();
  expect(JSON.stringify(parser.snapshot())).not.toContain('SECRET');
  pipe.destroy();
});

it('classifies H264 reference, slice and concealment diagnostics without exporting raw lines', () => {
  const parser = new EncoderDiagnostics();
  for (const line of [
    '[h264 @ 0x1] reference picture missing during reorder',
    'Missing reference picture, default is 0',
    'co located POCs unavailable',
    'mmco: unref short failure',
    'mmco: unref long failure',
    'decode_slice_header error',
    'non-existing PPS 0 referenced',
    'concealing 12 DC, 12 AC, 12 MV errors in P frame',
    'Cannot use previous picture in error concealment',
    'Cannot use next picture in error concealment',
  ]) {
    const bytes = Buffer.from(line + ' SECRET\n');
    parser.push(bytes.subarray(0, 9));
    parser.push(bytes.subarray(9));
  }
  parser.end();
  expect(parser.snapshot().counts).toMatchObject({
    missingReference: 5,
    invalidSlice: 2,
    concealment: 3,
  });
  expect(parser.snapshot().unmatchedLines).toBe(0);
  expect(JSON.stringify(parser.snapshot())).not.toContain('SECRET');
});
