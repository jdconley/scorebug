# Server stack

This directory holds the Compose stack for a self-hosted Scorebug server:
Caddy (HTTPS), the control plane API (SQLite) and the patched MediaMTX SRT
relay, plus an optional worker for the all-in-one topology.

Do not edit `.env` by hand or start this stack directly the first time. Run the
installer from the repository root; it generates the secrets, builds the images,
starts everything and checks health:

```sh
infra/install.sh
```

Everything else (both topologies, DNS, firewall, upgrades, backups, rotating
secrets, troubleshooting) is in [docs/self-hosting.md](../../docs/self-hosting.md).

| File                 | Purpose                                                            |
| -------------------- | ------------------------------------------------------------------ |
| `docker-compose.yml` | Caddy + API + relay; `--profile worker` adds the all-in-one worker |
| `Caddyfile`          | HTTPS reverse proxy for `CADDY_DOMAIN`                             |
| `mediamtx.yml`       | Relay config; the management password is injected by Compose       |
| `.env.example`       | Documents the keys `install.sh` writes to `.env` (mode 0600)       |

Only TCP 80/443 and UDP 8890 are published. The API (8787) and relay management
API (9997) stay on the private Compose network. `node scripts/test-vps-stack.mjs`
checks that wiring, API persistence across container recreation, and relay path
provisioning with throwaway credentials.
