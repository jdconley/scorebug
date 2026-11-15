import { mkdir, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { randomBytes } from 'node:crypto';

/**
 * Atomically write `text` to `path` so the scorebug overlay feed never reads
 * a partial file. Writes to `<path>.tmp.<rand>` then renames, which is atomic
 * on the same filesystem.
 */
export async function atomicWrite(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tmp = join(dirname(path), `.${randomBytes(6).toString('hex')}.tmp`);
  await writeFile(tmp, text, { encoding: 'utf8' });
  await rename(tmp, path);
}

export function scoreFilePath(dir: string): string {
  return join(dir, 'scorebug.json');
}
