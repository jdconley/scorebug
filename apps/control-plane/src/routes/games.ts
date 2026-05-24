import { Hono } from 'hono';
import { zValidator } from '@hono/zod-validator';
import { z } from 'zod';
import type { HomeMessage, Score, Team } from '@scorebug/protocol';
import { bearer } from '../auth.js';
import type { Config } from '../config.js';
import type { Logger } from '../logger.js';
import { newGameId, newSecret, publishStreamId } from '../secrets.js';
import type { GameStore } from '../state.js';
import type { HomeBus } from '../home-bus.js';

const teamSchema = z.object({
  name: z.string().min(1).max(80),
  shortName: z.string().min(1).max(8),
  color: z.string().regex(/^#[0-9a-fA-F]{6}$/),
});

const startSchema = z.object({
  homeTeam: teamSchema,
  awayTeam: teamSchema,
  youtubeStreamKey: z.string().min(8).max(200),
});

const scoreSchema = z.object({
  home: z.number().int().nonnegative(),
  away: z.number().int().nonnegative(),
  set: z.number().int().positive(),
  homeSets: z.number().int().nonnegative(),
  awaySets: z.number().int().nonnegative(),
});

const calloutSchema = z.object({
  kind: z.enum(['kill', 'dig', 'block']),
  player: z.object({
    number: z.number().int().nonnegative().max(99),
    name: z.string().min(1).max(80),
  }),
});

export function gamesRoutes(deps: {
  config: Config;
  store: GameStore;
  bus: HomeBus;
  log: Logger;
}) {
  const { config, store, bus, log } = deps;
  const app = new Hono();

  app.use('*', bearer(config.PHONE_TOKEN, 'phone'));

  app.post('/start', zValidator('json', startSchema), (c) => {
    const existing = store.active();
    if (existing) {
      return c.json(
        {
          error: 'game_in_flight',
          existing: {
            id: existing.id,
            status: existing.status,
            createdAt: existing.createdAt,
          },
        },
        409,
      );
    }

    const body = c.req.valid('json');
    const id = newGameId();
    const publishSecret = newSecret();
    const readSecret = newSecret();
    const sid = publishStreamId(id, publishSecret);

    const session = store.start({
      id,
      homeTeam: body.homeTeam as Team,
      awayTeam: body.awayTeam as Team,
      publishSecret,
      readSecret,
      publishStreamId: sid,
      youtubeStreamKey: body.youtubeStreamKey,
    });

    if (bus.isConnected()) {
      const pullUrl = `srt://${config.INGEST_HOST}:${config.INGEST_PORT}?streamid=read:game_${id}&passphrase=${readSecret}&latency=1000000`;
      const msg: HomeMessage = {
        type: 'start_game',
        gameId: id,
        pullUrl,
        youtubeStreamKey: body.youtubeStreamKey,
        teams: { home: session.homeTeam, away: session.awayTeam },
      };
      try {
        bus.send(msg);
      } catch (err) {
        log.warn('home_send_failed_on_start', { gameId: id, err: String(err) });
      }
    } else {
      log.warn('home_not_connected_on_start', { gameId: id });
    }

    log.info('game_started', { gameId: id });

    return c.json(
      {
        id,
        status: session.status,
        createdAt: session.createdAt,
        publish: {
          host: config.INGEST_HOST,
          port: config.INGEST_PORT,
          streamId: sid,
          passphrase: publishSecret,
        },
      },
      201,
    );
  });

  app.post('/:id/end', (c) => {
    const id = c.req.param('id');
    const s = store.get(id);
    if (!s) return c.json({ error: 'not_found' }, 404);
    if (s.status === 'ended') return c.json({ id, status: s.status });

    if (bus.isConnected()) {
      try {
        bus.send({ type: 'end_game', gameId: id });
      } catch (err) {
        log.warn('home_send_failed_on_end', { gameId: id, err: String(err) });
      }
    }
    store.end(id);
    log.info('game_ended', { gameId: id });
    return c.json({ id, status: 'ended' });
  });

  app.post('/:id/score', zValidator('json', scoreSchema), (c) => {
    const id = c.req.param('id');
    const s = store.get(id);
    if (!s) return c.json({ error: 'not_found' }, 404);
    if (s.status === 'ended') return c.json({ error: 'game_ended' }, 409);

    const score: Score = c.req.valid('json');
    store.setScore(id, score);

    if (bus.isConnected()) {
      try {
        bus.send({ type: 'score_update', gameId: id, score });
      } catch (err) {
        log.warn('home_send_failed_on_score', { gameId: id, err: String(err) });
      }
    }
    return c.json({ id, score });
  });

  app.post('/:id/callout', zValidator('json', calloutSchema), (c) => {
    const id = c.req.param('id');
    const s = store.get(id);
    if (!s) return c.json({ error: 'not_found' }, 404);
    if (s.status === 'ended') return c.json({ error: 'game_ended' }, 409);

    const event = c.req.valid('json');
    if (bus.isConnected()) {
      try {
        bus.send({ type: 'callout', gameId: id, event });
      } catch (err) {
        log.warn('home_send_failed_on_callout', { gameId: id, err: String(err) });
      }
    }
    return c.json({ ok: true });
  });

  app.get('/:id', (c) => {
    const id = c.req.param('id');
    const s = store.get(id);
    if (!s) return c.json({ error: 'not_found' }, 404);
    return c.json({
      id: s.id,
      status: s.status,
      createdAt: s.createdAt,
      homeTeam: s.homeTeam,
      awayTeam: s.awayTeam,
      score: s.score,
    });
  });

  return app;
}
