import { createWorkerApp } from './app.js';
import type { Env } from './env.js';
import { realGoogle } from './google.js';

export { TeamObject } from './team-object.js';

export default {
  fetch(request, env, ctx) {
    return createWorkerApp({ env, google: realGoogle(env) }).fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
