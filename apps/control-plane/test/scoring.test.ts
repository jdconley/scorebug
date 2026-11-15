import { describe, expect, it } from 'vitest';
import type { MatchRules, ScoringOperation, ScoringState, Side } from '@scorebug/protocol';
import {
  applyScoringOperation,
  defaultRules,
  defaultShortName,
  initialScoringState,
  pendingSetEnd,
  ScoringError,
  validateRules,
} from '../src/scoring.js';

function points(
  state: ScoringState,
  side: Side,
  count: number,
  rules = defaultRules,
): ScoringState {
  for (let i = 0; i < count; i++)
    state = applyScoringOperation(state, rules, { type: 'award_point', side });
  return state;
}

function atScore(home: number, away: number, rules = defaultRules): ScoringState {
  return points(points(initialScoringState(), 'home', home, rules), 'away', away, rules);
}

function finishSet(state: ScoringState, side: Side, rules = defaultRules): ScoringState {
  const target = state.score.set === rules.bestOf ? rules.decidingPointsToWin : rules.pointsToWin;
  return applyScoringOperation(points(state, side, target, rules), rules, { type: 'end_set' });
}

function expectError(
  state: ScoringState,
  operation: ScoringOperation,
  code: string,
  rules = defaultRules,
): void {
  const before = structuredClone(state);
  expect(() => applyScoringOperation(state, rules, operation)).toThrow(ScoringError);
  expect(() => applyScoringOperation(state, rules, operation)).toThrow(
    expect.objectContaining({ code }),
  );
  expect(state).toEqual(before);
}

