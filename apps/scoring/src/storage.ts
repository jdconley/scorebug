import type { ControlPlaneConfig } from './api.js';

const KEY_CONFIG = 'scorebug.config';
const KEY_TEAMS = 'scorebug.teams.lastUsed';
const KEY_ACTIVE = 'scorebug.activeGameId';

export function loadConfig(): ControlPlaneConfig | undefined {
  const raw = localStorage.getItem(KEY_CONFIG);
  if (!raw) return undefined;
  try {
    return JSON.parse(raw) as ControlPlaneConfig;
  } catch {
    return undefined;
  }
}
export function saveConfig(cfg: ControlPlaneConfig): void {
  localStorage.setItem(KEY_CONFIG, JSON.stringify(cfg));
}

export function loadLastTeams(): { home: string; homeShort: string; away: string; awayShort: string } | undefined {
  const raw = localStorage.getItem(KEY_TEAMS);
  if (!raw) return undefined;
  try {
    return JSON.parse(raw) as ReturnType<typeof loadLastTeams> extends infer T ? T : never;
  } catch {
    return undefined;
  }
}
export function saveLastTeams(t: { home: string; homeShort: string; away: string; awayShort: string }): void {
  localStorage.setItem(KEY_TEAMS, JSON.stringify(t));
}

export function loadActiveGame(): string | undefined {
  return localStorage.getItem(KEY_ACTIVE) ?? undefined;
}
export function saveActiveGame(id: string | undefined): void {
  if (id) localStorage.setItem(KEY_ACTIVE, id);
  else localStorage.removeItem(KEY_ACTIVE);
}
