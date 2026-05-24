import { useEffect, useState } from 'react';
import type { Score, Team } from '@scorebug/protocol';
import { api, ApiError, type ControlPlaneConfig, type StartGameResponse } from './api.js';
import { Settings } from './components/Settings.js';
import { GameSetup, type TeamForm } from './components/GameSetup.js';
import { Scoreboard } from './components/Scoreboard.js';
import * as storage from './storage.js';

type ActiveGame = {
  id: string;
  homeTeam: Team;
  awayTeam: Team;
  score: Score;
};

const initialScore = (): Score => ({
  home: 0,
  away: 0,
  set: 1,
  homeSets: 0,
  awaySets: 0,
});

function describeError(err: unknown): string {
  if (err instanceof ApiError) {
    const body = err.body as { error?: string } | undefined;
    if (err.status === 401) return 'Bad phone token. Check Settings.';
    if (err.status === 409 && body?.error === 'game_in_flight') {
      return 'A game is already running. End it from the previous device first.';
    }
    return `Server returned ${err.status}.`;
  }
  return err instanceof Error ? err.message : String(err);
}

export function App() {
  const [config, setConfig] = useState<ControlPlaneConfig | undefined>(() => storage.loadConfig());
  const [showSettings, setShowSettings] = useState(false);
  const [active, setActive] = useState<ActiveGame | undefined>(undefined);
  const [setupError, setSetupError] = useState<string | undefined>(undefined);
  const [scoreError, setScoreError] = useState<string | undefined>(undefined);
  const [busy, setBusy] = useState(false);
  const [homeConnected, setHomeConnected] = useState<boolean | undefined>(undefined);

  // Poll health every 5s so the operator sees if home daemon went offline.
  useEffect(() => {
    if (!config) return;
    let cancelled = false;
    const tick = async () => {
      try {
        const h = await api.health(config);
        if (!cancelled) setHomeConnected(h.home);
      } catch {
        if (!cancelled) setHomeConnected(undefined);
      }
    };
    void tick();
    const t = setInterval(() => void tick(), 5000);
    return () => {
      cancelled = true;
      clearInterval(t);
    };
  }, [config]);

  if (!config || showSettings) {
    return (
      <div className="app">
        <Settings
          initial={config}
          onSave={(cfg) => {
            storage.saveConfig(cfg);
            setConfig(cfg);
            setShowSettings(false);
          }}
          onCancel={() => setShowSettings(false)}
        />
      </div>
    );
  }

  if (active) {
    return (
      <div className="app">
        <Topbar
          status={
            homeConnected === undefined ? 'control plane?' : homeConnected ? 'home ✓' : 'home ✗'
          }
          onSettings={() => setShowSettings(true)}
        />
        <Scoreboard
          homeTeam={active.homeTeam}
          awayTeam={active.awayTeam}
          initial={active.score}
          error={scoreError}
          onChange={async (next) => {
            setActive({ ...active, score: next });
            setScoreError(undefined);
            try {
              await api.setScore(config, active.id, next);
            } catch (err) {
              setScoreError(describeError(err));
            }
          }}
          onEndGame={() => {
            if (!window.confirm('End the game?')) return;
            void (async () => {
              try {
                await api.endGame(config, active.id);
              } catch {
                /* swallow — operator wants out */
              }
              storage.saveActiveGame(undefined);
              setActive(undefined);
            })();
          }}
        />
      </div>
    );
  }

  const lastTeams = storage.loadLastTeams();

  const startGame = async (f: TeamForm) => {
    setBusy(true);
    setSetupError(undefined);
    storage.saveLastTeams({
      home: f.home,
      homeShort: f.homeShort,
      away: f.away,
      awayShort: f.awayShort,
    });
    const homeTeam: Team = { name: f.home, shortName: f.homeShort, color: '#1e3a8a' };
    const awayTeam: Team = { name: f.away, shortName: f.awayShort, color: '#b91c1c' };
    try {
      const res: StartGameResponse = await api.startGame(config, {
        homeTeam,
        awayTeam,
        youtubeStreamKey: f.youtubeStreamKey,
      });
      storage.saveActiveGame(res.id);
      setActive({ id: res.id, homeTeam, awayTeam, score: initialScore() });
    } catch (err) {
      setSetupError(describeError(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="app">
      <Topbar
        status={
          homeConnected === undefined ? 'control plane?' : homeConnected ? 'home ✓' : 'home ✗'
        }
        onSettings={() => setShowSettings(true)}
      />
      <GameSetup
        initial={lastTeams}
        onStart={startGame}
        onOpenSettings={() => setShowSettings(true)}
        error={setupError}
        busy={busy}
      />
    </div>
  );
}

function Topbar(props: { status: string; onSettings: () => void }) {
  return (
    <div className="topbar">
      <span>Scorebug</span>
      <span className="status" onClick={props.onSettings} style={{ cursor: 'pointer' }}>
        {props.status} · ⚙
      </span>
    </div>
  );
}
