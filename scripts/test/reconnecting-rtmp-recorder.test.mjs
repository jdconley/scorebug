import assert from 'node:assert/strict';
import test from 'node:test';
import net from 'node:net';
import { once } from 'node:events';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
const { startReconnectingRTMPRecorder } = await import('../reconnecting-rtmp-recorder.mjs').catch(
  () => ({}),
);
const closedSocket = (socket) => new Promise((resolve) => socket.once('close', resolve));
const deferred = () => {
  let resolve;
  const promise = new Promise((r) => (resolve = r));
  return { promise, resolve };
};
async function fixture(t, options = {}) {
  const artifact = await mkdtemp(join(tmpdir(), 'reconnecting-recorder-'));
  const started = [],
    calls = [];
  const startRecorder = async ({ artifact: directory, port }) => {
    calls.push(directory);
    if (options.beforeStart) await options.beforeStart(calls.length);
    const sockets = new Set(),
      complete = deferred(),
      bytes = [];
    const server = net.createServer({ allowHalfOpen: true }, (socket) => {
      sockets.add(socket);
      socket.on('data', (b) => {
        bytes.push(b);
        options.received?.(socket);
      });
      socket.on('error', () => {});
      socket.on('end', () => socket.end('ack'));
      socket.on('close', () => {
        sockets.delete(socket);
        complete.resolve();
      });
    });
    server.listen(port, '127.0.0.1');
    await once(server, 'listening');
    const entry = { directory, stops: 0, finishes: 0, finalized: deferred() };
    started.push(entry);
    const close = () => new Promise((resolve) => server.close(resolve));
    return {
      url: `rtmp://127.0.0.1:${port}/live/fixture`,
      async finish() {
        entry.finishes++;
        await complete.promise;
        if (options.beforeFinish) await options.beforeFinish();
        await close();
        await mkdir(join(directory, 'sink-recordings'), { recursive: true });
        const path = join(directory, 'sink-recordings/direct.mp4');
        await writeFile(path, Buffer.concat(bytes), { flag: 'wx' });
        entry.finalized.resolve();
        return options.resultPath ?? path;
      },
      async stop() {
        entry.stops++;
        for (const socket of sockets) socket.destroy();
        complete.resolve();
        await close();
      },
    };
  };
  assert.equal(typeof startReconnectingRTMPRecorder, 'function');
  const recorder = await startReconnectingRTMPRecorder(
    { artifact, ffmpeg: '/fixture/ffmpeg', port: 0 },
    {
      startRecorder,
      finishMs: options.finishMs ?? 500,
      ...options.dependencies,
    },
  );
  t.after(async () => {
    await recorder.stop();
    await rm(artifact, { recursive: true, force: true });
  });
  return { artifact, recorder, started, calls, port: Number(new URL(recorder.url).port) };
}
async function connect(port) {
  const socket = net.connect({ host: '127.0.0.1', port });
  socket.on('error', () => {});
  await once(socket, 'connect');
  return socket;
}
async function publish(port, bytes) {
  const socket = await connect(port),
    response = [];
  socket.on('data', (b) => response.push(b));
  const closed = closedSocket(socket);
  socket.end(bytes);
  await closed;
  return Buffer.concat(response);
}
test('exports reconnectable recorder', () =>
  assert.equal(typeof startReconnectingRTMPRecorder, 'function'));
