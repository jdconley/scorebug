// Simulator QA only (ios/README.md): the real Worker app with a stand-in Google that signs in as
// whoever POST /dev/identity names, and the Worker tests' in-memory YouTube, Stream and match
// container. Never deployed: it has its own wrangler config.
import { FakeStream } from '../../../apps/control-plane/test-worker/fake-media.js';
import { createWorkerApp } from '../../../apps/control-plane/src/worker/app.js';
import type { Env } from '../../../apps/control-plane/src/worker/env.js';
import type { GoogleOAuth } from '../../../apps/control-plane/src/worker/google.js';
export { TeamObject } from '../../../apps/control-plane/src/worker/team-object.js';
export { WorkerApi } from '../../../apps/control-plane/src/worker/worker-api.js';

// DEV_PUBLISH_URL (a wrangler var) points the app's SRT publish at a listener on this Mac, like
// `srt-live-transmit "srt://:9000?mode=listener" file://con > /dev/null`, so Go Live really goes
// live for screenshots. Empty: the fake Stream's unreachable URL.
let publishUrl = '';
const createInput = FakeStream.prototype.createInput;
FakeStream.prototype.createInput = async function (name: string) {
  const input = await createInput.call(this, name);
  return publishUrl ? { ...input, publishUrl } : input;
};

let email = 'jd@example.com';
let name = 'JD Conley';
const youtubeScope = 'https://www.googleapis.com/auth/youtube';

const google: GoogleOAuth = {
  authorizeUrl(p) {
    // Straight back to the Worker's callback, as if the person approved everything.
    const url = new URL(p.redirectUri);
    url.searchParams.set('state', p.state);
    url.searchParams.set('code', 'dev-' + Date.now());
    return url.toString();
  },
  async exchange() {
    return {
      identity: { sub: 'sub-' + email, email, emailVerified: true, name, picture: null },
      refreshToken: null,
      scopes: ['openid', 'email', 'profile'],
    };
  },
  async exchangeForRefreshToken() {
    // FakeYouTube accepts refresh tokens that start with "refresh-".
    return { refreshToken: 'refresh-' + email, scopes: ['openid', 'email', 'profile', youtubeScope] };
  },
  async revoke() {},
};

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    publishUrl = (env as Env & { DEV_PUBLISH_URL?: string }).DEV_PUBLISH_URL ?? '';
    const url = new URL(request.url);
    if (url.pathname === '/dev/identity' && request.method === 'POST') {
      const body = (await request.json()) as { email: string; name?: string };
      email = body.email;
      name = body.name ?? body.email.split('@')[0];
      return new Response('ok');
    }
    return createWorkerApp({ env, google }).fetch(request, env, ctx);
  },
};
