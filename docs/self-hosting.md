# Self-hosting Scorebug

[scorebug.live](https://scorebug.live) is the hosted Scorebug: sign in from the app
and there is nothing to install. This guide is for running your own server instead.

> **The current iPhone app does not work with a self-hosted server.** The app signs
> in with Google and uses team routes that only the hosted service serves; it no
> longer opens the setup links this server prints. The server, relay and worker
> below still build and pass CI, and you can test them without a phone
> ([Test without a phone](#test-without-a-phone)), but no phone can film to them.

You need a Linux machine with Docker, a domain name, and a YouTube stream key. No
Scorebug account or paid service is involved. One installer script sets everything
up.

## How it fits together

```
iPhone ──SRT (UDP 8890)──▶ relay ──SRT──▶ worker ──RTMPS──▶ YouTube
   │                                         │
   └──HTTPS (TCP 443)──▶ Caddy ─▶ API ◀──────┘ (HTTPS, worker polls)
```

- **API** (control plane): keeps matches and scores in a SQLite file and hands
  out short-lived SRT credentials.
- **Relay** (MediaMTX, built from `vendor/MediaMTX`): receives the phone's video
  over SRT. The API manages it through a management port that is never exposed.
- **Caddy**: HTTPS in front of the API, with an automatic Let's Encrypt
  certificate.
- **Worker** (the broadcast worker, `apps/home-daemon`): pulls the video from the
  relay, burns in the scorebug with FFmpeg and pushes it to YouTube. It only makes
  outbound connections. See [its README](../apps/home-daemon/README.md).

The phone has to reach the relay from any gym, so the API and relay need a public
address. The worker can run next to them or at home.

## Pick a topology

|                       | All-in-one                 | Split                                        |
| --------------------- | -------------------------- | -------------------------------------------- |
| Where the worker runs | Same server                | A machine at home (Linux Docker or macOS)    |
| Server size           | Enough CPU to encode video | The smallest VPS is fine                     |
| Home network          | Not involved               | Outbound connections only; open no ports     |
| Good for              | One box, simplest setup    | A small VPS plus a home machine that encodes |

You can switch later by re-running the installer with the other `--topology`.

### CPU for the worker

The self-hosted worker encodes in software with x264 (`veryfast`). It decodes the
phone's stream, scales it, draws the scorebug and re-encodes it, all in real time.
As a starting point for all-in-one, plan on at least 2 vCPU for `720p30` (the
installer's default) and 4 vCPU, preferably dedicated, for `1080p30`. If the stream
stutters or the worker falls behind, use a smaller profile, a bigger server, or the
split topology.

While live, the server receives the phone's stream and sends a stream out: to
YouTube (all-in-one) or to the home worker (split). Budget roughly twice the
stream bitrate.

## Prerequisites

1. **A Linux host with a public IP.** A VPS, or a home machine where your
   router forwards TCP 443 (plus TCP 80 for the certificate) and UDP 8890 to it.
2. **Docker Engine with the Compose plugin** (`docker compose version` works).
   Install from <https://docs.docker.com/engine/install/>. Run the installer as a
   user that can use Docker.
3. **A domain name** you control, for example `scorebug.example.com`. A free
   dynamic DNS name works for a home box. An IP address alone does not: phones
   need a trusted HTTPS certificate.
4. **A YouTube stream key.** In YouTube Studio choose _Go live → Stream_. Copy
   the _Stream URL_ and _Stream key_.
5. **A Git checkout of this repository** on the server (`git clone`), plus `curl`
   for the health checks.

## DNS

Create one DNS record pointing your domain at the server:

```
scorebug.example.com.  A     203.0.113.10      ; your server's IPv4
scorebug.example.com.  AAAA  2001:db8::10      ; optional, only if it has IPv6
```

The same name is used for the HTTPS API and the SRT relay. Create the record
before installing; Caddy needs it to get a certificate.

## Firewall

| Port | Protocol | Who connects        | Why                                                 |
| ---- | -------- | ------------------- | --------------------------------------------------- |
| 80   | TCP      | Let's Encrypt       | Certificate issuance and renewal, redirect to HTTPS |
| 443  | TCP      | Phones, home worker | HTTPS API                                           |
| 8890 | UDP      | Phones, home worker | SRT video in (phone) and out (home worker)          |
| 22   | TCP      | You                 | SSH; restrict to your own addresses if you can      |

Nothing else needs to be open. Caddy also listens on UDP 443 for HTTP/3; opening it
is optional. The API (8787) and relay management (9997) ports stay on Docker's
private network. A home worker needs no inbound ports.

With `ufw`, for example:

```bash
sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw allow 8890/udp
```

Also allow these in your cloud provider's firewall if it has one.

## Install: all-in-one

From the checkout on the server:

```bash
infra/install.sh
```

It asks three things: the topology (choose 1), your domain, and the YouTube
Stream URL and key (the key is not echoed). Then it:

1. checks Docker and Compose,
2. writes `infra/vps/.env` with mode `0600`, including three independent 256-bit
   secrets from `/dev/urandom` (`SERVER_SECRET`, `HOME_TOKEN`,
   `RELAY_API_PASSWORD`),
3. builds the images from this checkout (several minutes the first time),
4. starts Caddy, the API, the relay and the worker,
5. waits until `https://your-domain/healthz` answers through Caddy and the worker
   reports healthy,
6. saves the YouTube URL and key as the default streaming destination
   ("YouTube"),
7. prints a one-time phone setup link (with a QR code) and next steps.

For scripts or automation, pass everything as flags (or `SCOREBUG_*`
environment variables) and add `--yes` so it never prompts:

```bash
infra/install.sh --yes --topology all-in-one --domain scorebug.example.com \
  --rtmp-url rtmps://a.rtmp.youtube.com/live2 --stream-key "$YOUTUBE_STREAM_KEY"
```

`--video-profile` sets the output resolution: `240p30`, `360p30`, `540p30`,
`720p30` (default), `1080p30` or `2160p30`. Run `infra/install.sh --help` for every
option.

## Install: split

### On the server

```bash
infra/install.sh --topology split
```

This runs Caddy, the API and the relay only. It also writes
`infra/vps/worker.env` (mode `0600`) with everything the home worker needs, and
prints the commands below. That file contains the worker token and your stream
key. Copy it privately, for example with `scp`, and delete stray copies.

### At home: Linux with Docker

From a checkout of the same revision as the server:

```bash
infra/install.sh worker --env-file ./worker.env
```

It copies the settings to `infra/worker/worker.env` (mode `0600`), checks that
the server's `/healthz` is reachable, builds the worker image, starts it, and
waits for it to report healthy. The worker connects out to your server over
HTTPS and SRT and out to YouTube over RTMPS. Nothing listens at home.

### At home: macOS

On a Mac the worker runs as a plain Node process and can use the VideoToolbox
hardware encoder. You need Node 22.13 or later, pnpm 9.15.0
(`corepack enable`), and Homebrew's `ffmpeg-full` (`brew install ffmpeg-full`).

The split install prints a `worker.env (macOS)` block: the same settings with
`ENCODER=videotoolbox` and the Homebrew FFmpeg path. Save it as `worker.env`
(mode `0600`) and replace `YOUR_USER` in `SCORE_DIR`. Then, from a checkout of the
same revision as the server:

```bash
pnpm install --frozen-lockfile
pnpm --filter @scorebug/home-daemon... -r build
node --env-file=worker.env apps/home-daemon/dist/index.js
```

The worker logs one JSON line per event to the terminal and stops on Ctrl-C. Keep it
running for the whole match.

## Phone setup

Set up the phone once, at home. The installer ends by printing a QR code and a
one-time setup link like

```
scorebug://connect?server=https%3A%2F%2Fscorebug.example.com&code=…
```

Scan the QR code with the iPhone camera, or text the link to yourself and open
it on the phone. The app connects to your server and gets its own credential;
there is nothing to type. Each link works for one phone and expires after 24
hours. For another phone, or if the link expired, print a new one:

```bash
infra/install.sh phone
```

That runs the setup-link command inside the API container. You can also run it
directly:

```bash
docker compose -f infra/vps/docker-compose.yml exec control-plane \
  node apps/control-plane/dist/cli.js setup-link
```

A lost phone can be cut off without touching anything else:

```bash
docker compose -f infra/vps/docker-compose.yml exec control-plane \
  node apps/control-plane/dist/cli.js devices
docker compose -f infra/vps/docker-compose.yml exec control-plane \
  node apps/control-plane/dist/cli.js revoke-device DEVICE_ID
```

At the game you don't touch the server. The filming phone starts the match and
shares an invite (QR code, link or a short code like `K7P-4QX`) so other phones
can keep score. See [the API reference](api.md).

## Test without a phone

Before a real match, you can push a test pattern through the whole chain. Point
your stream key at a private or unlisted YouTube stream first.

Run this in the server's checkout (it reads `infra/vps/.env`). It needs Node 22 and
an FFmpeg build that includes SRT:

```bash
node infra/smoke-broadcast.mjs start > publish-url.txt
ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=frequency=440 \
  -t 120 -c:v libx264 -preset veryfast -tune zerolatency -g 60 -b:v 3M -pix_fmt yuv420p \
  -c:a aac -b:a 128k -f mpegts "$(cat publish-url.txt)"
node infra/smoke-broadcast.mjs stop    # also revokes the test phone
rm publish-url.txt
```

`smoke-broadcast.mjs start` mints a one-time setup link with `docker compose exec`,
sets itself up as a phone, creates a test match, and starts a broadcast the same way
the phone does. The server picks your worker. It prints the SRT publish URL, which
contains a one-time secret. Within a few seconds the worker log shows
`producing_output`, and the test pattern with a Home vs Away scorebug at 0–0
appears in your YouTube stream preview.

Without Node on the server, run the script in a container and give it a setup link
from `infra/install.sh phone` (the container cannot mint one):

```bash
docker run --rm -v "$PWD/infra:/infra" node:22-alpine \
  node /infra/smoke-broadcast.mjs start 'scorebug://connect?…'
```

## Checking health

```bash
infra/install.sh status
```

This shows the containers, checks `/healthz` through Caddy and through public DNS,
and for all-in-one prints the worker's status line, for example:

```
worker_health=ok worker=local-worker idle
worker_health=ok worker=local-worker match=1c4f...        (a broadcast is assigned)
worker_health=fail reason=http_401 worker=local-worker    (wrong HOME_TOKEN)
```

The same check (`infra/worker-health.mjs`) is the worker container's Docker
healthcheck (`docker compose ps` shows `healthy`). It proves the worker is running
and that the API accepts its URL, token and worker ID. It does not prove video is
flowing; the phone's streaming screen shows that.

Logs:

```bash
docker compose -f infra/vps/docker-compose.yml logs -f              # server
docker compose -f infra/worker/docker-compose.yml logs -f worker   # home worker
```

## Upgrading

Finish any live broadcast first, back up (below), then on the server:

```bash
git pull
infra/install.sh
```

Re-running keeps your secrets and settings (it reads them back from
`infra/vps/.env`), rebuilds the images for the new revision, and recreates the
containers that changed. The API and worker images are tagged with the Git
revision, so the previous ones stay available. To roll back: `git checkout
<previous-revision>`, restore the matching database backup if the new version
changed it, and run `infra/install.sh` again.

For a split setup, upgrade the home worker to the same revision afterwards:

```bash
git pull
infra/install.sh worker
```

On macOS, `git pull`, then run the install and build commands again and restart
the worker.

Never run two workers with the same worker ID at once.

## Backups

Everything that matters on the server is:

- `infra/vps/.env`: your secrets and settings (private).
- The `scorebug_control_data` Docker volume: the SQLite database
  (`scorebug.sqlite` plus its `-wal`/`-shm` files) with matches, scores,
  credentials and streaming destinations.
- The `scorebug_caddy_data` volume: certificates (Caddy issues new ones if lost).

Back up the database while the API is stopped so the copy is consistent:

```bash
docker compose -f infra/vps/docker-compose.yml stop control-plane
docker run --rm -v scorebug_control_data:/data:ro -v "$PWD":/backup alpine \
  tar czf /backup/scorebug-db-$(date +%F).tgz -C /data .
docker compose -f infra/vps/docker-compose.yml start control-plane
```

Restore onto a stopped API:

```bash
docker compose -f infra/vps/docker-compose.yml stop control-plane
docker run --rm -v scorebug_control_data:/data -v "$PWD":/backup alpine \
  sh -c 'rm -f /data/* && tar xzf /backup/scorebug-db-YYYY-MM-DD.tgz -C /data'
docker compose -f infra/vps/docker-compose.yml start control-plane
```

Keep `.env` and database backups somewhere private. `docker compose down` keeps
the volumes; `docker compose down --volumes` deletes your matches.

The phone keeps its own recording of every match, without the scorebug. The server
does not back that up.

## Rotating secrets

Rotate if a token leaked, between matches (not while live):

```bash
infra/install.sh --rotate-secrets
```

This replaces `SERVER_SECRET`, `HOME_TOKEN` and `RELAY_API_PASSWORD` and restarts
the stack. Afterwards:

- Phones keep working. Their credentials are stored in the database; revoke a
  lost phone with `revoke-device` (see Phone setup).
- An all-in-one worker picks up the new token automatically. A split home worker
  needs the new `infra/vps/worker.env`: copy it over and run
  `infra/install.sh worker --env-file ./worker.env` again (on macOS, update its
  `HOME_TOKEN` and restart it).

Matches in the database stay, but a broadcast that was set up before the rotation
must be started again from the phone.

To change only the YouTube stream key, re-run the installer with
`--rtmp-url ... --stream-key ...`. It updates the default destination and the
worker's fallback `OUTPUT_URL`; no secret changes.

## Troubleshooting

**"Caddy is not serving HTTPS" during install.** Caddy could not get a
certificate. Check that the domain's DNS points at this server
(`dig +short scorebug.example.com`), that TCP 80 and 443 are open in every
firewall, and look at `docker compose -f infra/vps/docker-compose.yml logs caddy`.
Fix it, then run `infra/install.sh status`.

**The phone says the server rejected it.** Its credential was revoked. Set it up
again with a new link from `infra/install.sh phone`.

**A setup link says "already used" or "expired".** Each link sets up one phone
within 24 hours. Print a new one with `infra/install.sh phone`.

**The phone connects but streaming never starts.** The phone could not reach the
relay over UDP 8890. Check that the firewall rule is UDP (not TCP) and, for a home
box, that the router forwards UDP 8890. Some guest Wi-Fi networks block non-web
UDP; try cellular.

**Worker is `unhealthy` / `worker_health=fail`.** The status line says why.
`http_401` means the worker's `HOME_TOKEN` does not match the server: copy the
current `worker.env` again. Any other reason (`timeout`, `unreachable` or a network
error code such as `ECONNREFUSED`) means it cannot reach the API URL. Check DNS and
HTTPS from that machine with `curl https://your-domain/healthz`.

**Worker stuck in `waiting_source`.** The broadcast is assigned but no video is
arriving at the relay yet, or (split) the home machine cannot reach UDP 8890 on
the server. Test from home with the smoke test above.

**Nothing appears on YouTube.** Check the worker log for RTMP errors. A wrong or
expired stream key fails immediately; re-run the installer with the new key.
`worker_output_missing` in the worker log means the match has no destination and
the worker has no fallback `OUTPUT_URL`. YouTube can take 10–20 seconds to show a
new stream in the preview.

**Video stutters or the worker falls behind.** The server is short on CPU. Use a
smaller profile (`--video-profile 720p30`), a bigger server, or the split
topology.

## Trying it on a laptop

You can run the whole all-in-one stack locally to see it work. Use a `.localhost`
name (Caddy then uses its own private certificate authority) and other ports if
80 and 443 are taken. Start the mock YouTube from `docker-compose.dev.yml`
(MediaMTX with `infra/local/sink.yml`, RTMP on `127.0.0.1:11935`) and send the
output there:

```bash
docker compose -f docker-compose.dev.yml up -d sink
infra/install.sh --yes --topology all-in-one --domain scorebug.localhost \
  --http-port 18080 --https-port 18443 \
  --output-url 'rtmp://host.docker.internal:11935/live/fixture?user=qa-worker&pass=qa-output-not-production'
```

Run the smoke test with `SCOREBUG_INSECURE_TLS=1` so Node accepts the private
certificate.

On Docker Desktop for Mac, add `--srt-bind 127.0.0.1`. Its UDP port forwarding on
all interfaces drops reply packets, so SRT from the host only works when the relay
port is bound to loopback. Linux Docker Engine does not have this problem; never use
`--srt-bind` on a real server.

Remove a local test completely (this deletes its database):

```bash
docker compose -f infra/vps/docker-compose.yml --profile worker down --volumes
rm -f infra/vps/.env infra/vps/worker.env
docker compose -f docker-compose.dev.yml down
```

## What lives where

| Path                              | What it is                                                     |
| --------------------------------- | -------------------------------------------------------------- |
| `infra/install.sh`                | The installer (`server`, `worker`, `status`, `phone`)          |
| `infra/vps/`                      | Server stack; see [its README](../infra/vps/README.md)         |
| `infra/vps/.env`                  | Generated secrets and settings (private, not in Git)           |
| `infra/vps/worker.env`            | Split topology: settings to copy to the home machine (private) |
| `infra/worker/docker-compose.yml` | Home worker stack for the split topology                       |
| `infra/worker-health.mjs`         | Worker health probe used by Docker and the installer           |
| `infra/smoke-broadcast.mjs`       | Starts and stops a test broadcast the way the phone does       |
| `infra/local/`                    | Public test configs for the local relay and mock YouTube       |
