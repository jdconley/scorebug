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
  home: number;
  away: number;
  set: number;
};

export type Player = {
  number: number;
  name: string;
};

export type CalloutKind = 'kill' | 'dig' | 'block';

export type CalloutEvent = {
  kind: CalloutKind;
  player: Player;
};

export type GameStatus = 'starting' | 'live' | 'ended';

export type GameSession = {
  id: string;
  homeTeam: Team;
  awayTeam: Team;
  youtubeStreamKey: string;
  publishStreamId: string;
  status: GameStatus;
  createdAt: string;
};

// Control plane → home daemon
export type HomeMessage =
  | {
      type: 'start_game';
      gameId: string;
      pullUrl: string;
      youtubeStreamKey: string;
      teams: Teams;
    }
  | {
      type: 'end_game';
      gameId: string;
    }
  | {
      type: 'score_update';
      gameId: string;
      score: Score;
    }
  | {
      type: 'callout';
      gameId: string;
      event: CalloutEvent;
    };

// Home daemon → control plane
export type HomeReport =
  | { type: 'pipeline_started'; gameId: string }
  | { type: 'pipeline_stopped'; gameId: string; reason: string }
  | { type: 'error'; gameId: string; message: string };

export type PipelineStopReason =
  | 'requested'
  | 'source_disconnected'
  | 'youtube_rejected'
  | 'crashed';
