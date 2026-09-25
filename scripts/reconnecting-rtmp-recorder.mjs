import net from 'node:net';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, relative, isAbsolute } from 'node:path';
import { startDirectRTMPRecorder } from './direct-rtmp-recorder.mjs';

const failure = (reason) => new Error(`Reconnecting RTMP recorder ${reason}`);
const deferred = () => {
  let resolve;
  const promise = new Promise((r) => (resolve = r));
  return { promise, resolve };
};
async function privatePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const port = server.address().port;
  await new Promise((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve())),
  );
  return port;
}
async function within(promise, milliseconds) {
  let timer;
  try {
    return await Promise.race([
      promise.then(() => true),
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(false), milliseconds);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

/** Persistent loopback endpoint for fault diagnostics. Each connection owns a
 * distinct single-session recorder; no concatenation or media qualification. */
export async function startReconnectingRTMPRecorder({ artifact, ffmpeg, port }, dependencies = {}) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw failure('has invalid port');
  const {
    startRecorder = startDirectRTMPRecorder,
    allocatePort = privatePort,
    now = () => performance.now(),
    finishMs = 5000,
  } = dependencies;
  if (!Number.isFinite(finishMs) || finishMs <= 0 || finishMs > 5000)
    throw failure('has invalid finish deadline');
  const root = join(artifact, 'reconnecting-recorder');
  await mkdir(root); // Exclusive ownership; never overwrite prior session evidence.
  const sessions = [],
    tasks = [],
    active = new Set();
  let closing = false,
    cancelled = false,
    finishTimedOut = false,
    rejectedConnections = 0;
  let listenerFailure = false,
    joining,
    stopping;
  const server = net.createServer({ pauseOnConnect: true, allowHalfOpen: true }, accept);
  const listenerClosed = deferred();
  server.once('close', () => listenerClosed.resolve());
  function closeListener() {
    if (!closing) {
      closing = true;
      server.close();
    }
  }
  function interrupt() {
    cancelled = true;
    closeListener();
    for (const session of active) {
      session.entry.interrupted = true;
      session.client.destroy();
      session.upstream?.destroy();
      session.stopRecorder?.();
    }
  }
  function accept(client) {
    client.on('error', () => {});
    if (closing || sessions.length >= 8 || active.size >= 2) {
      rejectedConnections++;
      client.destroy();
      return;
    }
    const sequence = sessions.length + 1;
    const entry = {
      sequence,
      acceptedAt: now(),
      connectedAt: null,
      closedAt: null,
      receivedBytes: 0,
      returnedBytes: 0,
      interrupted: false,
      failure: null,
      directoryRelativePath: `reconnecting-recorder/session-${sequence}`,
      recordingRelativePath: null,
    };
    sessions.push(entry);
    const session = { entry, client };
    active.add(session);
    const clientClosed = deferred();
    client.once('close', () => clientClosed.resolve());
    const task = (async () => {
      let recorder,
        upstreamClosed,
        stage = 'recorder-start',
        finished = false;
      const fail = (reason) => {
        entry.failure ??= reason;
      };
      try {
        const directory = join(artifact, entry.directoryRelativePath);
        await mkdir(directory);
        const privateListenerPort = await allocatePort();
        if (cancelled || client.destroyed) {
          entry.interrupted = true;
          return;
        }
        recorder = await startRecorder({
          artifact: directory,
          ffmpeg,
          port: privateListenerPort,
          packetTiming: true,
        });
        let stopped;
        session.stopRecorder = () => {
          if (!stopped) {
            stopped = Promise.resolve().then(() => recorder.stop());
            stopped.catch(() => {});
          }
          return stopped;
        };
        if (cancelled || client.destroyed) {
          entry.interrupted = true;
          return;
        }
        stage = 'upstream-connect';
        const upstream = net.connect({
          host: '127.0.0.1',
          port: privateListenerPort,
          allowHalfOpen: true,
        });
        session.upstream = upstream;
        upstreamClosed = deferred();
        upstream.once('close', () => upstreamClosed.resolve());
        upstream.on('error', () => {
          fail('upstream-socket');
          client.destroy();
        });
        client.on('error', () => {
          fail('client-socket');
          upstream.destroy();
        });
        await new Promise((resolve, reject) => {
          upstream.once('connect', resolve);
          upstream.once('error', reject);
          upstream.once('close', () => reject(failure('upstream closed before connection')));
        });
        if (cancelled || client.destroyed) {
          entry.interrupted = true;
          return;
        }
        entry.connectedAt = now();
        stage = 'forwarding';
        client.on('data', (bytes) => {
          entry.receivedBytes += bytes.length;
        });
        upstream.on('data', (bytes) => {
          entry.returnedBytes += bytes.length;
        });
        // Node pipe pauses its source when the destination write buffer fills.
        client.pipe(upstream);
        upstream.pipe(client);
        await Promise.all([clientClosed.promise, upstreamClosed.promise]);
        if (cancelled || entry.failure) {
          entry.interrupted ||= cancelled;
          return;
        }
        stage = 'recorder-finish';
        const path = await recorder.finish();
        const local = relative(directory, path);
        if (!local || isAbsolute(local) || local === '..' || local.startsWith('../'))
          throw failure('foreign recording');
        entry.recordingRelativePath = relative(artifact, path);
        if (entry.receivedBytes === 0) fail('empty-session');
        finished = true;
      } catch {
        fail(stage);
      } finally {
        client.destroy();
        session.upstream?.destroy();
        await clientClosed.promise;
        if (upstreamClosed) await upstreamClosed.promise;
        if (recorder && !finished) {
          try {
            await session.stopRecorder();
          } catch {
            fail('recorder-stop');
          }
        }
        if (entry.interrupted) fail('interrupted');
        entry.closedAt = now();
        active.delete(session);
      }
    })();
    tasks.push(task);
    // Every task is joined at finish/stop; avoid an unhandled rejection before then.
    task.catch(() => {});
  }
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, '127.0.0.1', resolve);
    });
  } catch {
    server.close();
    throw failure('could not listen');
  }
  server.on('error', () => {
    listenerFailure = true;
    interrupt();
  });
  const assignedPort = server.address().port;
  function joinAll() {
    if (!joining)
      joining = (async () => {
        closeListener();
        const all = Promise.all(tasks);
        if (!cancelled && !(await within(all, finishMs))) {
          finishTimedOut = true;
          interrupt();
        }
        await all;
        await listenerClosed.promise;
        const report = {
          formatVersion: 1,
          diagnosticOnly: true,
          mediaQualified: false,
          recoveryQualified: false,
          closed: true,
          terminal: cancelled ? 'stopped' : 'finished',
          finishTimedOut,
          listenerFailure,
          maximumSessions: 8,
          maximumConcurrentSessions: 2,
          rejectedConnections,
          sessions,
        };
        await writeFile(join(root, 'manifest.json'), JSON.stringify(report, null, 2) + '\n', {
          flag: 'wx',
        });
        return report;
      })();
    return joining;
  }
  function finish() {
    return joinAll();
  }
  function stop() {
    if (!stopping) {
      interrupt();
      stopping = joinAll();
    }
    return stopping;
  }
  return { url: `rtmp://127.0.0.1:${assignedPort}/live/fixture`, finish, stop };
}
