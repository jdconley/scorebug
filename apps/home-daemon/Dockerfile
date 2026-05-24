# Linux image — runs on any Linux host. NVENC requires the NVIDIA Container
# Toolkit at run time (`docker run --gpus all ...`); on Windows that means
# Docker Desktop with WSL2 + the NVIDIA WSL driver. Set NVENC_ENABLED=false
# to fall back to libx264 for dev or CPU-only hosts.
#
# Built from the repo root so the workspace layout is visible:
#   docker build -f apps/home-daemon/Dockerfile -t scorebug/home-daemon .

FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04 AS base

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates fonts-dejavu-core ffmpeg \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
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

CMD ["node", "apps/home-daemon/dist/index.js"]
