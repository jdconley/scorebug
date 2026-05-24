import type { GameSession, GameStatus, Score, Team } from '@scorebug/protocol';

export type StoredSession = GameSession & {
  /** SRT passphrase the iPhone uses to publish. Discarded after end_game. */
  publishSecret: string;
  /** SRT passphrase the home daemon uses to pull. Discarded after end_game. */
  readSecret: string;
  /** YouTube RTMPS stream key. Never logged. Discarded after end_game. */
  youtubeStreamKey: string;
  /** Latest score handed out via /games/:id/score. Defaults to 0-0 in set 1. */
  score: Score;
};

const initialScore: Score = {
  home: 0,
  away: 0,
  set: 1,
  homeSets: 0,
  awaySets: 0,
};

export class GameStore {
  private readonly sessions = new Map<string, StoredSession>();

  /** Returns the currently-active session if one exists (starting OR live). */
  active(): StoredSession | undefined {
    for (const s of this.sessions.values()) {
      if (s.status === 'starting' || s.status === 'live') return s;
    }
    return undefined;
  }

  get(id: string): StoredSession | undefined {
    return this.sessions.get(id);
  }

  start(args: {
    id: string;
    homeTeam: Team;
    awayTeam: Team;
    publishSecret: string;
    readSecret: string;
    publishStreamId: string;
    youtubeStreamKey: string;
  }): StoredSession {
    const session: StoredSession = {
      id: args.id,
      homeTeam: args.homeTeam,
      awayTeam: args.awayTeam,
      publishStreamId: args.publishStreamId,
      publishSecret: args.publishSecret,
      readSecret: args.readSecret,
      youtubeStreamKey: args.youtubeStreamKey,
      status: 'starting',
      createdAt: new Date().toISOString(),
      score: { ...initialScore },
    };
    this.sessions.set(args.id, session);
    return session;
  }

  setStatus(id: string, status: GameStatus): StoredSession | undefined {
    const s = this.sessions.get(id);
    if (!s) return undefined;
    s.status = status;
    return s;
  }

  setScore(id: string, score: Score): StoredSession | undefined {
    const s = this.sessions.get(id);
    if (!s) return undefined;
    s.score = score;
    return s;
  }

  /**
   * Mark ended and forget the secrets so they don't sit in memory longer than needed.
   * Session itself is kept so a late report from home can still find a name for the id.
   */
  end(id: string): StoredSession | undefined {
    const s = this.sessions.get(id);
    if (!s) return undefined;
    s.status = 'ended';
    s.publishSecret = '';
    s.readSecret = '';
    s.youtubeStreamKey = '';
    return s;
  }

  /** Drop ended sessions older than `maxAgeMs`. Called by a periodic timer in production. */
  pruneEndedOlderThan(maxAgeMs: number, now: number = Date.now()): number {
    let pruned = 0;
    for (const [id, s] of this.sessions) {
      if (s.status !== 'ended') continue;
      if (now - Date.parse(s.createdAt) > maxAgeMs) {
        this.sessions.delete(id);
        pruned++;
      }
    }
    return pruned;
  }
}
