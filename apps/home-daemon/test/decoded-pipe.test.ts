import { PassThrough } from 'node:stream';
import { expect, it } from 'vitest';
import { observeDecodedPipe } from '../src/decoded-pipe.js';
import { DecodedFrameHistory } from '../src/decoded-frame-history.js';
import { DecodedVideoTelemetry, DecodedVideoLifetime } from '../src/decoded-video.js';
it.each(['error', 'close'])(
  'quarantines all decoded observations after unexpected pipe %s',
  (event) => {
    const pipe = new PassThrough(),
      history = new DecodedFrameHistory(() => 0),
      telemetry = new DecodedVideoTelemetry(() => 0),
      lifetime = new DecodedVideoLifetime();
    let eof = false;
    observeDecodedPipe(pipe, [history, telemetry, lifetime], () => {
      eof = true;
    });
    expect(() => pipe.emit(event, new Error('SECRET'))).not.toThrow();
    pipe.emit('close');
    expect(eof).toBe(false);
    expect(history.snapshot()).toMatchObject({ ended: true, invalidReason: 'pipe' });
    expect(telemetry.snapshot()).toMatchObject({ ended: true, invalidReason: 'incomplete' });
    expect(lifetime.snapshot()).toMatchObject({ ended: true, invalidReason: 'incomplete' });
  },
);
it('normal EOF retains closed decoder evidence and ignores later error notifications', () => {
  const pipe = new PassThrough(),
    history = new DecodedFrameHistory(() => 0),
    telemetry = new DecodedVideoTelemetry(() => 0),
    lifetime = new DecodedVideoLifetime();
  let eof = 0;
  observeDecodedPipe(pipe, [history, telemetry, lifetime], () => {
    eof++;
  });
  pipe.emit('data', Buffer.from('frame:0 pts:0 pts_time:0\nscorebug.source=1\n'));
  pipe.emit('end');
  const saved = history.snapshot();
  expect(() => pipe.emit('error', new Error('SECRET'))).not.toThrow();
  pipe.emit('close');
  expect(eof).toBe(1);
  expect(history.snapshot()).toEqual(saved);
  expect(saved).toMatchObject({ acceptedFrames: 1, ended: true, invalidReason: null });
  expect(telemetry.snapshot().invalidReason).toBeNull();
  expect(lifetime.snapshot().invalidReason).toBeNull();
});
