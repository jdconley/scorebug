import type { Env } from './env.js';
import { realStream, type StreamApi } from './stream.js';
import { realYouTube, type YouTubeApi } from './youtube.js';

/** The match container a team object runs, behind an interface so tests need no Docker. */
export interface MatchContainer {
  readonly running: boolean;
  /** Registers the api.internal intercept and starts the worker with `env`. */
  start(env: Record<string, string>): Promise<void>;
  destroy(): Promise<void>;
  /** Without a renewal the platform stops the container after this long. */
  renew(timeoutMs: number): Promise<void>;
}

export type MediaAdapters = {
  youtube: YouTubeApi;
  stream: StreamApi;
  /** Null when the runtime has no container (Worker tests); then Go Live cannot start one. */
  container?: (ctx: DurableObjectState, teamId: () => string | null) => MatchContainer | null;
};

let override: ((env: Env) => MediaAdapters) | undefined;

/** Tests only: replace every adapter (Worker and team objects run in one isolate there). */
export function setMediaAdaptersForTests(factory: ((env: Env) => MediaAdapters) | undefined) {
  override = factory;
}

export function mediaAdapters(env: Env): MediaAdapters {
  return override ? override(env) : { youtube: realYouTube(env), stream: realStream(env) };
}
