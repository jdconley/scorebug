import assert from 'node:assert/strict';
import {
  startProbeProcess,
  requestProbeStop,
  stopProbeProcess,
} from './capacity-probe-process.mjs';
import { createSocket } from 'node:dgram';
import { mkdtemp, readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';
import { randomInt, createHash } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { ownedCommand } from './owned-command.mjs';
import { createUDPImpairmentProxy } from './udp-impairment.mjs';
import { qualifyDatagramTimeline } from './datagram-timeline-qualification.mjs';
import { CapacityProbePolicy } from './capacity-probe-policy.mjs';
assert.equal(process.argv.length, 2, 'No experiment arguments accepted');
const root = fileURLToPath(new URL('..', import.meta.url));
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/capacity-probe-'));
console.log(`Bounded local SRT probe: ${artifact}`);
const now = () => performance.now() / 1000;
const controller = new AbortController();
for (const name of ['SIGINT', 'SIGTERM']) process.once(name, () => controller.abort());
const children = [];
let proxy, error, result;
const runID = randomInt(1, 0xffffffff),
  decisions = [],
  commands = [],
  bridges = {},
  sourceSHA256 = {};
async function command(binary, args, label) {
  const r = await ownedCommand(binary, args, {
    cwd: root,
    signal: controller.signal,
    timeout: 60000,
    maxOutputBytes: 2 * 1024 * 1024,
  });
  await writeFile(join(artifact, label + '.log'), r.stdout + r.stderr);
  assert(r.ok, `${label}: ${r.reason}`);
  return r.stdout;
}
function start(role, port, binary) {
  const owner = startProbeProcess(binary, [role, String(port), String(runID)], {
    cwd: root,
    role,
    now,
  });
  children.push(owner);
  return owner;
}
async function until(predicate, label, seconds = 8) {
  const deadline = now() + seconds;
  while (now() < deadline) {
    assert(!controller.signal.aborted, 'cancelled');
    assert(
      children.every((c) => !c.closed && !c.failure),
      'native owner failed',
    );
    if (predicate()) return;
    await delay(10);
  }
  throw Error(label + ' timeout');
}
function send(owner, line) {
  assert(!owner.closed && !owner.failure);
  owner.child.stdin.write(line + '\n');
}
async function bridge(owner, id = 1) {
  const requestAt = now();
  send(owner, `ping ${id}`);
  await until(() => owner.rows.some((r) => r.kind === 'pong' && r.id === id), 'clock bridge');
  const pong = owner.rows.find((r) => r.kind === 'pong' && r.id === id);
  const low = requestAt - pong.at,
    high = pong.receivedAt - pong.at;
  assert(high >= low && high - low < 0.05, 'Clock bridge too uncertain');
  bridges[id === 1 ? owner.role : `${owner.role}-${id}`] = {
    requestAt,
    nativeAt: pong.at,
    responseAt: pong.receivedAt,
    low,
    high,
    uncertainty: high - low,
  };
  return low; // Earliest possible capture time: conservative freshness, fixed offset.
}
function sample(owner, offset) {
  if (!owner.sample) return null;
  const { receivedAt, ...s } = owner.sample;
  return { ...s, at: s.at + offset };
}
try {
  for (const path of [
    'tools/capacity-probe/srt-probe.cpp',
    'scripts/test-capacity-probe.mjs',
    'scripts/capacity-probe-policy.mjs',
    'scripts/capacity-probe-process.mjs',
    'scripts/owned-command.mjs',
    'scripts/udp-impairment.mjs',
    'scripts/datagram-timeline-qualification.mjs',
  ]) {
    const bytes = await readFile(join(root, path));
    sourceSHA256[path] = createHash('sha256').update(bytes).digest('hex');
    const target = join(artifact, 'source-snapshot', path);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, bytes);
  }
  await writeFile(
    join(artifact, 'source-sha256.json'),
    JSON.stringify(sourceSHA256, null, 2) + '\n',
  );
  const source = await readFile(join(root, 'tools/capacity-probe/srt-probe.cpp'));
  const flags = (await command('pkg-config', ['--cflags', '--libs', 'srt'], 'pkg-config'))
    .trim()
    .split(/\s+/);
  assert(
    flags.every((f) => /^[-A-Za-z0-9_/.+@]+$/.test(f)),
    'Unsupported pkg-config flag quoting',
  );
  const binary = join(artifact, 'srt-probe');
  await command(
    'c++',
    [
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      join(root, 'tools/capacity-probe/srt-probe.cpp'),
      '-o',
      binary,
      ...flags,
    ],
    'build',
  );
  const portSocket = createSocket('udp4');
  await new Promise((resolve, reject) => {
    portSocket.once('error', reject);
    portSocket.bind(0, '127.0.0.1', resolve);
  });
  const port = portSocket.address().port;
  await new Promise((resolve) => portSocket.close(resolve));
  const receiver = start('receiver', port, binary);
  await until(() => receiver.rows.some((r) => r.kind === 'listening'), 'listener');
  proxy = await createUDPImpairmentProxy({
    receiverPort: port,
    forward: { rateBitsPerSecond: 4_000_000, recordTimeline: true },
    reverse: { recordTimeline: true },
    forwardRateSchedule: [
      { atMilliseconds: 0, rateBitsPerSecond: 4_000_000 },
      { atMilliseconds: 12000, rateBitsPerSecond: 12_000_000 },
    ],
  });
  const sender = start('sender', proxy.port, binary);
  await until(
    () => children.every((c) => c.rows.some((r) => r.kind === 'ready')),
    'native connection',
  );
  const senderOffset = await bridge(sender),
    receiverOffset = await bridge(receiver),
    began = now();
  let nextStage = 1;
  const apply = (c) => {
    commands.push({ ...c, at: now() });
    send(sender, `set ${c.stage} ${c.baseBps} ${c.probeBps}`);
    nextStage = c.stage + 1;
  };
  async function attempt() {
    const policy = new CapacityProbePolicy({
      baselineBps: 3_500_000,
      targetBps: 6_000_000,
      stepBps: 250_000,
      startedAt: now(),
      initialStage: nextStage,
      baselineTransport: {
        retransmittedBytes: sender.sample?.retransmittedBytes ?? 0,
        droppedPackets: sender.sample?.droppedPackets ?? 0,
      },
    });
    apply(policy.command);
    let renewedAt = now();
    while (true) {
      assert(!controller.signal.aborted, 'cancelled');
      assert(
        children.every((c) => !c.closed && !c.failure),
        'native owner failed',
      );
      const input = {
        now: now(),
        sender: sample(sender, senderOffset),
        receiver: sample(receiver, receiverOffset),
      };
      const decision = policy.observe(input);
      if (decision) {
        decisions.push({ input, decision });
        apply(decision.command);
        if (decision.kind !== 'set') return decision;
      }
      if (now() - renewedAt >= 0.1) {
        send(sender, `lease ${policy.command.stage}`);
        renewedAt = now();
      }
      await delay(25);
    }
  }
  apply({ stage: nextStage, baseBps: 3_500_000, probeBps: 0 });
  await delay(2000);
  assert(children.every((c) => !c.closed && !c.failure));
  const baselineFirst = receiver.rows.find(
      (r) => r.kind === 'sample' && r.stage === 1 && r.basePackets > 0,
    ),
    baselineLast = receiver.sample;
  assert(baselineFirst && baselineLast.stage === 1 && baselineLast.at - baselineFirst.at >= 1.5);
  const baselineDeliveredBps =
    ((baselineLast.basePackets - baselineFirst.basePackets) * 10880) /
    (baselineLast.at - baselineFirst.at);
  assert(
    baselineDeliveredBps >= 3_500_000 * 0.97 &&
      sender.sample.rttMs <= 50 &&
      sender.sample.bufferMs <= 50,
    'Baseline not established',
  );
  const constrained = await attempt();
  assert.equal(constrained.kind, 'refused');
  assert.equal(constrained.reason, 'transport-pressure');
  assert(
    decisions.at(-1).input.sender.probePayloadBytes > 0 && decisions.at(-1).input.sender.stage >= 2,
    'Refusal must observe an active probe',
  );
  assert(now() - began < 11, 'Constrained refusal must precede independent recovery');
  while (now() - began < 14) {
    assert(!controller.signal.aborted);
    assert(children.every((c) => !c.closed && !c.failure));
    await delay(25);
  }
  assert.equal(receiver.sample.totalMissing, 0);
  assert.equal(receiver.sample.totalDuplicates, 0);
  const recovered = await attempt();
  assert.equal(recovered.kind, 'qualified');
  assert.equal(recovered.offeredAccountedBps, 6_000_000);
  const lastStage = recovered.command.stage;
  await until(
    () => receiver.sample?.stage === lastStage && sender.sample?.stage === lastStage,
    'probe withdrawal',
    2,
  );
  await delay(500);
  assert.equal(receiver.sample.missing, 0);
  assert.equal(receiver.sample.duplicates, 0);
  // Deliberately withhold renewals: native expiry must withdraw only extra load.
  const leaseStage = nextStage;
  apply({ stage: leaseStage, baseBps: 3_500_000, probeBps: 250_000 });
  await until(
    () => sender.sample?.stage === leaseStage && sender.sample.probeLeaseExpired === true,
    'native lease expiry',
    1,
  );
  const expiry = { ...sender.sample };
  await delay(200);
  assert.equal(sender.sample.probePackets, expiry.probePackets);
  assert(sender.sample.basePackets > expiry.basePackets);
  const leaseProof = { expired: expiry, after: sender.sample };
  apply({ stage: nextStage, baseBps: 0, probeBps: 0 });
  await until(
    () =>
      sender.sample.stage === nextStage - 1 &&
      receiver.sample.totalBasePackets === sender.sample.basePackets &&
      receiver.sample.totalProbePackets === sender.sample.probePackets,
    'final delivered messages',
    2,
  );
  assert.equal(receiver.sample.totalMissing, 0);
  assert.equal(receiver.sample.totalDuplicates, 0);
  for (const owner of children) {
    await bridge(owner, 2);
    const a = bridges[owner.role],
      b = bridges[`${owner.role}-2`];
    assert(Math.max(a.low, b.low) <= Math.min(a.high, b.high) + 0.001, 'Native clock bridge drift');
  }
  for (const [path, hash] of Object.entries(sourceSHA256))
    assert.equal(
      createHash('sha256')
        .update(await readFile(join(root, path)))
        .digest('hex'),
      hash,
      'Runtime source changed during experiment',
    );
  result = {
    constrained,
    recovered,
    baselineDeliveredBps,
    leaseProof,
    runID,
    sourceSHA256: createHash('sha256').update(source).digest('hex'),
    nativeVersions: children.map((c) => c.rows.find((r) => r.kind === 'ready').version),
    finalBaseline: receiver.sample,
    scope:
      'One local installed-library SRT connection, synthetic baseline/probe messages. This is delivered-load evidence, not usable video capacity or native media qualification.',
  };
} catch (e) {
  error = String(e.stack ?? e);
} finally {
  // Request both stops before awaiting either connection close.
  for (const owner of children) requestProbeStop(owner);
  for (const owner of children)
    try {
      await stopProbeProcess(owner);
    } catch (e) {
      error ??= String(e);
    }
  if (proxy)
    try {
      await proxy.close();
    } catch (e) {
      error ??= String(e);
    }
  for (const owner of children) {
    await writeFile(
      join(artifact, owner.role + '.json'),
      JSON.stringify(owner.rows, null, 2) + '\n',
    );
    await writeFile(join(artifact, owner.role + '.log'), owner.output + owner.error);
  }
  const transport = proxy?.snapshot();
  if (transport)
    await writeFile(join(artifact, 'proxy.json'), JSON.stringify(transport, null, 2) + '\n');
  if (!error)
    try {
      assert(transport.closed);
      assert.deepEqual(transport.errors, []);
      for (const direction of ['forward', 'reverse']) {
        assert.equal(transport[direction].pendingPackets, 0);
        assert(qualifyDatagramTimeline(transport[direction].queue).complete);
      }
      assert(
        children.every(
          (c) =>
            c.closed &&
            c.code === 0 &&
            !c.failure &&
            c.rows.at(-1).kind === 'finished' &&
            c.rows.at(-1).requestedStop,
        ),
      );
    } catch (e) {
      error = String(e.stack ?? e);
    }
  const output = {
    result,
    error,
    commands,
    decisions,
    bridges,
    cleanup: children.map((c) => ({
      role: c.role,
      closed: c.closed,
      code: c.code,
      failure: c.failure,
    })),
    proxyClosed: transport?.closed ?? null,
  };
  await writeFile(join(artifact, 'result.json'), JSON.stringify(output, null, 2) + '\n');
  console.log(JSON.stringify({ artifact, result, error, cleanup: output.cleanup }, null, 2));
}
if (error) process.exitCode = 1;
