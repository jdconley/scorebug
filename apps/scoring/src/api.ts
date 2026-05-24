import type { CalloutEvent, Score, Team } from '@scorebug/protocol';

export type ControlPlaneConfig = {
  baseUrl: string; // e.g. https://api.scorebug.live
  phoneToken: string;
};

export type StartGameRequest = {
  homeTeam: Team;
  awayTeam: Team;
  youtubeStreamKey: string;
};

export type StartGameResponse = {
  id: string;
  status: 'starting' | 'live' | 'ended';
  createdAt: string;
  publish: {
    host: string;
    port: number;
    streamId: string;
    passphrase: string;
  };
};

class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly body: unknown,
  ) {
    super(`api ${status}`);
  }
}

async function call<T>(
  cfg: ControlPlaneConfig,
  path: string,
  init: RequestInit & { json?: unknown } = {},
): Promise<T> {
  const { json, headers, ...rest } = init;
  const res = await fetch(`${cfg.baseUrl}${path}`, {
    ...rest,
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${cfg.phoneToken}`,
      ...(headers ?? {}),
    },
    body: json !== undefined ? JSON.stringify(json) : (init.body ?? null),
  });
  if (!res.ok) {
    let body: unknown = undefined;
    try {
      body = await res.json();
    } catch {
      /* ignore */
    }
    throw new ApiError(res.status, body);
  }
  return (await res.json()) as T;
}

export const api = {
  health: (cfg: ControlPlaneConfig) =>
    call<{ ok: boolean; home: boolean }>(cfg, '/healthz', { method: 'GET' }),

  startGame: (cfg: ControlPlaneConfig, req: StartGameRequest) =>
    call<StartGameResponse>(cfg, '/games/start', { method: 'POST', json: req }),

  endGame: (cfg: ControlPlaneConfig, id: string) =>
    call<{ id: string; status: string }>(cfg, `/games/${id}/end`, { method: 'POST' }),

  setScore: (cfg: ControlPlaneConfig, id: string, score: Score) =>
    call<{ id: string; score: Score }>(cfg, `/games/${id}/score`, { method: 'POST', json: score }),

  callout: (cfg: ControlPlaneConfig, id: string, event: CalloutEvent) =>
    call<{ ok: true }>(cfg, `/games/${id}/callout`, { method: 'POST', json: event }),
};

export { ApiError };
