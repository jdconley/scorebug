import test from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { startProbeProcess, stopProbeProcess } from '../capacity-probe-process.mjs';
import { createUDPImpairmentProxy } from '../udp-impairment.mjs';
import { closeMPEGTSProbe } from '../mpegts-probe-cleanup.mjs';

test('artifact failure happens only after both real children join and UDP proxy closes', async (t) => {
  const code = `process.stdout.write(JSON.stringify({kind:'ready',at:1})+'\\n');process.stdin.on('data',()=>process.exit(0));`;
  const owners = [0, 1].map((i) =>
    startProbeProcess(process.execPath, ['-e', code], {
      cwd: process.cwd(),
      role: String(i),
      now: () => 1,
    }),
  );
  t.after(async () => {
    for (const owner of owners) await stopProbeProcess(owner);
  });
  const proxy = await createUDPImpairmentProxy({ receiverPort: 9 });
  t.after(() => proxy.close());
  const end = performance.now() + 3000;
  while (!owners.every((o) => o.rows.length) && performance.now() < end) await delay(5);
  assert(owners.every((o) => !o.closed && !o.failure));
  const failures = await closeMPEGTSProbe(owners, proxy, async () => {
    assert(owners.every((o) => o.closed && o.code === 0));
    assert(proxy.snapshot().closed);
    throw Error('injected ENOSPC artifact write');
  });
  assert.equal(failures.length, 1);
  assert.match(failures[0], /injected ENOSPC/);
});
