import { serve } from '@hono/node-server';
import { createNodeWebSocket } from '@hono/node-ws';
import { loadConfig } from './config.js';
import { createApp } from './app.js';
import { tokensMatch } from './auth.js';
import { RelayLifecycleError } from './relay-lifecycle.js';

const config = loadConfig();
const { app, bus, log, relayLifecycle } = createApp(config);

// One in-flight pass at a time. Startup inventory also recovers paths left by a crash.
if (relayLifecycle) {
  let lastError: string | undefined;
  const reconcile = async () => {
    try {
      await relayLifecycle.reconcile();
      if (lastError) log.info('relay_reconciliation_recovered');
      lastError = undefined;
    } catch (error) {
      const code = error instanceof RelayLifecycleError ? error.code : 'relay_unavailable';
      if (code !== 'broadcast_changed' && code !== lastError) {
        log.warn('relay_reconciliation_failed', { code });
        lastError = code;
      }
    } finally {
      setTimeout(() => void reconcile(), 1000).unref();
    }
  };
  void reconcile();
}

const { upgradeWebSocket, injectWebSocket } = createNodeWebSocket({ app });

app.get(
  '/home/ws',
  upgradeWebSocket((c) => {
    const token = c.req.query('token') ?? '';
    if (!tokensMatch(token, config.HOME_TOKEN)) {
      return {
        onOpen: (_evt, ws) => ws.close(4401, 'unauthorized'),
      };
    }
    let attached: { send(d: string): void; close(c?: number, r?: string): void } | undefined;
    return {
      onOpen: (_evt, ws) => {
        attached = {
          send: (d) => ws.send(d),
          close: (code, reason) => ws.close(code, reason),
        };
        bus.attach(attached);
      },
      onMessage: (evt) => {
        const data = typeof evt.data === 'string' ? evt.data : evt.data.toString();
        bus.ingestReport(data);
      },
      onClose: () => {
        if (attached) bus.detach(attached);
      },
    };
  }),
);

const server = serve({ fetch: app.fetch, port: config.PORT, hostname: config.HOST }, (info) => {
  log.info('control_plane_listening', { port: info.port, host: config.HOST });
});

injectWebSocket(server);
