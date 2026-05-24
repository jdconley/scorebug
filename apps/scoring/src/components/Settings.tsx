import { useState } from 'react';
import type { ControlPlaneConfig } from '../api.js';

export function Settings(props: {
  initial: ControlPlaneConfig | undefined;
  onSave: (cfg: ControlPlaneConfig) => void;
  onCancel: () => void;
}) {
  const [baseUrl, setBaseUrl] = useState(props.initial?.baseUrl ?? 'http://localhost:8787');
  const [token, setToken] = useState(props.initial?.phoneToken ?? '');

  return (
    <div className="setup">
      <h1>Settings</h1>
      <div className="field">
        <label>Control plane URL</label>
        <input
          value={baseUrl}
          onChange={(e) => setBaseUrl(e.target.value)}
          autoCapitalize="off"
          autoCorrect="off"
        />
      </div>
      <div className="field">
        <label>Phone bearer token</label>
        <input
          value={token}
          onChange={(e) => setToken(e.target.value)}
          autoCapitalize="off"
          autoCorrect="off"
          type="password"
        />
      </div>
      <button
        className="primary"
        disabled={!baseUrl || token.length < 16}
        onClick={() => props.onSave({ baseUrl: baseUrl.replace(/\/$/, ''), phoneToken: token })}
      >
        Save
      </button>
      {props.initial ? (
        <button
          onClick={props.onCancel}
          style={{
            background: '#222',
            color: '#fff',
            padding: 14,
            borderRadius: 10,
            border: 'none',
            fontSize: 16,
          }}
        >
          Cancel
        </button>
      ) : null}
    </div>
  );
}
