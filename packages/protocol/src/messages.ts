export type Team = {
  name: string;
  shortName: string;
  color: string;
};

export type Teams = {
  home: Team;
  away: Team;
};

export type Score = {
  /** Current set points for the home team. */
  home: number;
  /** Current set points for the away team. */
  away: number;
  /** Current set number, 1-indexed. */
  set: number;
  /** Sets won so far by the home team. */
  homeSets: number;
  /** Sets won so far by the away team. */
  awaySets: number;
};
