# --- Stage 1: build the static bundle ---
# node:18 to match .nvmrc / the version that's actually verified to build
# this project cleanly (see repo history: newer Node breaks postcss's
# nested-package resolution in this toolchain).
FROM node:16.20.2-alpine AS build

WORKDIR /app

COPY package*.json ./
# --legacy-peer-deps matches what was verified working locally; the
# committed package-lock.json is the regenerated, known-good one.
RUN npm ci --legacy-peer-deps

COPY . .

# .env.production (committed, = /api) is picked up automatically by CRA
# for `npm run build`. No build-arg or runtime config injection needed -
# frontend and backend share one ALB origin in prod, so a relative path
# just works. See frontend/src/config.js for the fallback logic.
RUN npm run build

# --- Stage 2: serve the static bundle ---
# nginx-unprivileged, not the standard nginx image: it runs entirely as a
# non-root user out of the box. Plain nginx needs several manual
# chown/permission fixes on /var/run, /var/cache/nginx etc. to achieve the
# same thing, so this is actually the *simpler* path to least-privilege
# here, not extra complexity.
FROM nginxinc/nginx-unprivileged:alpine

COPY --from=build /app/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 3000
