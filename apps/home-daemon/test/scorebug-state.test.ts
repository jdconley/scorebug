import { describe, expect, it } from 'vitest';
import {
  parseScorebugOverlay,
  scorebugOverlay,
  serializeScorebugOverlay,
} from '../src/scorebug/state.js';

const teams = {
  home: { name: 'Home', shortName: 'H', color: '#112233' },
  away: { name: 'Away', shortName: 'A', color: '#445566' },
};
const score = { home: 3, away: 1, set: 2, homeSets: 1, awaySets: 0 };

describe('scorebug overlay state', () => {
  it('maps a match snapshot, dropping override reasons and inventing no serve or label', () => {
    expect(
      scorebugOverlay({
        teams,
        score,
        rules: { bestOf: 5 },
        scorebugStyle: 'lowerThird',
        completedSets: [
          { set: 1, home: 25, away: 20, winner: 'home', overrideReason: 'x' } as never,
        ],
      }),
    ).toEqual({
      style: 'lowerThird',
      label: null,
      bestOf: 5,
      teams,
      score,
      completedSets: [{ set: 1, home: 25, away: 20, winner: 'home' }],
      serving: null,
    });
  });
  it('round-trips through the score file and rejects anything else', () => {
    const overlay = scorebugOverlay({
      teams,
      score,
      rules: { bestOf: 3 },
      completedSets: [],
      scorebugStyle: 'setCard',
    });
    const text = serializeScorebugOverlay(overlay);
    expect(text.endsWith('\n')).toBe(true);
    expect(parseScorebugOverlay(text)).toEqual(overlay);
    expect(parseScorebugOverlay('HOME 12 - 7 AWAY')).toBeNull();
    expect(parseScorebugOverlay(JSON.stringify({ ...overlay, style: 'neon' }))).toBeNull();
    expect(parseScorebugOverlay(JSON.stringify({ ...overlay, bestOf: 4 }))).toBeNull();
  });
});
