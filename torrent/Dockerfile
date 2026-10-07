FROM node:24-alpine
WORKDIR /app
COPY package.json ./
COPY no-webrtc ./no-webrtc
COPY no-utp ./no-utp
# webrtc-polyfill and utp-native are overridden with stubs (no-webrtc/, no-utp/) and install scripts are skipped,
# so no native WebRTC or uTP code exists in the image at all.
RUN npm install --omit=dev --ignore-scripts && npm cache clean --force
COPY run.mjs ./
USER node
ENTRYPOINT ["node", "run.mjs"]
