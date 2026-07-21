FROM node:26.5.0-alpine3.24@sha256:e88a35be04478413b7c71c455cd9865de9b9360e1f43456be5951032d7ac1a66 AS deps
WORKDIR /app
RUN apk add --no-cache python3 make g++
COPY package.json package-lock.json ./
RUN npm ci

FROM node:26.5.0-alpine3.24@sha256:e88a35be04478413b7c71c455cd9865de9b9360e1f43456be5951032d7ac1a66 AS builder
ARG ADDRESS_ATLAS_BUILD_REVISION
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN mkdir -p dist \
  && ./node_modules/.bin/esbuild src/lib/sync/bootstrap.ts \
    --bundle \
    --platform=node \
    --target=node22 \
    --format=cjs \
    --external:pg \
    --outfile=dist/sync-bootstrap.cjs \
  && ./node_modules/.bin/esbuild src/lib/sync/restore-readiness.ts \
    --bundle \
    --platform=node \
    --target=node22 \
    --format=cjs \
    --external:pg \
    --outfile=dist/sync-restore.cjs
RUN npm run build

FROM node:26.5.0-alpine3.24@sha256:e88a35be04478413b7c71c455cd9865de9b9360e1f43456be5951032d7ac1a66 AS runner
ARG ADDRESS_ATLAS_BUILD_REVISION
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production
ENV ADDRESS_ATLAS_BUILD_REVISION=${ADDRESS_ATLAS_BUILD_REVISION}
LABEL org.opencontainers.image.revision=${ADDRESS_ATLAS_BUILD_REVISION}
LABEL com.addressatlas.sync.max-compatible-schema-head=4
LABEL com.addressatlas.sync.compatible-schema-head-3-sha256=47ad43aa7438c5c8969f7c01162bb73eab8d51066abef482a03fed86a7890ee3
LABEL com.addressatlas.sync.compatible-schema-head-4-sha256=ceb0b725a162b5be512bf35e63ecaf178aa67e7c1335e2807a116f2ef7f65dfe
COPY --from=builder --chown=node:node /app/next.config.mjs ./next.config.mjs
COPY --from=builder --chown=node:node /app/package.json ./package.json
COPY --from=builder --chown=node:node /app/package-lock.json ./package-lock.json
COPY --from=builder --chown=node:node /app/node_modules ./node_modules
COPY --from=builder --chown=node:node /app/.next ./.next
COPY --from=builder --chown=node:node /app/dist/sync-bootstrap.cjs ./dist/sync-bootstrap.cjs
COPY --from=builder --chown=node:node /app/dist/sync-restore.cjs ./dist/sync-restore.cjs
RUN npm prune --omit=dev && npm cache clean --force
USER node
EXPOSE 3000
CMD ["npm", "start"]
