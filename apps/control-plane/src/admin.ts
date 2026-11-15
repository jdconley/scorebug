/** Admin commands behind cli.ts. They print no secrets except the setup link asked for. */
import { parseArgs } from 'node:util';
import { setupLink } from '@scorebug/protocol';
import { MatchStore } from './matches-store.js';
import { renderQr } from './qr.js';
import { rtmpUrlSchema, streamKeySchema } from './routes/account.js';

const usage = `Usage: cli.js <command> [options]

  setup-link [--server URL] [--hours N] [--qr ansi|plain|none]
      Mint a one-time phone setup link (default: expires in 24 hours) and print
      it with a QR code. Text the link to yourself and open it on the phone.
  devices                       List owner phones.
  revoke-device ID              Revoke an owner phone's credential.
  destinations                  List streaming destinations (stream keys hidden).
  seed-destination --name NAME [--replace]
      Read a full RTMP(S) URL including the stream key from stdin and save it
      as the default destination, unless any destination already exists. With
      --replace, update the default destination's URL and key instead.

Environment: DATABASE_PATH, PHONE_TOKEN, PUBLIC_URL (default for --server).`;

function fail(message: string): never {
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

function openStore(): MatchStore {
  const token = process.env.PHONE_TOKEN;
  if (!token || token.length < 16) fail('PHONE_TOKEN is not set (run this inside the container)');
  return new MatchStore(process.env.DATABASE_PATH ?? 'data/scorebug.sqlite', token);
}

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString('utf8').trim();
}

/** Split `rtmps://host/app/KEY` into the server URL and the stream key (the last path segment). */
export function splitOutputUrl(value: string): { rtmpUrl: string; streamKey: string } | null {
  const query = value.indexOf('?');
  const path = query === -1 ? value : value.slice(0, query);
  const slash = path.lastIndexOf('/');
  if (slash < 0 || path.slice(0, slash).endsWith('/')) return null;
  const rtmpUrl = value.slice(0, slash);
  const streamKey = value.slice(slash + 1);
  return rtmpUrlSchema.safeParse(rtmpUrl).success && streamKeySchema.safeParse(streamKey).success
    ? { rtmpUrl, streamKey }
    : null;
}

export async function main(argv: string[]): Promise<void> {
  const [command, ...rest] = argv;
  if (!command || command === '-h' || command === '--help') {
    process.stdout.write(`${usage}\n`);
    return;
  }
  if (command === 'setup-link') {
    const { values } = parseArgs({
      args: rest,
      options: {
        server: { type: 'string' },
        hours: { type: 'string', default: '24' },
        qr: { type: 'string', default: 'ansi' },
      },
    });
    const server = (values.server ?? process.env.PUBLIC_URL ?? '').replace(/\/+$/, '');
    if (!/^https?:\/\/[^\s/?#]+(\/[^\s?#]*)?$/.test(server))
      fail('give --server https://your.domain (or set PUBLIC_URL)');
    const hours = Number(values.hours);
    if (!Number.isInteger(hours) || hours < 1 || hours > 720) fail('--hours must be 1-720');
    if (!['ansi', 'plain', 'none'].includes(values.qr)) fail('--qr must be ansi, plain or none');
    const store = openStore();
    try {
      const { code, expiresAt } = store.account.mintSetupCode(hours * 3_600_000);
      const link = setupLink(server, code);
      if (values.qr !== 'none') process.stdout.write(`${renderQr(link, values.qr as 'ansi')}\n\n`);
      process.stdout.write(`${link}\n\nOne phone, one use, expires ${expiresAt}.\n`);
    } finally {
      store.close();
    }
    return;
  }
  const store = openStore();
  try {
    if (command === 'devices') {
      for (const d of store.account.listDevices())
        process.stdout.write(
          `${d.id}  ${d.revokedAt ? 'revoked' : 'active '}  ${d.name}  last seen ${d.lastSeenAt ?? 'never'}\n`,
        );
    } else if (command === 'revoke-device') {
      const id = rest[0] ?? fail('give the device ID (see `devices`)');
      const device = store.account.revokeDevice(id);
      process.stdout.write(`revoked ${device.id} (${device.name})\n`);
    } else if (command === 'destinations') {
      for (const d of store.account.listDestinations())
        process.stdout.write(
          `${d.id}  ${d.isDefault ? 'default' : '       '}  ${d.name}  ${d.rtmpUrl}  key …${d.streamKeyLast4}\n`,
        );
    } else if (command === 'seed-destination') {
      const { values } = parseArgs({
        args: rest,
        options: { name: { type: 'string' }, replace: { type: 'boolean', default: false } },
      });
      const name = values.name?.trim() || fail('give --name');
      const parts = splitOutputUrl(await readStdin());
      if (!parts) fail('stdin must be an rtmp:// or rtmps:// URL ending in the stream key');
      const current = store.account.defaultDestinationId();
      if (values.replace && current) {
        store.account.updateDestination(current, parts);
        process.stdout.write(`updated the default destination (${current})\n`);
        return;
      }
      if (store.account.listDestinations().length > 0) {
        process.stdout.write('destination exists; left unchanged\n');
        return;
      }
      const destination = store.account.createDestination({ name, ...parts, isDefault: true });
      process.stdout.write(`seeded destination "${destination.name}" (${destination.id})\n`);
    } else fail(`unknown command ${command}\n\n${usage}`);
  } finally {
    store.close();
  }
}
