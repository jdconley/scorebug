import { createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import type {
  Destination,
  DestinationCreate,
  DestinationUpdate,
  Device,
  SetupRedeemRequest,
} from '@scorebug/protocol';
import { canonical } from './canonical-json.js';
import type { SqlDb } from './sql.js';

export class AccountStoreError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

type Dependencies = {
  transaction: <T>(body: () => T) => T;
  now: () => number;
  /** True when the active match streams to this destination. */
  destinationInUse: (id: string) => boolean;
};
type DeviceRow = {
  id: string;
  name: string;
  role: 'owner';
  token_hash: string;
  created_at: number;
  last_seen_at: number | null;
  revoked_at: number | null;
};
type CodeRow = {
  code_hash: string;
  expires_at: number;
  redeemed_at: number | null;
  device_id: string | null;
};
type DestinationRow = {
  id: string;
  name: string;
  rtmp_url: string;
  stream_key: string;
  is_default: number;
  created_at: number;
  updated_at: number;
};

export const SETUP_CODE_TTL_MS = 24 * 60 * 60 * 1000;
/** A phone that lost the redeem response may repeat it with the same device ID for this long. */
const SETUP_RETRY_MS = 10 * 60 * 1000;
const LAST_SEEN_RESOLUTION_MS = 60 * 1000;
const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString());
const sha256 = (value: string) => createHash('sha256').update(value).digest('hex');
const sameHex = (a: string, b: string) =>
  a.length === b.length && timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'));

/**
 * Owner devices, one-time setup codes and streaming destinations. Shares the
 * match database and its transactions. Only hashes of codes and device tokens
 * are stored; stream keys are stored because the worker needs them, and are
 * never returned by the API.
 */
export class AccountStore {
  private readonly key: Buffer;
  constructor(
    private readonly db: SqlDb,
    private readonly deps: Dependencies,
  ) {
    const row = db.get("SELECT value FROM server_keys WHERE name='hmac'") as {
      value: string;
    };
    this.key = Buffer.from(row.value, 'base64url');
  }

  static migrate(db: SqlDb): void {
    db.exec(`
      CREATE TABLE IF NOT EXISTS server_keys(name TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS setup_codes(code_hash TEXT PRIMARY KEY, created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL, redeemed_at INTEGER, device_id TEXT);
      CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL, last_seen_at INTEGER, revoked_at INTEGER);
      CREATE TABLE IF NOT EXISTS destinations(id TEXT PRIMARY KEY, name TEXT NOT NULL, rtmp_url TEXT NOT NULL,
        stream_key TEXT NOT NULL, is_default INTEGER NOT NULL DEFAULT 0 CHECK(is_default IN (0,1)),
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
    `);
    db.run(
      "INSERT OR IGNORE INTO server_keys(name,value) VALUES('hmac',?)",
      randomBytes(32).toString('base64url'),
    );
  }

  /** Keyed hash for short or low-entropy codes, so a copied database does not reveal them. */
  codeHash(purpose: string, code: string): string {
    return createHmac('sha256', this.key)
      .update(canonical([purpose, code]))
      .digest('hex');
  }

  // ------------------------------------------------------------ setup codes

  mintSetupCode(ttlMs = SETUP_CODE_TTL_MS): { code: string; expiresAt: string } {
    if (!Number.isSafeInteger(ttlMs) || ttlMs < 60_000 || ttlMs > 30 * SETUP_CODE_TTL_MS)
      throw new AccountStoreError('invalid_ttl');
    return this.deps.transaction(() => {
      const now = this.deps.now();
      // Unredeemed codes are useless a week after expiry; redeemed rows keep the retry receipt.
      this.db.run(
        'DELETE FROM setup_codes WHERE redeemed_at IS NULL AND expires_at < ?',
        now - 7 * SETUP_CODE_TTL_MS,
      );
      const code = randomBytes(18).toString('base64url');
      const expiresAt = now + ttlMs;
      this.db.run(
        'INSERT INTO setup_codes(code_hash,created_at,expires_at) VALUES(?,?,?)',
        this.codeHash('setup-code', code),
        now,
        expiresAt,
      );
      return { code, expiresAt: new Date(expiresAt).toISOString() };
    });
  }

  private deviceToken(deviceId: string, codeHash: string): string {
    return createHmac('sha256', this.key)
      .update(canonical(['scorebug-device-credential-v1', deviceId, codeHash]))
      .digest('base64url');
  }

  redeemSetupCode(input: SetupRedeemRequest): { device: Device; token: string } {
    return this.deps.transaction(() => {
      const now = this.deps.now();
      const hash = this.codeHash('setup-code', input.code);
      const row = this.db.get('SELECT * FROM setup_codes WHERE code_hash=?', hash) as
        | CodeRow
        | undefined;
      if (!row || !sameHex(row.code_hash, hash)) throw new AccountStoreError('setup_code_invalid');
      if (row.redeemed_at !== null) {
        const device = this.deviceRow(row.device_id ?? '');
        const token = this.deviceToken(input.deviceId, row.code_hash);
        if (
          row.device_id === input.deviceId &&
          now - row.redeemed_at < SETUP_RETRY_MS &&
          device &&
          device.revoked_at === null &&
          sameHex(device.token_hash, sha256(token))
        )
          return { device: deviceView(device), token };
        throw new AccountStoreError('setup_code_used');
      }
      if (now >= row.expires_at) throw new AccountStoreError('setup_code_expired');
      if (this.deviceRow(input.deviceId)) throw new AccountStoreError('device_id_taken');
      const token = this.deviceToken(input.deviceId, row.code_hash);
      this.db.run(
        "INSERT INTO devices(id,name,role,token_hash,created_at,last_seen_at) VALUES(?,?,'owner',?,?,?)",
        input.deviceId,
        input.deviceName,
        sha256(token),
        now,
        now,
      );
      this.db.run(
        'UPDATE setup_codes SET redeemed_at=?,device_id=? WHERE code_hash=?',
        now,
        input.deviceId,
        row.code_hash,
      );
      return { device: deviceView(this.deviceRow(input.deviceId)!), token };
    });
  }

