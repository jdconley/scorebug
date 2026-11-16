import { createWorkerApp } from './app.js';
import type { Env } from './env.js';
import { realGoogle } from './google.js';
import { mediaAdapters } from './media-adapters.js';
import { sweep } from './sweep.js';

export { TeamObject } from './team-object.js';
export { WorkerApi } from './worker-api.js';

export default {
  fetch(request, env, ctx) {
    return createWorkerApp({ env, google: realGoogle(env) }).fetch(request, env, ctx);
  },
  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(
      sweep(env, mediaAdapters(env)).then((result) => console.log('sweep_done', result)),
    );
  },
} satisfies ExportedHandler<Env>;
