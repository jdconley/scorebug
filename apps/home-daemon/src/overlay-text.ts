import type { Score, Team } from '@scorebug/protocol';

/**
 * v1 overlay is a single textfile read by ffmpeg drawtext. We pack everything
 * onto one line because drawtext's textfile mode renders only the first line.
 * Format chosen so it's readable at 1080p with a single drawtext box:
 *
 *   SPK 18-15 DIG · Set 3 · Sets 2-1
 */
export function renderOverlayLine(homeTeam: Team, awayTeam: Team, score: Score): string {
  return [
    `${homeTeam.shortName} ${score.home}-${score.away} ${awayTeam.shortName}`,
    `Set ${score.set}`,
    `Sets ${score.homeSets}-${score.awaySets}`,
  ].join(' · ');
}

/** Inserted before a game starts so ffmpeg has something to render. */
export function placeholderLine(): string {
  return 'Scorebug';
}
