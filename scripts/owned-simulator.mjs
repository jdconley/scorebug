import assert from 'node:assert/strict';
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

/** The caller supplies a unique name. Creation can commit in CoreSimulator before
 * the client exits; reconcile that exact name when no ID was returned. */
export async function createOwnedSimulator(run, name, runtime) {
  try {
    const id = await run(
      'xcrun',
      ['simctl', 'create', name, 'com.apple.CoreSimulator.SimDeviceType.iPhone-14', runtime],
      'create',
      { cleanup: true },
    );
    assert.match(id, uuid);
    return id;
  } catch (creationError) {
    try {
      const inventory = JSON.parse(
        await run('xcrun', ['simctl', 'list', 'devices', '--json'], 'reconcile-create', {
          cleanup: true,
        }),
      );
      const owned = Object.values(inventory.devices)
        .flat()
        .filter((d) => d.name === name);
      for (const device of owned) {
        assert.match(device.udid, uuid);
        await run('xcrun', ['simctl', 'delete', device.udid], 'delete-created', { cleanup: true });
      }
    } catch (cleanupError) {
      throw new AggregateError(
        [creationError, cleanupError],
        'Simulator creation and reconciliation failed',
      );
    }
    throw creationError;
  }
}
