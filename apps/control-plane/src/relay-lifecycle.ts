import type { BroadcastSelection } from '@scorebug/protocol';
import { publishAttemptQuery } from './publishing-attempt.js';
import {
  deriveIngestGrant,
  ingestPathPrefix,
  type IngestGrant,
  type IngestRelay,
  type SourceObservation,
} from './ingest.js';

export type RelayDesired = {
  gameId: string;
  generation: number;
  selection: BroadcastSelection;
};
export type PublishRequest = {
  gameId: string;
  deviceId: string;
  recordingId: string;
  generation: number;
  publishingAttemptId?: string;
};
export type PublishAssignment = {
  gameId: string;
  generation: number;
  recordingId: string;
  publishUrl: string;
  publishingAttemptId?: string;
};
export type WorkerIngestAssignment = {
  gameId: string;
  generation: number;
  readUrl: string;
  source: SourceObservation;
};
type Target = { desired: RelayDesired; grant: IngestGrant };
type RelayConfig = { installationSecret: string; host: string; port: number };

export class RelayLifecycleError extends Error {
  constructor(public readonly code: string) {
    super(code);
    this.name = 'RelayLifecycleError';
  }
}

/** Serializes relay I/O; the durable snapshot and relay inventory remain the authorities. */
export class RelayLifecycle {
  private tail: Promise<void> = Promise.resolve();
  private readonly prefix: string;
  private readonly config: RelayConfig;

  constructor(
    private readonly relay: Pick<IngestRelay, 'ensure' | 'remove' | 'status' | 'list'>,
    config: RelayConfig,
    private readonly desired: () => RelayDesired | null,
  ) {
    this.config = { ...config };
    this.prefix = ingestPathPrefix(config.installationSecret);
  }

  private serialized<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.tail.then(operation).catch((error: unknown) => {
      if (error instanceof RelayLifecycleError) throw error;
      // Do not expose remote response bodies, URLs, credentials, or unexpected exception text.
      const code = error instanceof Error ? error.message : '';
      throw new RelayLifecycleError(
        /^(?:relay_(?:unavailable|invalid_response|path_conflict|http_[1-5][0-9]{2})|invalid_(?:relay_path|ingest_credentials|ingest_identity))$/.test(
          code,
        )
          ? code
          : 'relay_unavailable',
      );
    });
    this.tail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  private current(): Target | null {
    const value = this.desired();
    if (!value) return null;
    // A caller may reuse mutable objects; retain the actual identity observed before I/O.
    const desired = { ...value, selection: { ...value.selection } };
    return {
      desired,
      grant: deriveIngestGrant(
        this.config.installationSecret,
        desired.gameId,
        desired.selection,
        desired.generation,
        this.config.host,
        this.config.port,
      ),
    };
  }

  private assertCurrent(target: Target | null): void {
    if (this.current()?.grant.path !== target?.grant.path)
      throw new RelayLifecycleError('broadcast_changed');
  }

  private async removeObsolete(target: Target | null): Promise<void> {
    if (target && this.current()?.grant.path !== target.grant.path)
      await this.relay.remove(target.grant.path);
  }

  private async withTarget<T>(target: Target | null, operation: () => Promise<T>): Promise<T> {
    try {
      const result = await operation();
      this.assertCurrent(target);
      return result;
    } catch (error) {
      // A failed response can follow a successful provision. Revoke it if it became obsolete.
      await this.removeObsolete(target);
      throw error;
    }
  }

  private async reconcileTarget(target: Target | null): Promise<void> {
    this.assertCurrent(target);
    const paths = await this.relay.list(this.prefix);
    this.assertCurrent(target);
    for (const path of paths) {
      // Independently enforce ownership even if the adapter returns a broader inventory.
      if (!path.startsWith(this.prefix) || !/^[a-f0-9]{32}$/.test(path.slice(this.prefix.length)))
        continue;
      this.assertCurrent(target);
      if (path !== target?.grant.path) {
        await this.relay.remove(path);
        this.assertCurrent(target);
      }
    }
    if (target) {
      this.assertCurrent(target);
      await this.relay.ensure(target.grant);
      this.assertCurrent(target);
    }
  }

  reconcile(): Promise<void> {
    return this.serialized(() => {
      const target = this.current();
      return this.withTarget(target, () => this.reconcileTarget(target));
    });
  }

  publish(request: PublishRequest): Promise<PublishAssignment> {
    request = { ...request };
    return this.serialized(() => {
      const target = this.current();
      if (
        !target ||
        target.desired.gameId !== request.gameId ||
        target.desired.generation !== request.generation
      )
        throw new RelayLifecycleError('broadcast_changed');
      if (
        target.desired.selection.captureDeviceId !== request.deviceId ||
        target.desired.selection.recordingId !== request.recordingId
      )
        throw new RelayLifecycleError('capture_not_selected');
      let publishUrl = target.grant.publishUrl;
      if (request.publishingAttemptId !== undefined) {
        // Validate and sign before relay I/O; keep the generation's base grant intact.
        const query = publishAttemptQuery(
          this.config.installationSecret,
          target.grant.path,
          request.publishingAttemptId,
        );
        const url = new URL(publishUrl);
        url.searchParams.set('streamid', `publish:${target.grant.path}:${query}`);
        publishUrl = url.toString();
      }
      return this.withTarget(target, async () => {
        await this.reconcileTarget(target);
        this.assertCurrent(target);
        return {
          gameId: target.desired.gameId,
          generation: target.desired.generation,
          recordingId: target.desired.selection.recordingId,
          publishUrl,
          ...(request.publishingAttemptId !== undefined
            ? { publishingAttemptId: request.publishingAttemptId }
            : {}),
        };
      });
    });
  }

  worker(workerId: string): Promise<WorkerIngestAssignment | null> {
    return this.serialized(async () => {
      const target = this.current();
      if (!target || target.desired.selection.workerId !== workerId) return null;
      return this.withTarget(target, async () => {
        await this.reconcileTarget(target);
        this.assertCurrent(target);
        const source = await this.relay.status(target.grant.path);
        this.assertCurrent(target);
        return {
          gameId: target.desired.gameId,
          generation: target.desired.generation,
          readUrl: target.grant.readUrl,
          source: {
            ready: source.ready,
            inboundBytes: source.inboundBytes,
            tracks: [...source.tracks],
          },
        };
      });
    });
  }
}
