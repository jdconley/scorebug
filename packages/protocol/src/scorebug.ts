import type { Score, Teams } from './messages.js';
import type { MatchRules, SetResult, Side } from './matches.js';

/** Broadcast graphic styles; `bar` is the default. */
export const SCOREBUG_STYLES = ['bar', 'lowerThird', 'setCard'] as const;
export type ScorebugStyle = (typeof SCOREBUG_STYLES)[number];
export const DEFAULT_SCOREBUG_STYLE: ScorebugStyle = 'bar';

/**
 * Everything the worker needs to draw one scorebug frame. Derived from the
 * worker's match snapshot; the worker never invents match state.
 */
export type ScorebugOverlay = {
  style: ScorebugStyle;
  /** Optional header label (match title or division); null leaves it blank. */
  label: string | null;
  bestOf: MatchRules['bestOf'];
  teams: Teams;
  score: Score;
  completedSets: Pick<SetResult, 'set' | 'home' | 'away' | 'winner'>[];
  /** Serving side when the match model knows it; null omits the serve marker. */
  serving: Side | null;
};
