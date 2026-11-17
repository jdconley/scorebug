# Server stack

This directory holds the Compose stack for a self-hosted Scorebug server: Caddy
(HTTPS), the control plane API (SQLite) and the MediaMTX SRT relay, plus an optional
broadcast worker for the all-in-one topology. The hosted service at scorebug.live
does not use it.

Start it with the installer from the repository root, not by hand. The installer
writes `.env`, builds the images, starts the services and checks health:

```sh
infra/install.sh
```

Both topologies, DNS, firewall, upgrades, backups, rotating secrets and
troubleshooting are in [Self-hosting](../../docs/self-hosting.md).

| File                 | Purpose                                                                  |
| -------------------- | ------------------------------------------------------------------------ |
| `docker-compose.yml` | Caddy, API and relay; `--profile worker` adds the all-in-one worker      |
| `Caddyfile`          | HTTPS reverse proxy for `CADDY_DOMAIN` to the API                        |
| `mediamtx.yml`       | Relay config; Compose injects the management password                    |
| `.env.example`       | Documents the keys `install.sh` writes to `.env` (mode 0600, not in Git) |

The relay image is built from [`vendor/MediaMTX`](../../vendor/MediaMTX/README.md),
the API image from `apps/control-plane/Dockerfile` and the worker image from
`apps/home-daemon/Dockerfile`.

Only Caddy (TCP 80, TCP and UDP 443) and the relay (UDP 8890) publish ports. The API
(8787) and the relay management API (9997) stay on the private Compose network. In
the split topology the installer also writes `worker.env` here, for the home
machine.

`node scripts/test-vps-stack.mjs` checks this wiring with throwaway credentials: no
published management ports, API data that survives recreating the container, and
relay paths created and removed with a broadcast. CI runs it.