test('two sequential publishers retain separate ordered byte-exact recordings', async (t) => {
  const f = await fixture(t),
    a = Buffer.alloc(300_000, 0x61),
    b = Buffer.alloc(170_000, 0x62);
  assert.equal((await publish(f.port, a)).toString(), 'ack');
  assert.equal((await publish(f.port, b)).toString(), 'ack');
  const first = f.recorder.finish();
  assert.equal(f.recorder.finish(), first);
  const report = await first;
  assert.equal(report.diagnosticOnly, true);
  assert.equal(report.mediaQualified, false);
  assert.equal(report.recoveryQualified, false);
  assert.equal(report.closed, true);
  assert.equal(report.rejectedConnections, 0);
  assert.equal(report.sessions.length, 2);
  for (const [index, expected] of [a, b].entries()) {
    const session = report.sessions[index];
    assert.equal(session.sequence, index + 1);
    assert.equal(session.failure, null);
    assert.equal(session.interrupted, false);
    assert.equal(session.receivedBytes, expected.length);
    assert.equal(session.returnedBytes, 3);
    assert(session.acceptedAt <= session.connectedAt && session.connectedAt <= session.closedAt);
    assert.deepEqual(await readFile(join(f.artifact, session.recordingRelativePath)), expected);
  }
  assert.equal(f.started.length, 2);
  assert(f.started.every((s) => s.finishes === 1 && s.stops === 0));
  assert.deepEqual(
    JSON.parse(await readFile(join(f.artifact, 'reconnecting-recorder/manifest.json'))),
    report,
  );
});
test('idle shutdown starts no recorder and repeated stop joins', async (t) => {
  const f = await fixture(t);
  const first = f.recorder.stop();
  assert.equal(f.recorder.stop(), first);
  const report = await first;
  assert.equal(f.started.length, 0);
  assert.equal(report.sessions.length, 0);
  assert.equal(report.terminal, 'stopped');
});
test('stop during recorder startup joins and stops a late child', async (t) => {
  const gate = deferred(),
    entered = deferred();
  const f = await fixture(t, {
    beforeStart: async () => {
      entered.resolve();
      await gate.promise;
    },
  });
  const socket = await connect(f.port);
  socket.write('pending');
  await entered.promise;
  const closed = closedSocket(socket),
    stopped = f.recorder.stop();
  gate.resolve();
  await stopped;
  await closed;
  assert.equal(f.started.length, 1);
  assert.equal(f.started[0].stops, 1);
  assert.equal((await stopped).sessions[0].interrupted, true);
});
test('early disconnect cannot leave a recorder created after the socket closed', async (t) => {
  const gate = deferred(),
    entered = deferred();
  const f = await fixture(t, {
    beforeStart: async () => {
      entered.resolve();
      await gate.promise;
    },
  });
  const socket = await connect(f.port);
  await entered.promise;
  const closed = closedSocket(socket);
  socket.destroy();
  await closed;
  gate.resolve();
  const report = await f.recorder.finish();
  assert.equal(report.sessions.length, 1);
  assert.notEqual(report.sessions[0].failure, null);
  assert.equal(f.started[0].stops + f.started[0].finishes, 1);
});
test('startup failure is recorded without exposing arbitrary errors and later connection works', async (t) => {
  const f = await fixture(t, {
    beforeStart: (n) => {
      if (n === 1) throw new Error('secret endpoint');
    },
  });
  await publish(f.port, Buffer.from('failed'));
  assert.equal((await publish(f.port, Buffer.from('next'))).toString(), 'ack');
  const report = await f.recorder.finish();
  assert.equal(report.sessions.length, 2);
  assert.equal(report.sessions[0].failure, 'recorder-start');
  assert.equal(report.sessions[1].failure, null);
  assert.doesNotMatch(JSON.stringify(report), /secret endpoint/);
});
test('finish deadline interrupts an active connection and joins it', async (t) => {
  const entered = deferred();
  const f = await fixture(t, { finishMs: 20, beforeStart: () => entered.resolve() }),
    socket = await connect(f.port);
  const closed = closedSocket(socket);
  socket.write('not finished');
  await entered.promise;
  const report = await f.recorder.finish();
  await closed;
  assert.equal(report.finishTimedOut, true);
  assert.equal(report.sessions[0].interrupted, true);
  assert(f.started.every((s) => s.stops === 1));
});
test('only two concurrent sessions are admitted and excess is retained as rejection', async (t) => {
  const entered = deferred(),
    gate = deferred();
  let count = 0;
  const f = await fixture(t, {
    beforeStart: async () => {
      if (++count === 2) entered.resolve();
      await gate.promise;
    },
  });
  const a = await connect(f.port),
    b = await connect(f.port);
  await entered.promise;
  const c = await connect(f.port),
    closed = closedSocket(c);
  await closed;
  const stopped = f.recorder.stop();
  gate.resolve();
  await stopped;
  a.destroy();
  b.destroy();
  assert.equal((await stopped).sessions.length, 2);
  assert.equal((await stopped).rejectedConnections, 1);
});
test('total session budget cannot be bypassed by sequential reconnects', async (t) => {
  const f = await fixture(t);
  for (let i = 0; i < 8; i++) {
    assert.equal((await publish(f.port, Buffer.from('x'))).toString(), 'ack');
    await f.started[i].finalized.promise;
    // Finish has joined both sockets and its file write. Drain its remaining
    // promise continuations before testing total admission, not concurrency.
    await new Promise(setImmediate);
  }
  await publish(f.port, Buffer.from('excess'));
  const report = await f.recorder.finish();
  assert.equal(report.sessions.length, 8);
  assert.equal(report.rejectedConnections, 1);
});
test('exclusive output directory prevents overwriting earlier evidence', async (t) => {
  const artifact = await mkdtemp(join(tmpdir(), 'reconnecting-existing-'));
  t.after(() => rm(artifact, { recursive: true, force: true }));
  await mkdir(join(artifact, 'reconnecting-recorder'));
  let spawned = false;
  assert.equal(typeof startReconnectingRTMPRecorder, 'function');
  await assert.rejects(() =>
    startReconnectingRTMPRecorder(
      { artifact, ffmpeg: 'ffmpeg', port: 0 },
      {
        startRecorder: () => {
          spawned = true;
        },
      },
    ),
  );
  assert.equal(spawned, false);
});

test('failed recorder finalization is retained and cleanup is joined', async (t) => {
  const f = await fixture(t, {
    beforeFinish: () => {
      throw new Error('private secret');
    },
  });
  await publish(f.port, Buffer.from('data'));
  const report = await f.recorder.finish();
  assert.equal(report.sessions[0].failure, 'recorder-finish');
  assert.equal(f.started[0].stops, 1);
  assert.doesNotMatch(JSON.stringify(report), /private secret/);
});
test('foreign returned path cannot claim a saved session', async (t) => {
  const f = await fixture(t, { resultPath: '/outside/recording.mp4' });
  await publish(f.port, Buffer.from('data'));
  const report = await f.recorder.finish();
  assert.equal(report.sessions[0].failure, 'recorder-finish');
  assert.equal(report.sessions[0].recordingRelativePath, null);
});
test('upstream reset is retained and both sockets are closed', async (t) => {
  const f = await fixture(t, { received: (socket) => socket.resetAndDestroy() });
  await publish(f.port, Buffer.from('reset'));
  const report = await f.recorder.finish();
  assert.equal(report.sessions.length, 1);
  assert.equal(report.sessions[0].failure, 'upstream-socket');
  assert.equal(report.finishTimedOut, false);
  assert.equal(f.started[0].stops, 1);
});
test('invalid port is rejected before a child or output is created', async (t) => {
  const artifact = await mkdtemp(join(tmpdir(), 'recorder-invalid-'));
  t.after(() => rm(artifact, { recursive: true, force: true }));
  for (const port of [-1, 65536, 1.5, null])
    await assert.rejects(() => startReconnectingRTMPRecorder({ artifact, ffmpeg: 'ffmpeg', port }));
});
