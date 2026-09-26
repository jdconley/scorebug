# Publisher-only ingest address implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development task by task, with independent specification then quality review.

**Goal:** Let the ordinary native app upload through a separately configured SRT endpoint while its proxy worker reads directly from the relay.

**Architecture:** Optional paired server configuration flows through `createApp` and `RelayLifecycle` to `deriveIngestGrant`. Only the publish URL authority changes; credentials, path identity, URL options and worker read URL retain current behavior. The [ordinary recovery design](../specs/2026-09-25-ordinary-recovery-design.md) defines the later integration and media gates.

**Tech stack:** TypeScript, Zod, Hono, Vitest; existing SRT grants.

## Contract and files

- `apps/control-plane/src/config.ts`: add optional `INGEST_PUBLISH_HOST` and `INGEST_PUBLISH_PORT`. Require both or neither; reject empty host, host URL/userinfo/path/query/fragment/whitespace, invalid ports including0/fraction/>65535. Accept ordinary DNS, IPv4 and rawIPv6. Preserve absent defaults and unrelated settings.
- `apps/control-plane/src/ingest.ts`: add optional final endpoint argument `{ host: string; port: number }` to `deriveIngestGrant`, after existing pacing argument. Validate direct callers before URL construction and use it only for action `publish`. Avoid duplicated host rules between config and derivation by extracting a small pure validator if necessary.
- `apps/control-plane/src/relay-lifecycle.ts`: accept/copy the endpoint in configuration and forward it. Caller mutation after construction cannot retarget grants.
- `apps/control-plane/src/app.ts`: pass the paired configuration into the normal native relay lifecycle. Legacy `/games` behavior is outside this native-only change; document that explicitly.
- Tests: `test/config.test.ts`, `test/ingest.test.ts`, `test/relay-lifecycle.test.ts` and an existing native API test fixture. Test normal API wiring, not only the helper in isolation.
- Operator documentation: add the pair/default/native-grant scope to existing control-plane configuration guidance, using literal example addresses and no credentials.

## Steps

- [ ] Add failing tests: absent config; valid pair; partial/invalid pair; default grant unchanged; override changes only publisher authority; reader URL/path/passphrases unchanged; IPv6 URL brackets; same options and attempt attestation; normal API dependency wiring; constructor snapshot survives caller mutation.
- [ ] Run focused Vitest tests, retain a behavioral failure from the unwired override (not only compile failure).
- [ ] Implement the optional configuration path without changing client controllers, capture, relay provisioning or credential generation.
- [ ] Run focused tests and complete control-plane tests/typecheck; retain command/count/exit evidence. Suggested commands: `pnpm --filter @scorebug/control-plane test` and `pnpm --filter @scorebug/control-plane typecheck`.
- [ ] Run independent specification review, then quality review. Resolve concrete findings, rerun affected checks and retain final exact source blob IDs.
- [ ] Commit reviewed source/tests/documentation and update the session log/current plan. This component pass does not claim real congestion or media qualification.

## Representative assertions

```ts
const baseline = deriveIngestGrant(secret, gameId, selection, 1, 'relay.internal', 8890);
const redirected = deriveIngestGrant(secret, gameId, selection, 1,
  'relay.internal', 8890, undefined, undefined, { host: 'upload.example', port: 18890 });
expect(new URL(redirected.publishUrl).host).toBe('upload.example:18890');
expect(redirected.readUrl).toBe(baseline.readUrl);
expect(redirected.path).toBe(baseline.path);
expect(redirected.publishPassphrase).toBe(baseline.publishPassphrase);
expect(redirected.readPassphrase).toBe(baseline.readPassphrase);
```

Existing tests supply actual secret/selection fixtures. Use the normal authenticated
native capture/worker endpoints for the integration regression, ensuring the
phone receives the overridden publisher URL while the selected worker receives
the baseline read URL. Preserve current authorization and error redaction tests.
