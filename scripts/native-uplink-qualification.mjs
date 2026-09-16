import assert from 'node:assert/strict';

/** Send attempts prove fixture accounting only. Native media and receiver gates
 * independently establish delivered frame continuity and timing. */
export function qualifyNativeUplinkProxy(snapshot) {
  assert.equal(snapshot.formatVersion, 1);
  assert.equal(snapshot.closed, true, 'Uplink closure must be joined');
  assert.equal(snapshot.foreignPeerPackets, 0, 'Uplink peer changed or received foreign traffic');
  assert.deepEqual(snapshot.errors, [], 'Uplink socket error');
  const result = { profile: 'passthrough' };
  for (const direction of ['forward', 'reverse']) {
    const d = snapshot[direction],
      q = d.queue,
      c = q.configuration;
    assert.equal(d.pendingPackets, 0);
    assert.equal(d.pendingPayloadBytes, 0);
    assert.equal(q.closed, true);
    assert.deepEqual(
      c,
      {
        rateBitsPerSecond: null,
        delayMilliseconds: 0,
        dropEvery: 0,
        maxDatagramBytes: 2048,
        burstBytes: 16384,
        maxQueuePackets: 256,
        maxQueueBytes: 262144,
      },
      'Unexpected pass-through configuration',
    );
    for (const unit of ['packets', 'wireBytes']) {
      for (const counter of [
        'received',
        'forwarded',
        'injectedDrop',
        'overflowDrop',
        'oversizeDrop',
        'closeDiscard',
        'queue',
      ])
        assert.ok(
          Number.isSafeInteger(q[counter][unit]) && q[counter][unit] >= 0,
          'Invalid uplink counter',
        );
      assert.ok(q.forwarded[unit] > 0, 'Missing bidirectional uplink traffic');
      for (const counter of [
        'injectedDrop',
        'overflowDrop',
        'oversizeDrop',
        'closeDiscard',
        'queue',
      ])
        assert.equal(q[counter][unit], 0, 'Pass-through dropped or retained packets');
      assert.equal(q.received[unit], q.forwarded[unit], 'Uplink conservation mismatch');
    }
    assert.ok(q.forwarded.wireBytes >= q.forwarded.packets * 28);
    result[direction + 'Packets'] = q.forwarded.packets;
    result[direction + 'WireBytes'] = q.forwarded.wireBytes;
  }
  return result;
}
