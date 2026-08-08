# ---------------------------------------------------------------------------
# Dependency stage
# ---------------------------------------------------------------------------
# npm is required to resolve and install production dependencies during the
# image build, but it is not required by the running backend application.
ARG ALPINE_VERSION=3.24

FROM node:24-alpine${ALPINE_VERSION} AS dependencies

WORKDIR /build-stage

ENV NODE_ENV=production

COPY package*.json ./

# Install runtime dependencies only.
RUN npm ci --omit=dev


# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
# Start from plain Alpine rather than the full Node image.
#
# Only the Node binary and application runtime dependencies are copied from
# the build stage. npm, Yarn, Corepack, package caches, and other build-time
# tooling are intentionally excluded from the deployed container.
FROM alpine:${ALPINE_VERSION} AS runtime

# libstdc++ supports the copied Node binary.
# dumb-init gives the application proper container signal handling.
RUN apk add --no-cache \
      libstdc++ \
      dumb-init \
    && addgroup -g 1000 node \
    && adduser \
      -u 1000 \
      -G node \
      -s /bin/sh \
      -D node

WORKDIR /app

# Copy only the Node runtime executable from the build image.
COPY --from=dependencies \
  /usr/local/bin/node \
  /usr/local/bin/node

# Copy only production application dependencies.
COPY --from=dependencies \
  --chown=node:node \
  /build-stage/node_modules \
  ./node_modules

# Copy application source required at runtime.
COPY --chown=node:node \
  index.js \
  config.js \
  ./

# Run the application without root privileges.
USER node

EXPOSE 8080

# dumb-init receives container signals first and forwards them cleanly to Node.
ENTRYPOINT ["dumb-init", "--"]

CMD ["node", "index.js"]