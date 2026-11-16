import { SLOT_STALE_MS } from './channels.js';
import type { Env } from './env.js';
import type { MediaAdapters } from './media-adapters.js';
import { parseInputName } from './stream.js';

const DAY_MS = 24 * 60 * 60 * 1000;
/** An input this new may be mid-create in its team object; leave it for tomorrow. */
const INPUT_GRACE_MS = 60 * 60 * 1000;

export type SweepResult = { teams: number; deletedInputs: number; failedTeams: number };

/**
 * Daily backstop for the team objects' own guards. Visits every team that could have
 * something running (a live slot, a recent match, or a Stream input named for it), lets it
 * apply its guards and stop an orphaned container, then deletes Stream inputs no open match
 * uses. Every orphan it finds is logged as an error, which is the alert.
 */
export async function sweep(
  env: Env,
  adapters: MediaAdapters,
  now = Date.now(),
): Promise<SweepResult> {
  let inputs: { uid: string; name: string | null; createdAt: number }[] = [];
  try {
    inputs = await adapters.stream.listInputs();
  } catch (error) {
    console.error('sweep_stream_list_failed', String(error));
  }
  const ours = inputs.flatMap((input) => {
    const owner = parseInputName(input.name);
    return owner ? [{ ...input, ...owner }] : [];
  });
  const [slots, recent] = await Promise.all([
    env.DB.prepare('SELECT DISTINCT team_id FROM live_slots').all<{ team_id: string }>(),
    env.DB.prepare('SELECT DISTINCT team_id FROM match_index WHERE created_at>?')
      .bind(now - 2 * DAY_MS)
      .all<{ team_id: string }>(),
  ]);
  const teams = new Set([
    ...slots.results.map((row) => row.team_id),
    ...recent.results.map((row) => row.team_id),
    ...ours.map((input) => input.teamId),
  ]);
  const referenced = new Set<string>();
  const unreachable = new Set<string>();
  for (const teamId of teams) {
    try {
      const result = await env.TEAM.getByName(teamId).sweep(teamId);
      for (const uid of result.inputs) referenced.add(uid);
    } catch (error) {
      unreachable.add(teamId);
      console.error('sweep_team_failed', teamId, String(error));
    }
  }
  let deletedInputs = 0;
  for (const input of ours) {
    if (referenced.has(input.uid) || unreachable.has(input.teamId)) continue;
    if (now - input.createdAt < INPUT_GRACE_MS) continue;
    console.error('sweep_orphan_input', input.uid, input.teamId, input.gameId);
    try {
      await adapters.stream.deleteInput(input.uid);
      deletedInputs++;
    } catch (error) {
      console.error('sweep_input_delete_failed', input.uid, String(error));
    }
  }
  await env.DB.prepare('DELETE FROM live_slots WHERE renewed_at<?')
    .bind(now - SLOT_STALE_MS)
    .run();
  return { teams: teams.size, deletedInputs, failedTeams: unreachable.size };
}