  // ---------------------------------------------------------------- devices

  private deviceRow(id: string): DeviceRow | undefined {
    return this.db.get('SELECT * FROM devices WHERE id=?', id) as DeviceRow | undefined;
  }

  /** Owner device for a bearer token, or undefined (unknown or revoked). */
  authenticateDevice(token: string): Device | undefined {
    if (!token) return undefined;
    const row = this.db.get(
      'SELECT * FROM devices WHERE token_hash=? AND revoked_at IS NULL',
      sha256(token),
    ) as DeviceRow | undefined;
    if (!row) return undefined;
    const now = this.deps.now();
    if (row.last_seen_at === null || now - row.last_seen_at >= LAST_SEEN_RESOLUTION_MS) {
      this.db.run('UPDATE devices SET last_seen_at=? WHERE id=?', now, row.id);
      row.last_seen_at = now;
    }
    return deviceView(row);
  }

  listDevices(): Device[] {
    return (this.db.all('SELECT * FROM devices ORDER BY created_at, rowid') as DeviceRow[]).map(
      deviceView,
    );
  }

  revokeDevice(id: string): Device {
    return this.deps.transaction(() => {
      const row = this.deviceRow(id);
      if (!row) throw new AccountStoreError('device_not_found');
      if (row.revoked_at === null)
        this.db.run('UPDATE devices SET revoked_at=? WHERE id=?', this.deps.now(), id);
      return deviceView(this.deviceRow(id)!);
    });
  }

  // ----------------------------------------------------------- destinations

  private destinationRow(id: string): DestinationRow | undefined {
    return this.db.get('SELECT * FROM destinations WHERE id=?', id) as DestinationRow | undefined;
  }

  listDestinations(): Destination[] {
    return (
      this.db.all('SELECT * FROM destinations ORDER BY created_at, rowid') as DestinationRow[]
    ).map(destinationView);
  }

  getDestination(id: string): Destination | undefined {
    const row = this.destinationRow(id);
    return row ? destinationView(row) : undefined;
  }

  /** The destination new matches use when they name none. */
  defaultDestinationId(): string | null {
    const row = this.db.get('SELECT id FROM destinations WHERE is_default=1') as
      | { id: string }
      | undefined;
    return row?.id ?? null;
  }

  createDestination(input: DestinationCreate): Destination {
    return this.deps.transaction(() => {
      const now = this.deps.now();
      const id = randomUUID();
      const { count } = this.db.get('SELECT COUNT(*) AS count FROM destinations') as {
        count: number;
      };
      if (count >= 32) throw new AccountStoreError('destination_limit');
      const isDefault = input.isDefault === true || this.defaultDestinationId() === null;
      if (isDefault) this.db.exec('UPDATE destinations SET is_default=0');
      this.db.run(
        'INSERT INTO destinations(id,name,rtmp_url,stream_key,is_default,created_at,updated_at) VALUES(?,?,?,?,?,?,?)',
        id,
        input.name,
        input.rtmpUrl,
        input.streamKey,
        isDefault ? 1 : 0,
        now,
        now,
      );
      return destinationView(this.destinationRow(id)!);
    });
  }

  updateDestination(id: string, patch: DestinationUpdate): Destination {
    return this.deps.transaction(() => {
      const row = this.destinationRow(id);
      if (!row) throw new AccountStoreError('destination_not_found');
      if (patch.isDefault === true) this.db.exec('UPDATE destinations SET is_default=0');
      this.db.run(
        'UPDATE destinations SET name=?,rtmp_url=?,stream_key=?,is_default=?,updated_at=? WHERE id=?',
        patch.name ?? row.name,
        patch.rtmpUrl ?? row.rtmp_url,
        patch.streamKey ?? row.stream_key,
        patch.isDefault === undefined ? row.is_default : patch.isDefault ? 1 : 0,
        this.deps.now(),
        id,
      );
      return destinationView(this.destinationRow(id)!);
    });
  }

  deleteDestination(id: string): void {
    this.deps.transaction(() => {
      if (!this.destinationRow(id)) throw new AccountStoreError('destination_not_found');
      if (this.deps.destinationInUse(id)) throw new AccountStoreError('destination_in_use');
      this.db.run('DELETE FROM destinations WHERE id=?', id);
    });
  }

  /** Internal, worker only: the full RTMP URL including the stream key. */
  publishUrl(id: string): string | null {
    const row = this.destinationRow(id);
    return row ? `${row.rtmp_url.replace(/\/+$/, '')}/${row.stream_key}` : null;
  }
}

function deviceView(row: DeviceRow): Device {
  return {
    id: row.id,
    name: row.name,
    role: row.role,
    createdAt: iso(row.created_at)!,
    lastSeenAt: iso(row.last_seen_at),
    revokedAt: iso(row.revoked_at),
  };
}

function destinationView(row: DestinationRow): Destination {
  return {
    id: row.id,
    name: row.name,
    rtmpUrl: row.rtmp_url,
    // Short keys would be mostly revealed by their last four characters.
    streamKeyLast4: row.stream_key.length >= 8 ? row.stream_key.slice(-4) : '',
    isDefault: row.is_default === 1,
    createdAt: iso(row.created_at)!,
    updatedAt: iso(row.updated_at)!,
  };
}
