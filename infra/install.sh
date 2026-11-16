#!/bin/sh
# Scorebug self-hosting installer. Plain-language guide: docs/self-hosting.md
#
#   infra/install.sh [server] [options]   set up / upgrade the server (default)
#   infra/install.sh worker [options]     run the worker on a home Linux machine
#   infra/install.sh status               check a running server
#   infra/install.sh phone                print a new one-time phone setup link
#
# Run `infra/install.sh --help` for every option.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SERVER_DIR=$SCRIPT_DIR/vps
WORKER_DIR=$SCRIPT_DIR/worker
SERVER_ENV=$SERVER_DIR/.env
WORKER_ENV=$WORKER_DIR/worker.env
SPLIT_WORKER_ENV=$SERVER_DIR/worker.env

usage() {
  cat <<'EOF'
Usage: infra/install.sh [server|worker|status|phone] [options]

phone - print a new one-time phone setup link (QR code + link, 24 hours)

server (default) - install or upgrade Caddy + API + SRT relay (+ worker)
  --topology all-in-one|split  all-in-one also runs the worker on this host;
                               split prints the worker setup for a home machine
  --domain NAME                public DNS name for the API and SRT relay
  --output-url URL             full RTMP(S) URL including the stream key, or:
  --rtmp-url URL               YouTube "Stream URL" (rtmps://a.rtmp.youtube.com/live2)
  --stream-key KEY             YouTube "Stream key"
  --video-profile NAME         240p30 360p30 540p30 720p30 1080p30 (default 720p30)
  --http-port N --https-port N host ports for Caddy (default 80 and 443)
  --srt-bind ADDR              host address for the SRT port (default: all).
                               Use 127.0.0.1 only to test on Docker Desktop
                               for Mac, whose wildcard UDP forwarding is broken
  --tls auto|public|internal   internal = Caddy's private CA, for test domains
                               only (default auto: internal for .localhost,
                               .test, .internal, .local, .home.arpa)
  --rotate-secrets             generate new tokens (phones/worker must be updated)
  --no-build                   skip building images (use ones already built)
  -y, --yes                    never prompt; fail if a required value is missing

worker - home machine in the split topology (Linux + Docker)
  --env-file PATH              worker.env produced by the server install

Every server option can also come from the environment: SCOREBUG_TOPOLOGY,
SCOREBUG_DOMAIN, SCOREBUG_OUTPUT_URL, SCOREBUG_RTMP_URL, SCOREBUG_STREAM_KEY,
SCOREBUG_VIDEO_PROFILE, SCOREBUG_HTTP_PORT, SCOREBUG_HTTPS_PORT, SCOREBUG_TLS,
SCOREBUG_SRT_BIND.
Re-running keeps existing secrets and settings unless you override them.
EOF
}

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------- helpers

# 32 bytes from the kernel CSPRNG, hex encoded (64 characters).
random_hex() {
  value=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  [ "${#value}" -eq 64 ] || die 'could not read /dev/urandom'
  printf '%s' "$value"
}

# env_get FILE KEY -> value (outer single quotes removed), empty if absent.
env_get() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1 | sed "s/^'\(.*\)'\$/\1/"
}

is_interactive() { [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; }

# ask VAR "Question" [secret]: prompt only when VAR is empty and a terminal is
# attached; otherwise leave VAR as is.
# shellcheck disable=SC2034 # `answer` is read through eval.
ask() {
  eval "current=\${$1:-}"
  [ -n "$current" ] && return 0
  answer=''
  is_interactive || return 0
  printf '%s: ' "$2" >&2
  if [ "${3:-}" = secret ]; then
    stty -echo 2>/dev/null || true
    IFS= read -r answer || true
    stty echo 2>/dev/null || true
    printf '\n' >&2
  else
    IFS= read -r answer || true
  fi
  eval "$1=\$answer"
}

valid_domain() {
  printf '%s' "$1" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
}

internal_domain() {
  case $1 in
    *.localhost | *.test | *.internal | *.local | *.home.arpa | *.invalid) return 0 ;;
    *) return 1 ;;
  esac
}

