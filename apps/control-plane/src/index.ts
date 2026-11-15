import { serve } from '@hono/node-server';
import { loadConfig } from './config.js';
import { createApp } from './app.js';
import { RelayLifecycleError } from './relay-lifecycle.js';

const config = loadConfig();
const { app, log, relayLifecycle } = createApp(config);

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

serve({ fetch: app.fetch, port: config.PORT, hostname: config.HOST }, (info) => {
  log.info('control_plane_listening', { port: info.port, host: config.HOST });
});
