# node:18 to match the frontend's build toolchain (.nvmrc) and avoid
# running two different major Node versions across the two services.
# -alpine keeps the pushed image small (matters for ECR storage + Fargate
# pull time, and backend has zero native/binary deps, so alpine is safe).
FROM node:18-alpine

WORKDIR /app

# Copy manifest files first so `npm ci` is only re-run when dependencies
# actually change, not on every source edit (Docker layer caching).
COPY package*.json ./
RUN npm ci --omit=dev

COPY index.js config.js ./

EXPOSE 8080

# Run as the non-root `node` user baked into the official image rather
# than the default root - least privilege applies inside the container
# too, not just at the IAM layer. Costs nothing here since the app never
# needs to write to the filesystem at runtime.
USER node

CMD ["node", "index.js"]
