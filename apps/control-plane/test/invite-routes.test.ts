import { Hono } from 'hono';
import { expect, it } from 'vitest';
import { MatchStore } from '../src/matches-store.js';
import { inviteRoutes } from '../src/routes/account.js';
import type { MatchAccess } from '../src/routes/matches.js';
import { openNodeSqlite } from '../src/sql-node.js';

const teams = {
  home: { name: 'One', shortName: 'ONE', color: '#112233' },
  away: { name: 'Two', shortName: 'TWO', color: '#445566' },
};
const rules = {
  bestOf: 3 as const,
  pointsToWin: 25,
  decidingPointsToWin: 15,
  winBy: 2,
  pointCap: null,
};

it('revokes a join code whose routing hook fails, so no unroutable code lingers', async () => {
  const store = new MatchStore(openNodeSqlite(':memory:'), 'qa-credential-key-not-production');
  store.create({ id: 'game-1', deviceId: 'phone-a', teams, rules });
  const access: MatchAccess = {
    bootstrap: async (_c, next) => next(),
    issuer: () => 'member:someone',
    joinLink: (code) => `https://scorebug.test/join/${code}`,
    onInvite: {
      issued: async () => {
        throw new Error('code taken elsewhere');
      },
      revoked: async () => {},
    },
  };
  const app = new Hono();
  app.route('/v1/matches/:id/invites', inviteRoutes(store, access));
  app.onError((_error, c) => c.json({ error: 'internal' }, 500));
  const response = await app.request('/v1/matches/game-1/invites', { method: 'POST' });
  expect(response.status).toBe(500);
  const invites = store.listInvites('game-1');
  expect(invites).toHaveLength(1);
  expect(invites[0]?.revokedAt).not.toBeNull();
  store.close();
});
