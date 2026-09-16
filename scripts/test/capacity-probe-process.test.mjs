import test from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { startProbeProcess, stopProbeProcess } from '../capacity-probe-process.mjs';
const code = `process.stdout.write(JSON.stringify({kind:'ready',at:1})+'\\n');process.stdin.on('data',data=>{if(String(data).includes('stop')){process.stdout.write(JSON.stringify({kind:'finished',requestedStop:true,at:2})+'\\n');process.exit(0);}});`;
async function owner(t) {
  const o = startProbeProcess(process.execPath, ['-e', code], {
    role: 'fixture',
    cwd: process.cwd(),
    now: () => performance.now() / 1000,
  });
  t.after(() => stopProbeProcess(o));
  const end = performance.now() + 2000;
  while (!o.rows.length && !o.closed && performance.now() < end) await delay(5);
  assert.equal(o.rows[0]?.kind, 'ready');
  return o;
}
for (const pipe of ['stdout', 'stderr', 'stdin'])
  test(`${pipe} error is latched, kills and joins the owned child`, async (t) => {
    const o = await owner(t);
    o.child[pipe].emit('error', new Error('injected ' + pipe));
    await stopProbeProcess(o);
    assert(o.closed);
    assert.match(o.failure, new RegExp('injected ' + pipe));
    assert(o.code !== 0);
  });
test('explicit stop joins once and remains idempotent', async (t) => {
  const o = await owner(t);
  await stopProbeProcess(o);
  await stopProbeProcess(o);
  assert(o.closed);
  assert.equal(o.code, 0);
  assert.equal(o.failure, null);
  assert.equal(o.rows.at(-1).kind, 'finished');
});
