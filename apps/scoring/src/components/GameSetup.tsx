import { useState } from 'react';

export type TeamForm = {
  home: string;
  homeShort: string;
  away: string;
  awayShort: string;
  youtubeStreamKey: string;
};

export function GameSetup(props: {
  initial?: { home: string; homeShort: string; away: string; awayShort: string } | undefined;
  onStart: (f: TeamForm) => Promise<void> | void;
  onOpenSettings: () => void;
  error?: string | undefined;
  busy?: boolean;
}) {
  const [home, setHome] = useState(props.initial?.home ?? '');
  const [homeShort, setHomeShort] = useState(props.initial?.homeShort ?? '');
  const [away, setAway] = useState(props.initial?.away ?? '');
  const [awayShort, setAwayShort] = useState(props.initial?.awayShort ?? '');
  const [youtubeStreamKey, setYoutubeStreamKey] = useState('');

  const valid =
    home.length > 0 &&
    homeShort.length > 0 &&
    homeShort.length <= 8 &&
    away.length > 0 &&
    awayShort.length > 0 &&
    awayShort.length <= 8 &&
    youtubeStreamKey.length >= 8;

  return (
    <div className="setup">
      <h1>New game</h1>
      <div className="row">
        <div className="field">
          <label>Home team</label>
          <input value={home} onChange={(e) => setHome(e.target.value)} placeholder="Home" />
        </div>
        <div className="field" style={{ flex: 0, width: 110 }}>
          <label>Short</label>
          <input
            value={homeShort}
            onChange={(e) => setHomeShort(e.target.value.toUpperCase().slice(0, 8))}
            placeholder="HOME"
          />
        </div>
      </div>
      <div className="row">
        <div className="field">
          <label>Away team</label>
          <input value={away} onChange={(e) => setAway(e.target.value)} placeholder="Away" />
        </div>
        <div className="field" style={{ flex: 0, width: 110 }}>
          <label>Short</label>
          <input
            value={awayShort}
            onChange={(e) => setAwayShort(e.target.value.toUpperCase().slice(0, 8))}
            placeholder="AWAY"
          />
        </div>
      </div>
      <div className="field">
        <label>YouTube stream key</label>
        <input
          value={youtubeStreamKey}
          onChange={(e) => setYoutubeStreamKey(e.target.value.trim())}
          placeholder="abcd-1234-efgh-5678"
          type="password"
          autoCapitalize="off"
          autoCorrect="off"
        />
      </div>
      {props.error ? <div className="error">{props.error}</div> : null}
      <button
        className="primary"
        disabled={!valid || props.busy}
        onClick={() => props.onStart({ home, homeShort, away, awayShort, youtubeStreamKey })}
      >
        {props.busy ? 'Starting…' : 'Start Game'}
      </button>
      <button
        onClick={props.onOpenSettings}
        style={{
          background: '#1a1a1a',
          color: '#fff',
          padding: 12,
          borderRadius: 10,
          border: '1px solid #333',
          fontSize: 14,
        }}
      >
        Settings
      </button>
    </div>
  );
}
