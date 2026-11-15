import { z } from 'zod';
import { DEFAULT_SCOREBUG_STYLE, SCOREBUG_STYLES, type ScorebugOverlay } from '@scorebug/protocol';

const integer = z.number().int().min(0).max(999);
const side = z.enum(['home', 'away']);
const team = z.object({
  name: z.string().min(1).max(256),
  shortName: z.string().min(1).max(64),
  color: z.string().max(32),
});
export const scorebugOverlaySchema = z.object({
  style: z.enum(SCOREBUG_STYLES),
  label: z.string().max(256).nullable(),
  bestOf: z.union([z.literal(3), z.literal(5)]),
  teams: z.object({ home: team, away: team }),
  score: z.object({
    home: integer,
    away: integer,
    set: integer.min(1),
    homeSets: integer,
    awaySets: integer,
  }),
  completedSets: z
    .array(z.object({ set: integer.min(1), home: integer, away: integer, winner: side }))
    .max(5),
  serving: side.nullable(),
});

/** Match snapshot fields the worker receives; absent style means a pre-style control plane. */
export type ScorebugMatch = {
  teams: ScorebugOverlay['teams'];
  score: ScorebugOverlay['score'];
  rules?: { bestOf: 3 | 5 } | undefined;
  completedSets?: ScorebugOverlay['completedSets'] | undefined;
  scorebugStyle?: ScorebugOverlay['style'] | undefined;
};

export function scorebugOverlay(match: ScorebugMatch): ScorebugOverlay {
  return {
    style: match.scorebugStyle ?? DEFAULT_SCOREBUG_STYLE,
    // The match model has no title/division or serve state yet: leave them blank.
    label: null,
    bestOf: match.rules?.bestOf ?? 3,
    teams: match.teams,
    score: match.score,
    completedSets: (match.completedSets ?? []).map(({ set, home, away, winner }) => ({
      set,
      home,
      away,
      winner,
    })),
    serving: null,
  };
}

/** Canonical file contents; the pipeline re-renders only when this text changes. */
export function serializeScorebugOverlay(overlay: ScorebugOverlay): string {
  return `${JSON.stringify(overlay)}\n`;
}

/** Null for anything that is not a complete overlay (e.g. a legacy drawtext line). */
export function parseScorebugOverlay(text: string): ScorebugOverlay | null {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return null;
  }
  const parsed = scorebugOverlaySchema.safeParse(value);
  return parsed.success ? parsed.data : null;
}
