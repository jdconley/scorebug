# Portable control plane and SRT relay

This Compose stack runs the current native API, persistent SQLite database,
API-managed SRT relay and Caddy HTTPS gateway. A worker can run on this host,
a home GPU machine or another reachable system using the
[worker runbook](../../apps/home-daemon/README.md#linux-cpugpu-deployment).
Native phone and Watch apps use the public HTTPS API; no browser scorer is required.

## Configure and start

Use a dedicated checkout at a recorded revision and Docker Engine with Compose v2.
Run these commands in `infra/vps`:

```sh
umask 077
cp .env.example .env
chmod 600 .env
# Generate four independent values; paste each into the matching field in .env.
openssl rand -hex 32
$EDITOR .env
```

Set `PHONE_TOKEN`, `HOME_TOKEN`, `INTERNAL_TOKEN` and `RELAY_API_PASSWORD` to
independent private values. Empty fields prevent startup. Use your real
`CADDY_DOMAIN` and `INGEST_HOST`, and set `SCOREBUG_RELEASE` to the checked-out
revision. For a production release, pin `CADDY_IMAGE` to a reviewed repository
digest and retain that digest with the configuration. Keep `.env` and its backups
private; do not paste rendered Compose configuration into logs.

Point both DNS names at this host. Allow TCP80/443 for HTTPS and certificate
issuance, and UDP8890 (or `INGEST_PORT`) for native SRT publishing and worker reads.
Keep SSH restricted to your administration network. The API and relay management
ports are not published. Bridge networking works with the explicit SRT UDP mapping;
there is no host-network dependency or shell callback to localhost.

```sh
docker compose build
docker compose up -d
docker compose ps
docker compose logs --tail=100 control-plane mediamtx
curl --fail https://YOUR_API_DOMAIN/healthz
```

The relay is built from the repository's pinned, patched MediaMTX source, matching
local streaming tests. It starts with no media paths. The API creates each selected
broadcast's generation-scoped path and separate SRT publish/read encryption
passphrases, then removes obsolete paths. Management uses a private password
injected through MediaMTX's [documented environment override](https://mediamtx.org/docs/features/configuration).
Launch the relay through Compose so that override is mandatory; do not run the
mounted YAML by itself.

A worker's `CONTROL_PLANE_URL` is the reachable API URL; its `HOME_TOKEN` must match
this installation. Its identity/output must match the native Film setup. The API
advertises `INGEST_HOST:INGEST_PORT` to both phone and worker, so both must reach
that address. Use the worker's `OUTPUT_MODE=rtmp`, `record`, or `rtmp+record` for
broadcast, overlaid MP4, or both. Use a mock destination before a real broadcast.

## Persistence, upgrade and rollback

The `control_data` volume contains `/data/scorebug.sqlite` and its WAL files.
Recreating the API container retains matches, credentials and command receipts.
Keep `PHONE_TOKEN` stable: it also anchors relay path/grant identities.
Caddy certificate state has separate named volumes.

Finish a broadcast before an upgrade. Stop the API, take a consistent backup of
the entire `control_data` volume while stopped, and protect the private `.env`
and Caddy data. Retain the old checkout/image tag and a pre-upgrade database backup.
Use the same Compose project name so the new checkout attaches the same volumes.
Build the new revision and run `docker compose up -d`; verify health and a mock
native broadcast. For rollback, stop the new API, restore the matching database
backup if schema compatibility requires it, restore the old image/configuration,
and restart. Never run old and new APIs against one database simultaneously.

`docker compose down` retains the named volumes. **Do not use `down --volumes` on
an installation whose matches or certificates you need.** This stack does not
back up the phone's local archive or worker output directory; preserve those too.

## Local deployment check and qualification limits

From the repository root:

```sh
node scripts/test-vps-stack.mjs
# Reuse an already built API image:
node scripts/test-vps-stack.mjs --image scorebug/control-plane:YOUR_REVISION
```

This check uses a unique owned Compose project, random private credentials and
loopback-only temporary ports. It checks management authentication, native relay
provisioning, API-container recreation with the same durable match/credential/grant,
and path removal on stop. It removes only that test project's containers/volumes
and retains a result under `artifacts/qa/vps-stack-*`. The maintained relay image
must already exist (build it with the Compose file if needed).

A passing local check establishes deployment wiring and persistence on this Mac's
Linux container runtime. It does not qualify public DNS/TLS/firewalls, other CPU
architectures, GPUs, external hosts or sustained media. Those remain acceptance
steps on each actual destination; no remote deployment is performed by this test.
