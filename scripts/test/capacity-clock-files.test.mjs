import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm, symlink, lstat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { sampleCapacityClock } from '../capacity-clock-exchange.mjs';
const implementation = await import('../capacity-clock-files.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
const scope = {
  recordingID: 'recording',
  matchID: 'match',
  broadcastGeneration: 1,
  publishingAttemptID: '11111111-1111-4111-8111-111111111111',
  appliedProfileRevision: '1',
};
const request = () => ({
  formatVersion: 1,
  scope,
  sequence: 1,
  nonce: '22222222-2222-4222-8222-222222222222',
});
const response = () => ({
  formatVersion: 1,
  scope,
  sample: { sequence: 1, nonce: request().nonce, nativeAt: 900001 },
});
async function directory(t) {
  const path = await mkdtemp(join(tmpdir(), 'capacity-clock-'));
  t.after(() => rm(path, { recursive: true, force: true }));
  return path;
}
async function files(path) {
  assert.equal(typeof implementation.capacityClockFiles, 'function');
  return implementation.capacityClockFiles(path);
}
test('owned clock files atomically replace only the request and read the bounded response', async (t) => {
  const path = await directory(t),
    io = await files(path);
  await writeFile(join(path, 'input.mov'), 'untouched');
  assert.equal(await io.read(), null);
  await io.write(request());
  assert.deepEqual(
    JSON.parse(await readFile(join(path, 'capacity-clock-request.json'), 'utf8')),
    request(),
  );
  assert.equal((await lstat(join(path, 'capacity-clock-request.json'))).mode & 0o777, 0o600);
  await io.write({ ...request(), sequence: 2 });
  assert.equal(
    JSON.parse(await readFile(join(path, 'capacity-clock-request.json'), 'utf8')).sequence,
    2,
  );
  await writeFile(join(path, 'capacity-clock-response.json'), JSON.stringify(response()));
  assert.deepEqual(await io.read(), response());
  assert.deepEqual((await readdir(path)).sort(), [
    'capacity-clock-request.json',
    'capacity-clock-response.json',
    'input.mov',
  ]);
  assert.equal(await readFile(join(path, 'input.mov'), 'utf8'), 'untouched');
});
test('file adapter composes with the nonce sampler using real joined file I/O', async (t) => {
  const path = await directory(t),
    io = await files(path);
  const result = await sampleCapacityClock({
    scope,
    sequence: 1,
    nonce: request().nonce,
    signal: new AbortController().signal,
    now: () => 100,
    write: async (value) => {
      await io.write(value);
      const observed = JSON.parse(
        await readFile(join(path, 'capacity-clock-request.json'), 'utf8'),
      );
      assert.deepEqual(observed, value);
      await writeFile(join(path, 'capacity-clock-response.json'), JSON.stringify(response()));
    },
    read: io.read,
  });
  assert.deepEqual(result.response, response());
});
test('clock adapter requires an existing absolute directory without following its leaf symlink', async (t) => {
  const path = await directory(t);
  await assert.rejects(files('relative'));
  await assert.rejects(files(join(path, 'missing')));
  await writeFile(join(path, 'ordinary'), 'x');
  await assert.rejects(files(join(path, 'ordinary')));
  await symlink(path, join(path, 'linked'));
  await assert.rejects(files(join(path, 'linked')));
  assert.deepEqual((await readdir(path)).sort(), ['linked', 'ordinary']);
});
for (const [name, value] of [
  ['oversized', Buffer.alloc(16385, 32)],
  ['malformed JSON', Buffer.from('{')],
  ['invalid UTF-8', Buffer.from([0x22, 0xff, 0x22])],
])
  test(`clock reader rejects ${name}`, async (t) => {
    const path = await directory(t),
      io = await files(path);
    await writeFile(join(path, 'capacity-clock-response.json'), value);
    await assert.rejects(io.read());
  });
test('clock reader rejects links and directories', async (t) => {
  const path = await directory(t),
    io = await files(path),
    leaf = join(path, 'capacity-clock-response.json');
  await writeFile(join(path, 'other'), JSON.stringify(response()));
  await symlink(join(path, 'other'), leaf);
  await assert.rejects(io.read());
  await rm(leaf);
  await mkdir(leaf);
  await assert.rejects(io.read());
});
test('clock writer enforces the UTF-8 byte bound before any mutation', async (t) => {
  const path = await directory(t),
    io = await files(path);
  await io.write(request());
  for (const value of [{ extra: 'é'.repeat(4096) }, undefined, { value: 1n }])
    await assert.rejects(io.write(value));
  assert.deepEqual(
    JSON.parse(await readFile(join(path, 'capacity-clock-request.json'), 'utf8')),
    request(),
  );
  assert.deepEqual(await readdir(path), ['capacity-clock-request.json']);
});
test('failed atomic replacement closes and removes its owned temporary file', async (t) => {
  const path = await directory(t),
    io = await files(path);
  await mkdir(join(path, 'capacity-clock-request.json'));
  await assert.rejects(io.write(request()));
  assert.deepEqual(await readdir(path), ['capacity-clock-request.json']);
});
test('atomic replacement never follows a request symlink', async (t) => {
  const path = await directory(t),
    io = await files(path);
  await writeFile(join(path, 'other'), 'untouched');
  await symlink(join(path, 'other'), join(path, 'capacity-clock-request.json'));
  await io.write(request());
  assert.equal(await readFile(join(path, 'other'), 'utf8'), 'untouched');
  assert.equal((await lstat(join(path, 'capacity-clock-request.json'))).isSymbolicLink(), false);
});
test('overlapping operations are rejected instead of overwriting another in-flight challenge', async (t) => {
  const path = await directory(t),
    io = await files(path);
  const first = io.write(request());
  const second = assert.rejects(io.write({ ...request(), sequence: 2 }));
  await Promise.all([first, second]);
  assert.equal(
    JSON.parse(await readFile(join(path, 'capacity-clock-request.json'), 'utf8')).sequence,
    1,
  );
});
