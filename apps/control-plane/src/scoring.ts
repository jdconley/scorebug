import type {
  MatchRules,
  ScoringFrame,
  ScoringOperation,
  ScoringState,
  SetResult,
} from '@scorebug/protocol';

export const defaultRules: MatchRules = {
  bestOf: 3,
  pointsToWin: 25,
  decidingPointsToWin: 15,
  winBy: 2,
  pointCap: null,
};

export class ScoringError extends Error {
  constructor(public readonly code: string) {
    super(code);
    this.name = 'ScoringError';
  }
}

export function initialScoringState(): ScoringState {
  return {
    score: { home: 0, away: 0, set: 1, homeSets: 0, awaySets: 0 },
    completedSets: [],
    history: [],
    status: 'active',
    endReason: null,
  };
}

export function validateRules(rules: MatchRules): void {
  const inRange = (value: number, min: number, max: number) =>
    Number.isInteger(value) && value >= min && value <= max;
  if (
    (rules.bestOf !== 3 && rules.bestOf !== 5) ||
    !inRange(rules.pointsToWin, 1, 99) ||
    !inRange(rules.decidingPointsToWin, 1, 99) ||
    !inRange(rules.winBy, 1, 10) ||
    (rules.pointCap !== null &&
      !inRange(rules.pointCap, Math.max(rules.pointsToWin, rules.decidingPointsToWin), 199))
  )
    throw new ScoringError('invalid_rules');
}

function frameOf(state: ScoringFrame): ScoringFrame {
  return {
    score: { ...state.score },
    completedSets: state.completedSets.map((set) => ({ ...set })),
  };
}

export function applyScoringOperation(
  state: ScoringState,
  rules: MatchRules,
  operation: ScoringOperation,
): ScoringState {
  if (state.status === 'ended') throw new ScoringError('match_ended');
  validateRules(rules);

  if (operation.type === 'end_match') {
    const reason = operation.reason.trim();
    if (!reason) throw new ScoringError('invalid_end_reason');
    return { ...state, status: 'ended', endReason: reason };
  }

  if (operation.type === 'undo') {
    const previous = state.history.at(-1);
    if (!previous) throw new ScoringError('nothing_to_undo');
    return { ...state, ...frameOf(previous), history: state.history.slice(0, -1) };
  }

  const setsToWin = Math.ceil(rules.bestOf / 2);
  if (state.score.homeSets >= setsToWin || state.score.awaySets >= setsToWin) {
    throw new ScoringError('match_already_won');
  }

  if (operation.type === 'award_point') {
    return {
      ...state,
      score: { ...state.score, [operation.side]: state.score[operation.side] + 1 },
      history: [...state.history, frameOf(state)],
    };
  }

  const { home, away, set } = state.score;
  if (home === away) throw new ScoringError('tied_set');
  const hasOverride = operation.winner !== undefined || operation.overrideReason !== undefined;
  const overrideReason = operation.overrideReason?.trim() ?? null;
  if (hasOverride && (!operation.winner || !overrideReason))
    throw new ScoringError('invalid_override');

  const winner = operation.winner ?? (home > away ? 'home' : 'away');
  const target = set === rules.bestOf ? rules.decidingPointsToWin : rules.pointsToWin;
  const highest = Math.max(home, away);
  const reachedCap = rules.pointCap !== null && highest >= rules.pointCap;
  if (
    !hasOverride &&
    !(highest >= target && (Math.abs(home - away) >= rules.winBy || reachedCap))
  ) {
    throw new ScoringError('set_not_won');
  }

  const score = {
    ...state.score,
    homeSets: state.score.homeSets + (winner === 'home' ? 1 : 0),
    awaySets: state.score.awaySets + (winner === 'away' ? 1 : 0),
  };
  if (score.homeSets < setsToWin && score.awaySets < setsToWin) {
    score.home = 0;
    score.away = 0;
    score.set += 1;
  }
  const result: SetResult = { set, home, away, winner, overrideReason };
  return {
    ...state,
    score,
    completedSets: [...state.completedSets, result],
    history: [...state.history, frameOf(state)],
  };
}
