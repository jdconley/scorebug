# VPS deploy

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
