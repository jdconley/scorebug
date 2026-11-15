import { Hono } from 'hono';
import { zValidator } from '@hono/zod-validator';
import { z } from 'zod';
import { ownerAuth } from '../auth.js';
import type { Config } from '../config.js';
import { MatchStore, MatchStoreError } from '../matches-store.js';

/** Pairing errors intentionally never attach the active match's private snapshot. */
export function watchPairingRoutes(config: Config, store: MatchStore) {
  const app = new Hono();
  app.post(
    '/',
    ownerAuth(config.PHONE_TOKEN, store.account),
    zValidator(
      'json',
      z
        .object({
          pairingId: z.uuid(),
          watchDeviceId: z.uuid(),
        })
        .strict(),
    ),
    (c) => c.json(store.issueWatchPairing(c.req.param('id')!, c.req.valid('json')), 201),
  );
  app.post(
    '/:pairingId/redeem',
    async (c, next) => {
      const token = c.req.header('authorization')?.match(/^Bearer (.+)$/i)?.[1] ?? '';
      if (!store.authenticateWatchPairing(c.req.param('id')!, c.req.param('pairingId')!, token))
        return c.json({ error: 'unauthorized' }, 401);
      const key = c.req.header('X-Scorebug-Pairing-Recovery') ?? '';
      if (
        !/^[A-Za-z0-9_-]{43}$/.test(key) ||
        Buffer.from(key, 'base64url').toString('base64url') !== key
      )
        return c.json({ error: 'invalid_recovery_key' }, 400);
      await next();
    },
    zValidator('json', z.object({ redemptionId: z.uuid(), deviceId: z.uuid() }).strict()),
    (c) => {
      const token = c.req.header('authorization')!.match(/^Bearer (.+)$/i)![1]!;
      return c.json(
        store.redeemWatchPairing(
          c.req.param('id')!,
          c.req.param('pairingId')!,
          token,
          c.req.header('X-Scorebug-Pairing-Recovery')!,
          c.req.valid('json'),
        ),
      );
    },
  );
  app.onError((error, c) => {
    if (error instanceof MatchStoreError)
      return c.json({ error: error.code }, error.code === 'unauthorized' ? 401 : 409);
    throw error;
  });
  return app;
}