describe('volleyball scoring', () => {
  it('starts fresh with default best-of-three rules and awards only the chosen side', () => {
    expect(defaultRules).toEqual({
      bestOf: 3,
      pointsToWin: 25,
      decidingPointsToWin: 15,
      winBy: 2,
      pointCap: null,
    });
    const initial = initialScoringState();
    expect(initial).toEqual({
      score: { home: 0, away: 0, set: 1, homeSets: 0, awaySets: 0 },
      completedSets: [],
      history: [],
      status: 'active',
      endReason: null,
    });
    const next = applyScoringOperation(initial, defaultRules, {
      type: 'award_point',
      side: 'away',
    });
    expect(next.score).toEqual({ ...initial.score, away: 1 });
    expect(next.history).toEqual([{ score: initial.score, completedSets: [] }]);
    expect(initial.score.away).toBe(0);
    expect(initialScoringState()).toEqual(initial);
  });

  it('requires the normal target and a two-point lead', () => {
    expectError(atScore(24, 0), { type: 'end_set' }, 'set_not_won');
    expectError(atScore(25, 24), { type: 'end_set' }, 'set_not_won');
    expectError(atScore(29, 28), { type: 'end_set' }, 'set_not_won');
    const result = applyScoringOperation(atScore(30, 28), defaultRules, { type: 'end_set' });
    expect(result.score).toEqual({ home: 0, away: 0, set: 2, homeSets: 1, awaySets: 0 });
    expect(result.completedSets).toEqual([
      { set: 1, home: 30, away: 28, winner: 'home', overrideReason: null },
    ]);
  });

  it('applies configurable targets and lead requirements', () => {
    const rules: MatchRules = { ...defaultRules, pointsToWin: 11, winBy: 3 };
    expectError(atScore(11, 9, rules), { type: 'end_set' }, 'set_not_won', rules);
    const result = applyScoringOperation(atScore(8, 11, rules), rules, { type: 'end_set' });
    expect(result.score.awaySets).toBe(1);
    expect(result.completedSets[0]?.winner).toBe('away');
  });

  it('allows a one-point lead at an optional cap but never a tie', () => {
    const rules: MatchRules = { ...defaultRules, pointCap: 30 };
    expectError(atScore(29, 28, rules), { type: 'end_set' }, 'set_not_won', rules);
    const result = applyScoringOperation(atScore(30, 29, rules), rules, { type: 'end_set' });
    expect(result.completedSets[0]).toMatchObject({ home: 30, away: 29, winner: 'home' });
    expectError(atScore(30, 30, rules), { type: 'end_set' }, 'tied_set', rules);
  });

  it.each([3, 5] as const)('uses the deciding target only in set %i', (bestOf) => {
    const rules: MatchRules = { ...defaultRules, bestOf };
    let state = initialScoringState();
    for (let set = 1; set < bestOf; set++) {
      const side = set % 2 === 1 ? 'home' : 'away';
      const partial = points(state, side, 15, rules);
      expectError(partial, { type: 'end_set' }, 'set_not_won', rules);
      state = finishSet(state, side, rules);
    }
    expect(state.score.set).toBe(bestOf);
    state = finishSet(state, 'away', rules);
    expect(state.score).toMatchObject({
      home: 0,
      away: 15,
      set: bestOf,
      awaySets: Math.ceil(bestOf / 2),
    });
    expect(state.completedSets).toHaveLength(bestOf);
  });

  it('preserves the winning set score and blocks further scoring until undo', () => {
    let state = finishSet(initialScoringState(), 'home');
    state = finishSet(state, 'home');
    expect(state.score).toEqual({ home: 25, away: 0, set: 2, homeSets: 2, awaySets: 0 });
    expect(state.status).toBe('active');
    expectError(state, { type: 'award_point', side: 'away' }, 'match_already_won');
    expectError(state, { type: 'end_set' }, 'match_already_won');
    const restored = applyScoringOperation(state, defaultRules, { type: 'undo' });
    expect(restored.score).toEqual({ home: 25, away: 0, set: 2, homeSets: 1, awaySets: 0 });
    expect(restored.completedSets).toHaveLength(1);
    expect(
      applyScoringOperation(restored, defaultRules, { type: 'award_point', side: 'away' }).score
        .away,
    ).toBe(1);
  });

  it('records an explicit manual winner and a trimmed reason', () => {
    const state = applyScoringOperation(atScore(8, 5), defaultRules, {
      type: 'end_set',
      winner: 'away',
      overrideReason: '  Referee awarded set  ',
    });
    expect(state.completedSets).toEqual([
      { set: 1, home: 8, away: 5, winner: 'away', overrideReason: 'Referee awarded set' },
    ]);
    expect(state.score.awaySets).toBe(1);
  });

  it.each([
    { type: 'end_set', winner: 'home' },
    { type: 'end_set', overrideReason: 'Forfeit' },
    { type: 'end_set', winner: 'home', overrideReason: '' },
    { type: 'end_set', winner: 'home', overrideReason: '   ' },
  ] satisfies ScoringOperation[])('rejects incomplete override metadata: %j', (operation) => {
    expectError(atScore(25, 0), operation, 'invalid_override');
  });

  it('rejects tied sets even with a manual override', () => {
    expectError(atScore(0, 0), { type: 'end_set' }, 'tied_set');
    expectError(
      atScore(26, 26),
      { type: 'end_set', winner: 'home', overrideReason: 'Referee decision' },
      'tied_set',
    );
  });

  it('undoes points and completed sets in order without negative points', () => {
    const beforeSet = atScore(25, 23);
    const afterSet = applyScoringOperation(beforeSet, defaultRules, { type: 'end_set' });
    const afterPoint = applyScoringOperation(afterSet, defaultRules, {
      type: 'award_point',
      side: 'away',
    });
    const undoPoint = applyScoringOperation(afterPoint, defaultRules, { type: 'undo' });
    expect(undoPoint).toEqual(afterSet);
    const undoSet = applyScoringOperation(undoPoint, defaultRules, { type: 'undo' });
    expect(undoSet).toEqual(beforeSet);
    let state = undoSet;
    while (state.history.length)
      state = applyScoringOperation(state, defaultRules, { type: 'undo' });
    expect(state).toEqual(initialScoringState());
    expectError(state, { type: 'undo' }, 'nothing_to_undo');
  });

  it('accepts deeply frozen inputs through points, set completion, undo, and match ending', () => {
    function freezeDeep(value: unknown): void {
      if (value === null || typeof value !== 'object' || Object.isFrozen(value)) return;
      for (const nested of Object.values(value)) freezeDeep(nested);
      Object.freeze(value);
    }

    function transition(state: ScoringState, operation: ScoringOperation): ScoringState {
      const before = structuredClone(state);
      freezeDeep(state);
      const result = applyScoringOperation(state, defaultRules, operation);
      expect(result).not.toBe(state);
      expect(state).toEqual(before);
      return result;
    }

    const beforeSet = transition(atScore(24, 23), { type: 'award_point', side: 'home' });
    expect(beforeSet.score.home).toBe(25);
    const afterSet = transition(beforeSet, { type: 'end_set' });
    expect(afterSet.score).toEqual({ home: 0, away: 0, set: 2, homeSets: 1, awaySets: 0 });
    expect(afterSet.completedSets).toHaveLength(1);
    const afterPoint = transition(afterSet, { type: 'award_point', side: 'away' });
    expect(afterPoint.score.away).toBe(1);
    const undoPoint = transition(afterPoint, { type: 'undo' });
    expect(undoPoint).toEqual(afterSet);
    const undoSet = transition(undoPoint, { type: 'undo' });
    expect(undoSet).toEqual(beforeSet);
    const ended = transition(undoSet, { type: 'end_match', reason: 'Weather' });
    expect(ended).toEqual({ ...undoSet, status: 'ended', endReason: 'Weather' });
  });

  it('ends a match with a reason and rejects all subsequent commands without mutation', () => {
    const state = atScore(5, 3);
    expectError(state, { type: 'end_match', reason: '   ' }, 'invalid_end_reason');
    const ended = applyScoringOperation(state, defaultRules, {
      type: 'end_match',
      reason: '  Weather  ',
    });
    expect(ended).toEqual({ ...state, status: 'ended', endReason: 'Weather' });
    for (const operation of [
      { type: 'award_point', side: 'home' },
      { type: 'undo' },
      { type: 'end_set' },
      { type: 'end_match', reason: 'Again' },
    ] satisfies ScoringOperation[])
      expectError(ended, operation, 'match_ended');
    expect(state.status).toBe('active');
  });

  it('permits ending a match after the winning set', () => {
    const won = finishSet(finishSet(initialScoringState(), 'home'), 'home');
    expect(
      applyScoringOperation(won, defaultRules, { type: 'end_match', reason: 'Match complete' })
        .status,
    ).toBe('ended');
  });
});

