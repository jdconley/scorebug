# The hosted match container: `wrangler deploy` builds this image for the control
# plane's per-match Cloudflare Container. Linux CPU image; FFmpeg encodes with x264.
# No system fonts: the worker rasterizes the scorebug itself (resvg + the
# Barlow Condensed files bundled in apps/home-daemon/assets/fonts, SIL OFL 1.1).
#
# Built from the repo root so the workspace layout is visible:
#   docker build -f apps/home-daemon/Dockerfile -t scorebug/home-daemon .

# Trixie FFmpeg supplies stats_enc_pre/post required by adaptive processing reports.
# Bookworm can publish but silently lacks those timing options.
FROM node:22-trixie-slim AS base

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates ffmpeg tini \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g pnpm@9.15.0

WORKDIR /app

# Workspace manifests first for cache friendliness
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml tsconfig.base.json ./
COPY packages/protocol/package.json packages/protocol/
COPY apps/home-daemon/package.json apps/home-daemon/

RUN pnpm install --frozen-lockfile --filter @scorebug/home-daemon...

COPY packages/protocol packages/protocol
COPY apps/home-daemon apps/home-daemon

RUN pnpm --filter @scorebug/home-daemon... -r build

ENV SCORE_DIR=/tmp/scorebug
RUN mkdir -p /tmp/scorebug

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "apps/home-daemon/dist/index.js"]
