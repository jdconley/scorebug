import { describe, expect, it } from 'vitest';
import { placeholderLine, renderOverlayLine } from '../src/overlay-text.js';

const home = { name: 'Spikers', shortName: 'SPK', color: '#1e3a8a' };
const away = { name: 'Diggers', shortName: 'DIG', color: '#b91c1c' };

describe('renderOverlayLine', () => {
  it('formats sets and points', () => {
    const line = renderOverlayLine(home, away, {
      home: 18,
      away: 15,
      set: 3,
      homeSets: 2,
      awaySets: 1,
    });
    expect(line).toBe('SPK 18-15 DIG · Set 3 · Sets 2-1');
  });

  it('renders 0-0 at start', () => {
    const line = renderOverlayLine(home, away, {
      home: 0,
      away: 0,
      set: 1,
      homeSets: 0,
      awaySets: 0,
    });
    expect(line).toBe('SPK 0-0 DIG · Set 1 · Sets 0-0');
  });
});

describe('placeholderLine', () => {
  it('returns the brand', () => {
    expect(placeholderLine()).toBe('Scorebug');
  });
});