valid_port() {
  case $1 in '' | *[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# URL safe to store in a dotenv file: rtmp(s), no whitespace or quotes.
valid_output_url() {
  case $1 in
    *[[:space:]]* | *\'* | *\"* | *\\*) return 1 ;;
    rtmps://?* | rtmp://?*) return 0 ;;
    *) return 1 ;;
  esac
}

check_docker() {
  command -v docker >/dev/null 2>&1 ||
    die 'Docker is not installed. Install Docker Engine: https://docs.docker.com/engine/install/'
  docker compose version >/dev/null 2>&1 ||
    die 'Docker Compose v2 is missing (the "docker compose" plugin).'
  docker info >/dev/null 2>&1 ||
    die 'Cannot talk to the Docker daemon. Is it running, and is this user allowed to use it?'
  [ -f "$SCRIPT_DIR/../apps/control-plane/Dockerfile" ] ||
    die 'Run this script from a full Scorebug checkout.'
  [ "$(uname -s)" = Linux ] ||
    warn 'Not Linux: fine for testing, but production hosts should be Linux.'
}

server_compose() {
  docker compose --project-directory "$SERVER_DIR" -f "$SERVER_DIR/docker-compose.yml" \
    --env-file "$SERVER_ENV" "$@"
}

worker_compose() {
  docker compose --project-directory "$WORKER_DIR" -f "$WORKER_DIR/docker-compose.yml" "$@"
}

# wait_healthy "compose function" SERVICE SECONDS
wait_healthy() {
  waited=0
  while [ "$waited" -lt "$3" ]; do
    id=$($1 ps -q "$2" 2>/dev/null || true)
    if [ -n "$id" ]; then
      health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || echo missing)
      [ "$health" = healthy ] && return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

https_base() {
  if [ "$HTTPS_PORT" = 443 ]; then printf 'https://%s' "$DOMAIN"; else printf 'https://%s:%s' "$DOMAIN" "$HTTPS_PORT"; fi
}

# Check /healthz through Caddy on this host (independent of public DNS).
check_local_https() {
  command -v curl >/dev/null 2>&1 || {
    warn 'curl not found; skipping the HTTPS check.'
    return 0
  }
  insecure=''
  [ "$CADDY_TLS" = 'tls internal' ] && insecure='-k'
  waited=0
  while [ "$waited" -lt "$1" ]; do
    # shellcheck disable=SC2086 # $insecure is intentionally empty or one flag.
    if body=$(curl -fsS $insecure --max-time 5 --resolve "$DOMAIN:$HTTPS_PORT:127.0.0.1" \
      "$(https_base)/healthz" 2>/dev/null); then
      say "HTTPS /healthz through Caddy: $body"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

# ---------------------------------------------------------- phone setup

control_plane_cli() {
  server_compose exec -T control-plane node apps/control-plane/dist/cli.js "$@"
}

# Mint a one-time setup link inside the API container and print it with a QR
# code. The link is a single-use secret that expires in 24 hours.
print_phone_setup() {
  step 'Phone setup'
  qr=none
  [ -t 1 ] && qr=ansi
  if ! control_plane_cli setup-link --server "$(https_base)" --qr "$qr"; then
    warn "could not mint a setup link; is the API running? Try again with: $0 phone"
    return 0
  fi
  say ''
  say 'Scan the QR code with the phone camera, or text the link to yourself and'
  say 'open it on the phone. Each link sets up one phone. Another phone: run'
  say "  $0 phone"
}

# Save the YouTube URL from the installer as the default streaming destination
# the first time; later changes happen in the app. Reads the URL from stdin so
# the stream key never appears in a process list.
seed_destination() {
  set -- --name YouTube
  # A stream URL/key given on this run also replaces the saved default.
  [ "$OUTPUT_URL_GIVEN" -eq 1 ] && set -- "$@" --replace
  printf '%s' "$OUTPUT_URL" | control_plane_cli seed-destination "$@" ||
    warn 'could not save the YouTube destination; the worker uses OUTPUT_URL instead'
}

load_server_settings() {
  [ -f "$SERVER_ENV" ] || die "No server configuration at $SERVER_ENV. Run '$0 server' first."
  DOMAIN=$(env_get "$SERVER_ENV" CADDY_DOMAIN)
  HTTPS_PORT=$(env_get "$SERVER_ENV" HTTPS_PORT)
  HTTPS_PORT=${HTTPS_PORT:-443}
  CADDY_TLS=$(env_get "$SERVER_ENV" CADDY_TLS)
  TOPOLOGY=$(env_get "$SERVER_ENV" SCOREBUG_TOPOLOGY)
}

# ------------------------------------------------------------------ server

write_server_env() {
  umask 077
  tmp="$SERVER_ENV.tmp.$$"
  cat >"$tmp" <<EOF
# Written by infra/install.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ'). Private: mode 0600.
# Re-run infra/install.sh to change settings; it keeps these secrets.
SCOREBUG_TOPOLOGY=$TOPOLOGY
CADDY_DOMAIN=$DOMAIN
INGEST_HOST=$DOMAIN
INGEST_PORT=8890
INGEST_BIND=$INGEST_BIND
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
CADDY_TLS=$CADDY_TLS
PUBLIC_URL=$(https_base)
SERVER_SECRET=$SERVER_SECRET
HOME_TOKEN=$HOME_TOKEN
RELAY_API_PASSWORD=$RELAY_API_PASSWORD
WORKER_ID=$WORKER_ID
OUTPUT_ID=$OUTPUT_ID
OUTPUT_URL='$OUTPUT_URL'
VIDEO_PROFILE=$VIDEO_PROFILE
SCOREBUG_RELEASE=$SCOREBUG_RELEASE
CADDY_IMAGE=$CADDY_IMAGE
CORS_ORIGINS=https://localhost.invalid
LOG_LEVEL=info
EOF
  chmod 600 "$tmp"
  mv "$tmp" "$SERVER_ENV"
}

write_split_worker_env() {
  umask 077
  tmp="$SPLIT_WORKER_ENV.tmp.$$"
  cat >"$tmp" <<EOF
# Scorebug worker settings for the home machine. Private: contains secrets.
CONTROL_PLANE_URL=$(https_base)
HOME_TOKEN=$HOME_TOKEN
WORKER_ID=$WORKER_ID
OUTPUT_ID=$OUTPUT_ID
OUTPUT_MODE=rtmp
OUTPUT_URL='$OUTPUT_URL'
ENCODER=software
VIDEO_PROFILE=$VIDEO_PROFILE
LOG_LEVEL=info
EOF
  chmod 600 "$tmp"
  mv "$tmp" "$SPLIT_WORKER_ENV"
}

cmd_server() {
  TOPOLOGY=${SCOREBUG_TOPOLOGY:-}
  DOMAIN=${SCOREBUG_DOMAIN:-}
  OUTPUT_URL=${SCOREBUG_OUTPUT_URL:-}
  RTMP_URL=${SCOREBUG_RTMP_URL:-}
  STREAM_KEY=${SCOREBUG_STREAM_KEY:-}
  VIDEO_PROFILE=${SCOREBUG_VIDEO_PROFILE:-}
  HTTP_PORT=${SCOREBUG_HTTP_PORT:-}
  HTTPS_PORT=${SCOREBUG_HTTPS_PORT:-}
  TLS_MODE=${SCOREBUG_TLS:-auto}
  INGEST_BIND=${SCOREBUG_SRT_BIND-unset}
  ROTATE=0
  BUILD=1
  while [ $# -gt 0 ]; do
    case $1 in
      --topology) TOPOLOGY=${2:?--topology needs a value}; shift ;;
      --domain) DOMAIN=${2:?--domain needs a value}; shift ;;
      --output-url) OUTPUT_URL=${2:?--output-url needs a value}; shift ;;
      --rtmp-url) RTMP_URL=${2:?--rtmp-url needs a value}; shift ;;
      --stream-key) STREAM_KEY=${2:?--stream-key needs a value}; shift ;;
      --video-profile) VIDEO_PROFILE=${2:?--video-profile needs a value}; shift ;;
      --http-port) HTTP_PORT=${2:?--http-port needs a value}; shift ;;
      --https-port) HTTPS_PORT=${2:?--https-port needs a value}; shift ;;
      --tls) TLS_MODE=${2:?--tls needs a value}; shift ;;
      --srt-bind) INGEST_BIND=${2?--srt-bind needs a value}; shift ;;
      --rotate-secrets) ROTATE=1 ;;
      --no-build) BUILD=0 ;;
      -y | --yes) ASSUME_YES=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done

  step 'Checking Docker'
  check_docker
  say "$(docker compose version)"

  OUTPUT_URL_GIVEN=0
  [ -n "$OUTPUT_URL$RTMP_URL$STREAM_KEY" ] && OUTPUT_URL_GIVEN=1
  # Previous settings are the defaults, so re-running is an upgrade.
  TOPOLOGY=${TOPOLOGY:-$(env_get "$SERVER_ENV" SCOREBUG_TOPOLOGY)}
  DOMAIN=${DOMAIN:-$(env_get "$SERVER_ENV" CADDY_DOMAIN)}
  if [ -z "$OUTPUT_URL" ] && [ -n "$RTMP_URL$STREAM_KEY" ]; then
    [ -n "$RTMP_URL" ] && [ -n "$STREAM_KEY" ] || die 'give both --rtmp-url and --stream-key'
    OUTPUT_URL="${RTMP_URL%/}/$STREAM_KEY"
  fi
  OUTPUT_URL=${OUTPUT_URL:-$(env_get "$SERVER_ENV" OUTPUT_URL)}
  VIDEO_PROFILE=${VIDEO_PROFILE:-$(env_get "$SERVER_ENV" VIDEO_PROFILE)}
  HTTP_PORT=${HTTP_PORT:-$(env_get "$SERVER_ENV" HTTP_PORT)}
  HTTPS_PORT=${HTTPS_PORT:-$(env_get "$SERVER_ENV" HTTPS_PORT)}
  [ "$INGEST_BIND" = unset ] && INGEST_BIND=$(env_get "$SERVER_ENV" INGEST_BIND)
  case $INGEST_BIND in '' | *[!0-9.]*) [ -z "$INGEST_BIND" ] || die '--srt-bind must be an IPv4 address' ;; esac

  step 'Settings'
  if [ -z "$TOPOLOGY" ] && is_interactive; then
    say 'Where should video encoding run?'
    say '  1) all-in-one: on this server (needs enough CPU, see docs/self-hosting.md)'
    say '  2) split: on a machine at home; this server only runs the API and relay'
    ask choice 'Choose 1 or 2 [1]'
    case ${choice:-1} in
      1) TOPOLOGY='all-in-one' ;;
      2) TOPOLOGY='split' ;;
      *) die 'choose 1 or 2' ;;
    esac
  fi
  TOPOLOGY=${TOPOLOGY:-all-in-one}
  case $TOPOLOGY in all-in-one | split) ;; *) die "--topology must be all-in-one or split" ;; esac

  ask DOMAIN 'Public domain for this server (DNS must point here, e.g. scorebug.example.com)'
  [ -n "$DOMAIN" ] || die 'a domain is required (--domain)'
  valid_domain "$DOMAIN" ||
    die "'$DOMAIN' is not a DNS name. Use a domain, not an IP address or bare 'localhost' (for a local test, use e.g. scorebug.localhost)."

  if [ -z "$OUTPUT_URL" ] && is_interactive; then
    say 'YouTube Studio -> Go live -> Stream shows a Stream URL and a Stream key.'
    ask RTMP_URL 'Stream URL [rtmps://a.rtmp.youtube.com/live2]'
    RTMP_URL=${RTMP_URL:-rtmps://a.rtmp.youtube.com/live2}
    ask STREAM_KEY 'Stream key (hidden)' secret
    [ -n "$STREAM_KEY" ] && OUTPUT_URL="${RTMP_URL%/}/$STREAM_KEY"
  fi
  [ -n "$OUTPUT_URL" ] || die 'the YouTube stream URL and key are required (--rtmp-url and --stream-key)'
  valid_output_url "$OUTPUT_URL" || die 'output URL must start with rtmps:// or rtmp:// and contain no spaces or quotes'
  case $OUTPUT_URL in rtmp://*) warn 'rtmp:// is unencrypted; YouTube supports rtmps://.' ;; esac

  VIDEO_PROFILE=${VIDEO_PROFILE:-720p30}
  case $VIDEO_PROFILE in 240p30 | 360p30 | 540p30 | 720p30 | 1080p30 | 2160p30) ;; *) die "unknown video profile $VIDEO_PROFILE" ;; esac
  HTTP_PORT=${HTTP_PORT:-80}
  HTTPS_PORT=${HTTPS_PORT:-443}
  if ! valid_port "$HTTP_PORT" || ! valid_port "$HTTPS_PORT"; then die 'ports must be 1-65535'; fi

  case $TLS_MODE in
    auto) if internal_domain "$DOMAIN"; then CADDY_TLS='tls internal'; else CADDY_TLS=''; fi ;;
    public) CADDY_TLS='' ;;
    internal) CADDY_TLS='tls internal' ;;
    *) die '--tls must be auto, public or internal' ;;
  esac
  if [ -n "$CADDY_TLS" ]; then
    say "TLS: Caddy's private CA (test only; phones will not trust it)"
  elif [ "$HTTP_PORT" != 80 ] || [ "$HTTPS_PORT" != 443 ]; then
    warn 'public certificates need this host reachable on ports 80 and 443'
  fi

  for key in SERVER_SECRET HOME_TOKEN RELAY_API_PASSWORD; do
    value=$(env_get "$SERVER_ENV" "$key")
    if [ "$ROTATE" -eq 1 ] || [ -z "$value" ]; then value=$(random_hex); fi
    eval "$key=\$value"
  done
  WORKER_ID=$(env_get "$SERVER_ENV" WORKER_ID)
  WORKER_ID=${WORKER_ID:-local-worker}
  OUTPUT_ID=$(env_get "$SERVER_ENV" OUTPUT_ID)
  OUTPUT_ID=${OUTPUT_ID:-local-output}
  SCOREBUG_RELEASE=$(git -C "$SCRIPT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo local)
  CADDY_IMAGE=$(env_get "$SERVER_ENV" CADDY_IMAGE)
  CADDY_IMAGE=${CADDY_IMAGE:-caddy:2-alpine}

  say "Topology: $TOPOLOGY"
  say "Domain:   $DOMAIN (HTTPS $HTTPS_PORT/tcp, SRT 8890/udp)"
  say "Video:    $VIDEO_PROFILE"
  write_server_env
  say "Wrote $SERVER_ENV (mode 600)"
  [ "$ROTATE" -eq 1 ] && warn 'secrets rotated: update every phone and any home worker'

  set --
  [ "$TOPOLOGY" = all-in-one ] && set -- --profile worker

  if [ "$BUILD" -eq 1 ]; then
    step 'Building images (first run takes several minutes)'
    server_compose "$@" pull --quiet caddy || warn 'could not pull Caddy; using the local image if present'
    server_compose "$@" build
  fi

  step 'Starting the stack'
  if [ "$TOPOLOGY" = split ]; then
    # Switching from all-in-one: make sure no worker keeps running here.
    server_compose --profile worker rm --force --stop worker >/dev/null 2>&1 || true
  fi
  server_compose "$@" up -d --no-build --remove-orphans

  step 'Waiting for the API'
  wait_healthy server_compose control-plane 120 ||
    die "the API did not become healthy. Logs: docker compose -f $SERVER_DIR/docker-compose.yml logs control-plane"
  check_local_https 180 || die "the API is running but Caddy is not serving HTTPS for $DOMAIN yet.
  Usually DNS for $DOMAIN does not point at this host yet, or ports 80/443 are blocked.
  Fix that, then check again with: $0 status
  Caddy logs: docker compose -f $SERVER_DIR/docker-compose.yml logs caddy"
  seed_destination

  if [ "$TOPOLOGY" = all-in-one ]; then
    step 'Waiting for the worker'
    if wait_healthy server_compose worker 90; then
      server_compose exec -T worker node /app/infra/worker-health.mjs || true
    else
      die "the worker did not become healthy. Logs: docker compose -f $SERVER_DIR/docker-compose.yml logs worker"
    fi
  else
    write_split_worker_env
    print_split_worker
  fi

  print_phone_setup
  print_next_steps
}

