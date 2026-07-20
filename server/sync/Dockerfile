FROM node:22.23.1-alpine3.24@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2 AS deps
WORKDIR /app
RUN apk add --no-cache python3 make g++
COPY package.json package-lock.json ./
RUN npm ci

FROM node:22.23.1-alpine3.24@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2 AS builder
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

FROM node:22.23.1-alpine3.24@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2 AS runner
ARG ADDRESS_ATLAS_BUILD_REVISION
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production
ENV ADDRESS_ATLAS_BUILD_REVISION=${ADDRESS_ATLAS_BUILD_REVISION}
LABEL org.opencontainers.image.revision=${ADDRESS_ATLAS_BUILD_REVISION}
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
