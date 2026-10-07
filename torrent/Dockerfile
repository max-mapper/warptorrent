FROM node:24-alpine
WORKDIR /app
COPY package.json ./
COPY no-webrtc ./no-webrtc
# webrtc-polyfill is overridden with a stub (no-webrtc/) and install scripts are skipped,
# so no native WebRTC stack exists in the image at all.
RUN npm install --omit=dev --ignore-scripts && npm cache clean --force
COPY run.mjs ./
USER node
ENTRYPOINT ["node", "run.mjs"]
