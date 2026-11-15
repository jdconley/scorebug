import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, open, realpath, rename, unlink } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';

/** Local simulator QA files only. The caller owns the existing container and
 * joins every operation; the exchange sampler separately enforces its deadline. */
export async function capacityClockFiles(directory) {
  assert(typeof directory === 'string' && isAbsolute(directory), 'Expected absolute QA directory');
  assert((await lstat(directory)).isDirectory(), 'QA path is not a regular directory');
  const root = await realpath(directory);
  let busy = false;
  async function exclusive(operation) {
    assert(!busy, 'Clock file operation already in progress');
    busy = true;
    try {
      return await operation();
    } finally {
      busy = false;
    }
  }
  return {
    write: (request) =>
      exclusive(async () => {
        const json = JSON.stringify(request);
        assert(
          typeof json === 'string' && Buffer.byteLength(json) <= 4096,
          'Oversized clock request',
        );
        const temporary = join(root, `.capacity-clock-${randomUUID()}.tmp`);
        let file,
          owned = false;
        try {
          file = await open(
            temporary,
            constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
            0o600,
          );
          owned = true;
          await file.writeFile(json, 'utf8');
          await file.close();
          file = undefined;
          await rename(temporary, join(root, 'capacity-clock-request.json'));
          owned = false;
        } finally {
          try {
            await file?.close();
          } finally {
            if (owned) await unlink(temporary);
          }
        }
      }),
    read: () =>
      exclusive(async () => {
        let file;
        try {
          try {
            file = await open(
              join(root, 'capacity-clock-response.json'),
              constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
            );
          } catch (error) {
            if (error.code === 'ENOENT') return null;
            throw error;
          }
          const stat = await file.stat();
          assert(
            stat.isFile() && stat.size >= 0 && stat.size <= 16384,
            'Invalid clock response file',
          );
          const bytes = Buffer.alloc(stat.size + 1);
          let length = 0;
          while (length < bytes.length) {
            const { bytesRead } = await file.read(bytes, length, bytes.length - length, null);
            if (!bytesRead) break;
            length += bytesRead;
          }
          assert.equal(length, stat.size, 'Clock response changed during read');
          return JSON.parse(
            new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, length)),
          );
        } finally {
          await file?.close();
        }
      }),
  };
}