print_split_worker() {
  step 'Home worker setup (split topology)'
  say "The worker settings are in $SPLIT_WORKER_ENV (mode 600, contains secrets)."
  say 'Copy that file to the home machine privately, for example:'
  say "  scp you@$DOMAIN:$SPLIT_WORKER_ENV ./worker.env"
  say ''
  say 'Linux home machine with Docker, from a Scorebug checkout:'
  say '  infra/install.sh worker --env-file ./worker.env'
  say ''
  say 'macOS home machine: use the launchd service in docs/macos-worker-service.md.'
  say 'Start from the same values, add the macOS paths, and keep the file private:'
  say '----- worker.env (macOS) -----'
  sed -e '/^#/d' -e 's/^ENCODER=software$/ENCODER=videotoolbox/' "$SPLIT_WORKER_ENV"
  say 'FFMPEG_PATH=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg'
  say 'FFPROBE_PATH=/opt/homebrew/opt/ffmpeg-full/bin/ffprobe'
  say 'FONT_PATH="/System/Library/Fonts/Supplemental/Arial.ttf"'
  say 'SCORE_DIR="/Users/YOUR_USER/Library/Application Support/ScorebugWorker/state"'
  say '------------------------------'
  say 'The worker only makes outbound connections; open no ports at home.'
}

