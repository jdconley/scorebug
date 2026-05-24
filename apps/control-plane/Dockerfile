# Build from the repo root:
#   docker build -f apps/control-plane/Dockerfile -t scorebug/control-plane .

FROM node:22-alpine AS deps
RUN apk add --no-cache libc6-compat
RUN npm install -g pnpm@9.15.0
WORKDIR /app

COPY package.json pnpm-workspace.yaml pnpm-lock.yaml tsconfig.base.json ./
COPY packages/protocol/package.json packages/protocol/
COPY apps/control-plane/package.json apps/control-plane/

RUN pnpm install --frozen-lockfile --filter @scorebug/control-plane...

FROM deps AS build
COPY packages/protocol packages/protocol
COPY apps/control-plane apps/control-plane
RUN pnpm --filter @scorebug/control-plane build

FROM node:22-alpine AS runtime
RUN apk add --no-cache tini
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/node_modules /app/node_modules
COPY --from=build /app/packages /app/packages
COPY --from=build /app/apps/control-plane/dist /app/apps/control-plane/dist
COPY --from=build /app/apps/control-plane/package.json /app/apps/control-plane/package.json

EXPOSE 8787
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "apps/control-plane/dist/index.js"]
