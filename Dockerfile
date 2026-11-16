# ── Stage 1: build the Flutter web admin dashboard ──────────────────────────
FROM ghcr.io/cirruslabs/flutter:stable AS flutter_build
WORKDIR /app
COPY packages/ ./packages/
COPY admin_dashboard/ ./admin_dashboard/
WORKDIR /app/admin_dashboard
RUN flutter pub get
RUN flutter build web

# ── Stage 2: run the Node server, serving the built web app ────────────────
FROM node:20-slim
WORKDIR /app

# Only copy what the server actually needs at runtime.
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

COPY server.js ./
COPY --from=flutter_build /app/admin_dashboard/build/web ./admin_dashboard/build/web

ENV HOST=0.0.0.0
ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
