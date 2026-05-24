import { useEffect, useState } from 'react';
import type { Score, Team } from '@scorebug/protocol';

export function Scoreboard(props: {
  homeTeam: Team;
  awayTeam: Team;
  initial: Score;
  onChange: (next: Score) => Promise<void> | void;
  onEndGame: () => void;
  error?: string | undefined;
}) {
  const [score, setScore] = useState<Score>(props.initial);
  const [history, setHistory] = useState<Score[]>([]);
  const [busy, setBusy] = useState(false);

  // Re-sync if the parent hands us a new initial (e.g. server rehydrate).
  useEffect(() => setScore(props.initial), [props.initial]);

  const push = (next: Score) => {
    setHistory((h) => [...h.slice(-30), score]);
    setScore(next);
    setBusy(true);
    Promise.resolve(props.onChange(next)).finally(() => setBusy(false));
  };

  const inc = (side: 'home' | 'away') =>
    push({ ...score, [side]: score[side] + 1 });

  const undo = () => {
    if (history.length === 0) return;
    const prev = history[history.length - 1]!;
    setHistory((h) => h.slice(0, -1));
    setScore(prev);
    setBusy(true);
    Promise.resolve(props.onChange(prev)).finally(() => setBusy(false));
  };

  const endSet = () => {
    const homeWon = score.home > score.away;
    const next: Score = {
      home: 0,
      away: 0,
      set: score.set + 1,
      homeSets: score.homeSets + (homeWon ? 1 : 0),
      awaySets: score.awaySets + (homeWon ? 0 : 1),
    };
    push(next);
  };

  return (
    <div className="scoreboard">
      <div className="team-header home">{props.homeTeam.shortName}</div>
      <div className="team-header away">{props.awayTeam.shortName}</div>

      <button
        className="bigscore home"
        onClick={() => inc('home')}
        disabled={busy}
        aria-label={`${props.homeTeam.name} plus one`}
      >
        {score.home}
      </button>
      <button
        className="bigscore away"
        onClick={() => inc('away')}
        disabled={busy}
        aria-label={`${props.awayTeam.name} plus one`}
      >
        {score.away}
      </button>

      <div className="set-line">
        Set {score.set} · {score.homeSets}–{score.awaySets} sets
      </div>

      {props.error ? <div className="error">{props.error}</div> : null}

      <div className="controls">
        <button onClick={undo} disabled={history.length === 0 || busy}>Undo</button>
        <button onClick={endSet} className="ok" disabled={busy}>End set</button>
        <button onClick={() => props.onChange(score)} disabled={busy}>Resync</button>
        <button onClick={props.onEndGame} className="danger" disabled={busy}>End game</button>
      </div>
    </div>
  );
}
