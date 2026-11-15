import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, chmodSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, delimiter } from 'node:path';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';

async function fixture(script, mode, port = '', cwd = process.cwd()) {
  const dir = mkdtempSync(join(tmpdir(), 'scorebug-cleanup-'));
  const binary = join(dir, 'docker');
  const log = join(dir, 'calls.jsonl');
  writeFileSync(
    binary,
    `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.QA_CALLS, JSON.stringify(args) + '\\n');
if (args[0] === 'run' || args.includes('up')) {
  if (process.env.QA_MODE === 'remove-failure') console.log('fixture-started');
  else if (process.env.QA_MODE === 'cancel') { process.kill(process.ppid, 'SIGTERM'); console.log('fixture-started'); }
  else { console.error('fixture startup failed after container creation'); process.exit(1); }
}
if (args[0] === 'inspect') console.log(args.join(' ').includes('State.Running') ? 'true' : process.env.QA_PORT);
if (args[0] === 'rm' && process.env.QA_MODE === 'remove-failure') { console.error('fixture removal failed'); process.exit(1); }
`,
  );
  chmodSync(binary, 0o755);
  try {
    const result = await new Promise((resolve) => {
      const child = spawn(
        process.execPath,
        [
          ...(script.includes('relay')
            ? [join(process.cwd(), 'apps/control-plane/node_modules/tsx/dist/cli.mjs')]
            : []),
          join(process.cwd(), script),
          ...(script.includes('container') ? ['--image', 'qa-existing-image'] : []),
        ],
        {
          cwd,
          env: {
            ...process.env,
            PATH: `${dir}${delimiter}${process.env.PATH}`,
            QA_CALLS: log,
            QA_MODE: mode,
            QA_PORT: String(port),
          },
          stdio: 'ignore',
          timeout: 10_000,
        },
      );
      child.on('close', (code, signal) => resolve({ code, signal }));
    });
    const calls = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
    return { ...result, calls };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test('container startup failure still removes the uniquely owned container', async () => {
  const result = await fixture('scripts/test-container.mjs', 'partial');
  assert.equal(result.code, 1);
  assert.ok(
    result.calls.some((args) => args[0] === 'rm' && args[2].startsWith('scorebug-qa-api-')),
  );
});

test('successful HTTP checks cannot hide a failed container cleanup', async () => {
  let requests = 0;
  const server = createServer((request, response) => {
    requests++;
    response.writeHead(request.url === '/healthz' ? 200 : 401, {
      'Content-Type': 'application/json',
    });
    response.end(JSON.stringify({ ok: true }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const result = await fixture(
      'scripts/test-container.mjs',
      'remove-failure',
      server.address().port,
    );
    assert.equal(requests, 2);
    assert.equal(result.code, 1);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('relay startup failure still removes its uniquely owned container', async () => {
  const result = await fixture('scripts/test-relay.mjs', 'partial');
  assert.equal(result.code, 1);
  assert.ok(result.calls.some((args) => args[0] === 'rm' && args[2].startsWith('scorebug-relay-')));
});

test('relay validation loads its fixture when invoked from the control-plane workspace', async () => {
  const result = await fixture(
    'scripts/test-relay.mjs',
    'partial',
    '',
    join(process.cwd(), 'apps/control-plane'),
  );
  assert.equal(result.code, 1);
  assert.ok(result.calls.some((args) => args[0] === 'run'));
  assert.ok(result.calls.some((args) => args[0] === 'rm' && args[2].startsWith('scorebug-relay-')));
});

for (const script of [
  'scripts/test-container.mjs',
  'scripts/test-local.mjs',
  'scripts/test-relay.mjs',
]) {
  test(`${script} handles cancellation with owned teardown`, async () => {
    const result = await fixture(script, 'cancel');
    assert.equal(
      result.signal,
      null,
      'Runner must handle the signal instead of exiting immediately',
    );
    assert.equal(result.code, 1);
    assert.ok(result.calls.some((args) => args[0] === 'rm' || args.includes('down')));
  });
}