print_next_steps() {
  step 'Next steps'
  say "1. Firewall: allow inbound 80/tcp and 443/tcp (HTTPS) and 8890/udp (SRT)."
  say "2. Health any time:   $0 status"
  say "3. Logs:              docker compose -f $SERVER_DIR/docker-compose.yml logs -f"
  say "4. Back up the database regularly; see docs/self-hosting.md (Backups)."
  say "5. Upgrade:           git pull && $0"
}

# ------------------------------------------------------------------ status

cmd_status() {
  check_docker
  load_server_settings
  set --
  [ "$TOPOLOGY" = all-in-one ] && set -- --profile worker
  server_compose "$@" ps
  check_local_https 3 || die "HTTPS /healthz through Caddy failed for $DOMAIN"
  if [ "$TOPOLOGY" = all-in-one ]; then
    server_compose exec -T worker node /app/infra/worker-health.mjs ||
      die 'worker is not healthy'
  fi
  if command -v curl >/dev/null 2>&1; then
    insecure=''
    [ "$CADDY_TLS" = 'tls internal' ] && insecure='-k'
    # shellcheck disable=SC2086 # $insecure is intentionally empty or one flag.
    if curl -fsS $insecure --max-time 5 "$(https_base)/healthz" >/dev/null 2>&1; then
      say "Public check: $(https_base)/healthz reachable via DNS"
    else
      warn "$(https_base)/healthz is not reachable via public DNS from here (DNS, firewall, or hairpin NAT)"
    fi
  fi
}

