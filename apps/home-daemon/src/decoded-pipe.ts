import type { Readable } from 'node:stream';
export type DecodedPipeObserver = {
  push(chunk: Buffer): void;
  end(): void;
  invalidatePipe(): void;
};
/** A side-channel failure invalidates evidence, never publication ownership. */
export function observeDecodedPipe(
  pipe: Readable,
  observers: readonly DecodedPipeObserver[],
  onEOF: () => void,
) {
  let eof = false;
  const invalidate = () => observers.forEach((observer) => observer.invalidatePipe());
  const end = () => observers.forEach((observer) => observer.end());
  pipe.on('data', (chunk: Buffer) => observers.forEach((observer) => observer.push(chunk)));
  pipe.once('end', () => {
    eof = true;
    onEOF();
    end();
  });
  pipe.on('error', invalidate);
  pipe.once('close', () => {
    if (!eof) {
      invalidate();
      end();
    }
  });
}
