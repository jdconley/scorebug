import type { Readable } from 'node:stream';
export type DecodedPipeObserver = { push(chunk: Buffer): void; end(): void };
/** Feed FFmpeg's decoded-PTS pipe to an observer and always drain it. A pipe failure
 * ends the observer; it never stops the broadcast. */
export function observeDecodedPipe(pipe: Readable, observer?: DecodedPipeObserver) {
  let ended = false;
  const end = () => {
    if (ended) return;
    ended = true;
    observer?.end();
  };
  pipe.on('data', (chunk: Buffer) => {
    if (!ended) observer?.push(chunk);
  });
  pipe.once('end', end);
  pipe.on('error', end);
  pipe.once('close', end);
}
