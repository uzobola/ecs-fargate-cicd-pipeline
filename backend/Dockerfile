
FROM node:24-alpine3.24

WORKDIR /app

ENV NODE_ENV=production

COPY package*.json ./

RUN npm ci --omit=dev \
    && npm cache clean --force

COPY --chown=node:node index.js config.js ./

USER node

EXPOSE 8080

CMD ["node", "index.js"]

