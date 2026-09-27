# VPS deploy — legacy template

This stack is **not ready for the current durable native workflow as checked in**.
It has no persistent control-plane database volume or explicit `DATABASE_PATH`,
passes no `RELAY_API_*` management settings, and its MediaMTX file disables the API
and uses old `game_*` paths. Its host-network hook calls `127.0.0.1:8787` while the
control-plane port is only exposed inside the Compose bridge. Do not infer working
native credentials, restart recovery or private management from `compose up`.

Use the maintained local relay configuration and native tests as repair references;
do not expose their public fixture credentials. Native deployment needs a durable
SQLite mount, authenticated private relay management, reachable API/relay endpoints,
current generation-bound native paths, pinned images and verified TLS/firewall rules.
The commands below describe the old layout only. See the
[Linux worker runbook](../../apps/home-daemon/README.md#linux-cpugpu-deployment)
for current worker-only CPU/GPU packaging and its explicit qualification limits.

Drop this directory onto the VPS, fill in `.env`, and run.

```sh
# On the VPS, in this directory
cp .env.example .env
$EDITOR .env

docker compose pull
docker compose build
docker compose up -d

docker compose logs -f control-plane
```

## What runs

| Service         | Image                 | Network  | Ports           |
| --------------- | --------------------- | -------- | --------------- |
| `caddy`         | `caddy:2-alpine`      | bridge   | 80, 443 (host)  |
| `control-plane` | built from repo       | bridge   | 8787 (internal) |
| `mediamtx`      | `bluenviron/mediamtx` | **host** | 8890/udp (SRT)  |

## DNS

Point these at the VPS public IP before you bring up Caddy (or it can't fetch certs):

- `api.scorebug.live` → A record
- `ingest.scorebug.live` → A record (same IP)

## Firewall

UFW or Hetzner Cloud firewall must allow:

| Port | Proto | Purpose                          |
| ---- | ----- | -------------------------------- |
| 22   | tcp   | SSH                              |
| 80   | tcp   | HTTP (Caddy redirect to HTTPS)   |
| 443  | tcp   | HTTPS (control plane API)        |
| 8890 | udp   | SRT (iPhone publish + home pull) |

## Updating

```sh
git pull
docker compose build control-plane
docker compose up -d control-plane
```

Caddy and MediaMTX update with `docker compose pull && docker compose up -d`.
