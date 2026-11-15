import assert from 'node:assert/strict';
import test from 'node:test';
import { createSocket } from 'node:dgram';
import { setTimeout as delay } from 'node:timers/promises';
import { nativeUplinkOptions } from '../native-streaming-options.mjs';
import { qualifyNativeUplinkProxy } from '../native-uplink-qualification.mjs';
import { createUDPImpairmentProxy } from '../udp-impairment.mjs';
const options = () => ({
  environment: {
    SCOREBUG_TEST_UPLINK_PROFILE: 'passthrough',
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
  },
  streaming: true,
  requireQuality: true,
  requireConfirmation: true,
  requireProcessing: true,
  requirePublication: true,
  fixtureWorkload: 'motion-blocks16',
});
test('uplink mode is explicit and reserves the generated port', () => {
  assert.equal(nativeUplinkOptions(options()), 'passthrough');
  assert.equal(nativeUplinkOptions({ environment: {} }), null);
  for (const raw of ['', '1', 'limited', 'passthrough ']) {
    const o = options();
    o.environment.SCOREBUG_TEST_UPLINK_PROFILE = raw;
    assert.throws(() => nativeUplinkOptions(o));
  }
  for (const key of [
    'streaming',
    'requireQuality',
    'requireConfirmation',
    'requireProcessing',
    'requirePublication',
  ]) {
    const o = options();
    o[key] = false;
    assert.throws(() => nativeUplinkOptions(o));
  }
  for (const workload of ['barcode', 'motion']) {
    const o = options();
    o.fixtureWorkload = workload;
    assert.throws(() => nativeUplinkOptions(o));
  }
  const o = options();
  delete o.environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER;
  assert.throws(() => nativeUplinkOptions(o));
  for (const raw of ['', '1234'])
    assert.throws(() =>
      nativeUplinkOptions({ environment: { SCOREBUG_TEST_UPLINK_PROXY_PORT: raw } }),
    );
});
test('qualifies actual bidirectional passthrough and rejects corrupt or incomplete evidence', async (t) => {
  const sockets = [];
  const socket = async () => {
    const s = createSocket('udp4');
    sockets.push(s);
    await new Promise((resolve) => s.bind(0, '127.0.0.1', resolve));
    return s;
  };
  const receiver = await socket(),
    client = await socket();
  const proxy = await createUDPImpairmentProxy({ receiverPort: receiver.address().port });
  t.after(async () => {
    await proxy.close();
    await Promise.all(sockets.map((s) => new Promise((resolve) => s.close(resolve))));
  });
  receiver.on('message', (data, peer) => receiver.send(data, peer.port, peer.address));
  let received = false;
  client.on('message', () => {
    received = true;
  });
  client.send(Buffer.from('fixture'), proxy.port, '127.0.0.1');
  for (let i = 0; i < 200 && !received; i++) await delay(5);
  assert.ok(received);
  assert.throws(() => qualifyNativeUplinkProxy(proxy.snapshot()));
  await proxy.close();
  const snapshot = proxy.snapshot();
  assert.deepEqual(qualifyNativeUplinkProxy(snapshot), {
    profile: 'passthrough',
    forwardPackets: 1,
    reversePackets: 1,
    forwardWireBytes: 35,
    reverseWireBytes: 35,
  });
  const mutations = [
    (s) => (s.forwardRateSchedule = {}),
    (s) => (s.formatVersion = 2),
    (s) => (s.foreignPeerPackets = 1),
    (s) => s.errors.push('EIO'),
  ];
  for (const direction of ['forward', 'reverse']) {
    for (const field of ['pendingPackets', 'pendingPayloadBytes'])
      mutations.push((s) => (s[direction][field] = 1));
    mutations.push((s) => (s[direction].queue.closed = false));
    mutations.push((s) => (s[direction].queue.configuration.rateBitsPerSecond = 4000000));
    mutations.push((s) => (s[direction].queue.configuration.delayMilliseconds = 1));
    mutations.push((s) => (s[direction].queue.configuration.dropEvery = 1));
    for (const field of [
      'received',
      'forwarded',
      'injectedDrop',
      'overflowDrop',
      'oversizeDrop',
      'closeDiscard',
      'queue',
    ])
      for (const unit of ['packets', 'wireBytes'])
        mutations.push((s) => s[direction].queue[field][unit]++);
    mutations.push((s) => (s[direction].queue.forwarded.packets = 0));
    mutations.push((s) => (s[direction].queue.received.wireBytes = NaN));
  }
  for (const mutate of mutations) {
    const s = structuredClone(snapshot);
    mutate(s);
    assert.throws(() => qualifyNativeUplinkProxy(s));
  }
});
test('no-peer proxy shutdown is joined and cannot qualify as a routing proof', async () => {
  const proxy = await createUDPImpairmentProxy({ receiverPort: 9 });
  await proxy.close();
  await proxy.close();
  const s = proxy.snapshot();
  assert.equal(s.closed, true);
  assert.deepEqual(s.errors, []);
  assert.equal(s.forward.pendingPackets, 0);
  assert.equal(s.reverse.pendingPackets, 0);
  assert.throws(() => qualifyNativeUplinkProxy(s));
});
