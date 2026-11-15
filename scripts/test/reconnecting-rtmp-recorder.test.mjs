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
  assert.ok(report.sessions[0].lifecycle, 'recorder rejection is retained');
  assert.deepEqual(
    report.sessions[0].lifecycle.events
      .filter((event) => event.target === 'recorder')
      .map((event) => [event.event, event.code]),
    [
      ['finish-request', undefined],
      ['finish-rejected', 'unknown'],
      ['stop-request', undefined],
      ['stop-resolved', undefined],
    ],
  );
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
  assert.ok(report.sessions[0].lifecycle, 'upstream error is retained');
  const error = report.sessions[0].lifecycle.events.find(
    (event) => event.target === 'upstream' && event.event === 'error',
  );
  assert.equal(error.code, 'ECONNRESET');
  assert.equal(error.stage, 'forwarding');
  assert.equal(report.finishTimedOut, false);
  assert.equal(f.started[0].stops, 1);
});
test('invalid port is rejected before a child or output is created', async (t) => {
  const artifact = await mkdtemp(join(tmpdir(), 'recorder-invalid-'));
  t.after(() => rm(artifact, { recursive: true, force: true }));
  for (const port of [-1, 65536, 1.5, null])
    await assert.rejects(() => startReconnectingRTMPRecorder({ artifact, ffmpeg: 'ffmpeg', port }));
});

// Capture the real proxy-side socket for deterministic startup event injection.
// Actual half-close/reset tests below use TCP events, not synthetic emissions.
function observeClient(t, observe) {
  const createServer = net.createServer;
  t.mock.method(net, 'createServer', function (options, accept) {
    if (options?.pauseOnConnect)
      return createServer.call(this, options, (client) => {
        accept(client);
        observe(client);
      });
    return createServer.apply(this, arguments);
  });
}

test('clean half-close retains ordered socket and recorder lifecycle evidence', async (t) => {
  const f = await fixture(t);
  await publish(f.port, Buffer.from('half-close'));
  const report = await f.recorder.finish();
  const session = report.sessions[0];
  assert.equal(session.failure, null);
  assert.ok(session.lifecycle, 'session retains lifecycle diagnostics');
  const { events, maximumEvents, overflowed } = session.lifecycle;
  assert.equal(maximumEvents, 32);
  assert.equal(overflowed, false);
  assert(
    events.every(
      (event, index) =>
        Number.isFinite(event.at) &&
        event.at >= session.acceptedAt &&
        event.at <= session.closedAt &&
        (index === 0 || event.at >= events[index - 1].at),
    ),
  );
  for (const target of ['client', 'upstream']) {
    const socketEvents = events.filter((event) => event.target === target);
    assert.deepEqual(socketEvents.map((event) => event.event).sort(), ['close', 'end', 'finish']);
    assert.equal(socketEvents.at(-1).event, 'close');
    assert.equal(socketEvents.at(-1).hadError, false);
    assert(socketEvents.every((event) => event.stage === 'forwarding'));
  }
  assert.deepEqual(
    events
      .filter((event) => event.target === 'recorder')
      .map(({ stage, event }) => ({ stage, event })),
    [
      { stage: 'recorder-finish', event: 'finish-request' },
      { stage: 'recorder-finish', event: 'finish-resolved' },
    ],
  );
});

test('client reset retains networking errno before stop outcome without changing failure', async (t) => {
  const received = deferred();
  const f = await fixture(t, { received: () => received.resolve() });
  const socket = await connect(f.port);
  socket.write('reset');
  await received.promise;
  const closed = closedSocket(socket);
  socket.resetAndDestroy();
  await closed;
  const report = await f.recorder.finish();
  const session = report.sessions[0];
  assert.equal(session.failure, 'client-socket');
  assert.equal(report.finishTimedOut, false);
  assert.ok(session.lifecycle, 'client reset has lifecycle diagnostics');
  const events = session.lifecycle.events;
  const error = events.find((event) => event.target === 'client' && event.event === 'error');
  assert.equal(error.code, 'ECONNRESET');
  assert.equal(error.stage, 'forwarding');
  assert.equal(
    events.find((event) => event.target === 'client' && event.event === 'close').hadError,
    true,
  );
  assert.deepEqual(
    events.filter((event) => event.target === 'recorder').map((event) => event.event),
    ['stop-request', 'stop-resolved'],
  );
  assert.equal(f.started[0].finishes, 0);
});

test('startup reset is observed before a late recorder exists', async (t) => {
  const accepted = deferred(),
    entered = deferred(),
    gate = deferred();
  observeClient(t, (client) => accepted.resolve(client));
  const f = await fixture(t, {
    beforeStart: async () => {
      entered.resolve();
      await gate.promise;
    },
  });
  const socket = await connect(f.port);
  const client = await accepted.promise;
  await entered.promise;
  const clientClosed = closedSocket(client),
    publisherClosed = closedSocket(socket);
  // Startup keeps the proxy paused; resume only in the test to deliver the TCP reset.
  client.resume();
  socket.resetAndDestroy();
  await Promise.all([clientClosed, publisherClosed]);
  gate.resolve();
  const report = await f.recorder.finish();
  const session = report.sessions[0];
  assert.equal(session.failure, 'interrupted');
  assert.equal(session.connectedAt, null);
  assert.equal(f.started[0].stops, 1);
  assert.ok(session.lifecycle, 'startup socket events are retained');
  assert.deepEqual(
    session.lifecycle.events
      .filter((event) => event.target === 'client')
      .map(({ stage, event, code, hadError }) => ({ stage, event, code, hadError })),
    [
      { stage: 'recorder-start', event: 'error', code: 'ECONNRESET', hadError: undefined },
      { stage: 'recorder-start', event: 'close', code: undefined, hadError: true },
    ],
  );
});

test('lifecycle error diagnostics redact values and cap event storage explicitly', async (t) => {
  const accepted = deferred(),
    entered = deferred(),
    gate = deferred();
  observeClient(t, (client) => accepted.resolve(client));
  const f = await fixture(t, {
    beforeStart: async () => {
      entered.resolve();
      await gate.promise;
    },
  });
  const socket = await connect(f.port);
  const client = await accepted.promise;
  await entered.promise;
  for (const code of ['EPIPE', 'ECONNRESET', 'rtmp://private/key', null, { secret: 'payload' }])
    client.emit('error', Object.assign(new Error('secret endpoint payload'), { code }));
  for (let i = 0; i < 100; i++) client.emit('error', new Error('private flood'));
  const clientClosed = closedSocket(client),
    publisherClosed = closedSocket(socket);
  socket.resume();
  client.destroy();
  await Promise.all([clientClosed, publisherClosed]);
  gate.resolve();
  const report = await f.recorder.finish();
  const session = report.sessions[0];
  assert.equal(session.failure, 'interrupted');
  assert.ok(session.lifecycle, 'bounded redacted diagnostics are retained');
  assert.equal(session.lifecycle.events.length, 32);
  assert.equal(session.lifecycle.maximumEvents, 32);
  assert.equal(session.lifecycle.overflowed, true);
  assert.deepEqual(
    session.lifecycle.events.slice(0, 5).map((event) => event.code),
    ['EPIPE', 'ECONNRESET', 'unknown', 'unknown', 'unknown'],
  );
  assert.doesNotMatch(JSON.stringify(report), /secret|private|payload|rtmp:\/\//);
});
