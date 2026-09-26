import assert from 'node:assert/strict';
import { test } from 'node:test';
import { qualifyOrdinaryPairedEvidence } from '../ordinary-paired-evidence.mjs';

function fixture(explicitStop = false) {
  const commands = [
    'take_over',
    'take_over',
    'award_point',
    'undo',
    'award_point',
    'end_match',
  ].map((type, i) => ({
    request: {
      commandId: `command-${i}`,
      deviceId: i ? 'real-watch' : 'phone',
      operation: { type, ...(i === 2 ? { side: 'home' } : i === 4 ? { side: 'away' } : {}) },
    },
    outcome: {
      accepted: true,
      commandId: `command-${i}`,
      snapshot: {
        scorer: { deviceId: i ? 'real-watch' : 'phone' },
        score: { home: i === 2 ? 1 : 0, away: i >= 4 ? 1 : 0 },
        broadcast: { desired: i === 5 ? 'stopped' : 'running', generation: i === 5 ? 2 : 1 },
      },
    },
  }));
  const mediaCommands = [
    {
      request: {
        commandId: 'start',
        expectedGeneration: 0,
        operation: {
          type: 'start',
          selection: { captureDeviceId: 'film-device', recordingId: 'native-recording' },
        },
      },
      outcome: {
        accepted: true,
        commandId: 'start',
        snapshot: {
          broadcast: { desired: 'running', generation: 1 },
          recordings: [
            { recordingId: 'native-recording', deviceId: 'film-device', status: 'recording' },
          ],
        },
      },
    },
  ];
  if (explicitStop)
    mediaCommands.push({
      request: { commandId: 'stop', expectedGeneration: 2, operation: { type: 'stop' } },
      outcome: {
        accepted: true,
        commandId: 'stop',
        snapshot: { broadcast: { desired: 'stopped', generation: 3 } },
      },
    });
  return {
    pairings: [{ pairing_id: 'pair', watch_device_id: 'real-watch', redemption_request: '{}' }],
    commands,
    mediaCommands,
    final: {
      status: 'ended',
      score: { home: 0, away: 1 },
      scorer: { deviceId: 'real-watch' },
      broadcast: { desired: 'stopped', generation: explicitStop ? 3 : 2 },
    },
  };
}
for (const explicitStop of [false, true])
  test(`qualifies real Watch operations and end-generation stop, explicit stop ${explicitStop}`, () => {
    assert.equal(qualifyOrdinaryPairedEvidence(fixture(explicitStop)).watchCommands.length, 5);
  });
for (const [name, mutate] of Object.entries({
  'unredeemed offer': (f) => {
    f.pairings[0].redemption_request = null;
  },
  'fixture identity': (f) => {
    f.pairings[0].watch_device_id = 'phone';
  },
  'phone authored point': (f) => {
    f.commands[2].request.deviceId = 'phone';
  },
  'rejected operation': (f) => {
    f.commands[3].outcome.accepted = false;
  },
  'duplicate command': (f) => {
    f.commands[3].request.commandId = 'command-2';
  },
  'wrong point side': (f) => {
    f.commands[4].request.operation.side = 'home';
  },
  'absent undo transition': (f) => {
    f.commands[3].outcome.snapshot.score.home = 1;
  },
  'no live start': (f) => {
    f.mediaCommands = [];
  },
  'wrong capture owner': (f) => {
    f.mediaCommands[0].outcome.snapshot.recordings[0].deviceId = 'unrelated';
  },
  'wrong selected recording': (f) => {
    f.mediaCommands[0].request.operation.selection.recordingId = 'unrelated';
  },
  'stale match-end generation': (f) => {
    f.commands[5].outcome.snapshot.broadcast.generation = 1;
  },
  'unexpected restart': (f) => {
    f.mediaCommands.push(f.mediaCommands[0]);
  },
  'wrong final generation': (f) => {
    f.final.broadcast.generation = 4;
  },
}))
  test(`rejects ${name} despite the expected final score`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualifyOrdinaryPairedEvidence(f));
  });
