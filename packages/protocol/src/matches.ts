import type { Score, Teams } from './messages.js';
import type { ScorebugStyle } from './scorebug.js';
import type { MatchOutput } from './setup.js';

export type Side = 'home' | 'away';
export type MatchRules = {
  bestOf: 3 | 5;
  pointsToWin: number;
  decidingPointsToWin: number;
  winBy: number;
  pointCap: number | null;
};
export type SetResult = {
  set: number;
  home: number;
  away: number;
  winner: Side;
  overrideReason: string | null;
};
export type ScoringFrame = { score: Score; completedSets: SetResult[] };
export type ScoringState = ScoringFrame & {
  status: 'active' | 'ended';
  history: ScoringFrame[];
  endReason: string | null;
};
export type ScoringOperation =
  | { type: 'award_point'; side: Side }
  | { type: 'undo' }
  | { type: 'end_set'; winner?: Side | undefined; overrideReason?: string | undefined }
  | { type: 'end_match'; reason: string };
export type MatchOperation =
  | ScoringOperation
  | { type: 'take_over' }
  /** Presentation only: changes the broadcast graphic, never score or undo history. */
  | { type: 'set_scorebug_style'; style: ScorebugStyle };
export type MatchCommand = {
  commandId: string;
  gameId: string;
  deviceId: string;
  expectedRevision: number;
  scorerEpoch: number;
  issuedAt: string;
  operation: MatchOperation;
};
export type MatchSnapshot = {
  id: string;
  createdAt: string;
  revision: number;
  teams: Teams;
  rules: MatchRules;
  score: Score;
  completedSets: SetResult[];
  status: 'active' | 'ended';
  endReason: string | null;
  canUndo: boolean;
  scorer: { deviceId: string; epoch: number };
  broadcast: { desired: 'stopped' | 'running'; generation: number };
  scorebugStyle: ScorebugStyle;
  /**
   * Set point reached under the match rules: prompt the scorer to confirm with
   * `end_set`. Further points remain allowed and recompute this.
   */
  pendingSetEnd: { winner: Side } | null;
  output: MatchOutput;
};
export type CommandOutcome = {
  commandId: string;
  accepted: boolean;
  error: string | null;
  snapshot: MatchSnapshot;
};
export type MatchCredential = {
  gameId: string;
  deviceId: string;
  role: 'score' | 'capture';
  token: string;
};