describe('match rule validation', () => {
  it.each([
    { bestOf: 1 },
    { bestOf: 4 },
    { pointsToWin: 0 },
    { pointsToWin: 100 },
    { pointsToWin: 1.5 },
    { decidingPointsToWin: 0 },
    { decidingPointsToWin: 100 },
    { decidingPointsToWin: NaN },
    { winBy: 0 },
    { winBy: 11 },
    { winBy: 1.5 },
    { pointCap: 24 },
    { pointCap: 200 },
    { pointCap: 30.5 },
    { pointsToWin: 15, decidingPointsToWin: 25, pointCap: 20 },
  ])('rejects invalid rules %j', (overrides) => {
    const rules = { ...defaultRules, ...overrides } as MatchRules;
    expect(() => validateRules(rules)).toThrow(expect.objectContaining({ code: 'invalid_rules' }));
    expectError(
      initialScoringState(),
      { type: 'award_point', side: 'home' },
      'invalid_rules',
      rules,
    );
  });

  it('accepts boundary values and an absent cap', () => {
    expect(() => validateRules(defaultRules)).not.toThrow();
    expect(() =>
      validateRules({
        bestOf: 5,
        pointsToWin: 1,
        decidingPointsToWin: 99,
        winBy: 10,
        pointCap: 199,
      }),
    ).not.toThrow();
    expect(() => validateRules({ ...defaultRules, pointCap: 25 })).not.toThrow();
  });
});

describe('pendingSetEnd', () => {
  const end = (state: ScoringState, rules = defaultRules) =>
    applyScoringOperation(state, rules, { type: 'end_set' });
  it('flags set point at 25, win by 2, for either side', () => {
    expect(pendingSetEnd(atScore(24, 23), defaultRules)).toBeNull();
    expect(pendingSetEnd(atScore(25, 23), defaultRules)).toEqual({ winner: 'home' });
    expect(pendingSetEnd(atScore(24, 25), defaultRules)).toBeNull();
    expect(pendingSetEnd(atScore(24, 26), defaultRules)).toEqual({ winner: 'away' });
    expect(pendingSetEnd(atScore(30, 28), defaultRules)).toEqual({ winner: 'home' });
  });
  it('agrees with end_set: pending exactly when an unforced end_set is accepted', () => {
    const rules: MatchRules = { ...defaultRules, pointCap: 27 };
    for (let home = 0; home <= 28; home++)
      for (let away = 0; away <= 28; away++) {
        if (Math.max(home, away) > 27) continue;
        const state = atScore(home, away, rules);
        let accepted = true;
        try {
          end(state, rules);
        } catch {
          accepted = false;
        }
        expect(pendingSetEnd(state, rules) !== null, `${home}-${away}`).toBe(accepted);
      }
  });
  it('uses the deciding-set target and the optional cap', () => {
    let state = finishSet(finishSet(initialScoringState(), 'home'), 'away');
    expect(state.score.set).toBe(3);
    expect(pendingSetEnd(points(points(state, 'home', 14), 'away', 13), defaultRules)).toBeNull();
    state = points(points(state, 'home', 15), 'away', 13);
    expect(pendingSetEnd(state, defaultRules)).toEqual({ winner: 'home' });
    const capped: MatchRules = { ...defaultRules, pointCap: 27 };
    expect(pendingSetEnd(atScore(27, 26, capped), capped)).toEqual({ winner: 'home' });
    expect(pendingSetEnd(atScore(26, 25, capped), capped)).toBeNull();
  });
  it('is null once the match is decided or ended', () => {
    const won = finishSet(finishSet(initialScoringState(), 'home'), 'home');
    expect(pendingSetEnd(won, defaultRules)).toBeNull();
    const ended = applyScoringOperation(atScore(25, 10), defaultRules, {
      type: 'end_match',
      reason: 'rain',
    });
    expect(pendingSetEnd(ended, defaultRules)).toBeNull();
  });
});

describe('defaultShortName', () => {
  it('takes the first 8 characters of the collapsed name', () => {
    expect(defaultShortName('Spikers')).toBe('Spikers');
    expect(defaultShortName('  Bay   Area Juniors')).toBe('Bay Area');
    expect(defaultShortName('Volleyball Club')).toBe('Volleyba');
    expect(defaultShortName('Team 🏐🏐🏐🏐🏐')).toBe('Team 🏐🏐🏐');
  });
});
