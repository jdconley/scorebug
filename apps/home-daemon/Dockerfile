# Linux CPU image; no CUDA runtime is required for the default software encoder.
# NVENC on other hosts still requires actual driver/toolkit and media qualification.
#
# Built from the repo root so the workspace layout is visible:
#   docker build -f apps/home-daemon/Dockerfile -t scorebug/home-daemon .

FROM node:22-bookworm-slim AS base

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates fonts-dejavu-core ffmpeg tini \
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

RUN pnpm --filter @scorebug/home-daemon build

ENV SCORE_DIR=/tmp/scorebug
RUN mkdir -p /tmp/scorebug

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "apps/home-daemon/dist/index.js"]