cmd_phone() {
  check_docker
  load_server_settings
  print_phone_setup
}

# ------------------------------------------------------------------ worker

cmd_worker() {
  source_env=''
  BUILD=1
  while [ $# -gt 0 ]; do
    case $1 in
      --env-file) source_env=${2:?--env-file needs a path}; shift ;;
      --no-build) BUILD=0 ;;
      -y | --yes) ASSUME_YES=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  step 'Checking Docker'
  check_docker
  if [ -n "$source_env" ]; then
    [ -f "$source_env" ] || die "no such file: $source_env"
    umask 077
    cp "$source_env" "$WORKER_ENV.tmp.$$"
    chmod 600 "$WORKER_ENV.tmp.$$"
    mv "$WORKER_ENV.tmp.$$" "$WORKER_ENV"
  fi
  [ -f "$WORKER_ENV" ] || die "give --env-file with the worker.env printed by the server install"
  # OUTPUT_URL is optional: destinations normally come from the server.
  for key in CONTROL_PLANE_URL HOME_TOKEN WORKER_ID OUTPUT_ID; do
    [ -n "$(env_get "$WORKER_ENV" "$key")" ] || die "$key is missing from $WORKER_ENV"
  done
  api=$(env_get "$WORKER_ENV" CONTROL_PLANE_URL)
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 10 "$api/healthz" >/dev/null ||
      die "cannot reach $api/healthz from this machine; check the server and DNS"
    say "Server reachable: $api"
  fi
  SCOREBUG_RELEASE=$(git -C "$SCRIPT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo local)
  export SCOREBUG_RELEASE
  if [ "$BUILD" -eq 1 ]; then
    step 'Building the worker image'
    worker_compose build
  fi
  step 'Starting the worker'
  worker_compose up -d --no-build --remove-orphans
  wait_healthy worker_compose worker 90 ||
    die "the worker did not become healthy. Logs: docker compose -f $WORKER_DIR/docker-compose.yml logs worker"
  worker_compose exec -T worker node /app/infra/worker-health.mjs || true
  say ''
  say 'Worker is running and connects outbound only. It starts encoding when the'
  say 'phone starts a broadcast for this worker and output.'
  say "Logs: docker compose -f $WORKER_DIR/docker-compose.yml logs -f worker"
}

# -------------------------------------------------------------------- main

ASSUME_YES=0
command=server
case ${1:-} in
  server | worker | status | phone) command=$1; shift ;;
  -h | --help) usage; exit 0 ;;
esac
"cmd_$command" "$@"
