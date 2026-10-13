# The SpaceKit website. Coolify builds this with "Base Directory" set to /web.
FROM node:22-alpine

ENV NODE_ENV=production \
    PORT=3000 \
    DOWNLOADS_DIR=/data/downloads

WORKDIR /app
COPY package.json server.mjs ./
COPY public ./public

# The installer customers download lives on a persistent volume mounted at /data, not in the image.
RUN mkdir -p /data/downloads && chown -R node:node /data
USER node

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD wget -qO- http://127.0.0.1:3000/healthz >/dev/null || exit 1

CMD ["node", "server.mjs"]
