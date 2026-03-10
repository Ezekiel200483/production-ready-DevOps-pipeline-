# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 – Dependencies
#   Install only production deps in a clean layer so the final image stays slim.
# ─────────────────────────────────────────────────────────────────────────────
FROM node:20-alpine AS deps

WORKDIR /app

# Copy manifests first for better layer caching
COPY package*.json ./

# Install ALL deps (needed for build/test stages)
RUN npm ci --ignore-scripts

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 – Test  (optional; skipped in prod builds via --target runtime)
# ─────────────────────────────────────────────────────────────────────────────
FROM deps AS test

COPY . .
RUN npm run test:ci

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 – Production deps only
# ─────────────────────────────────────────────────────────────────────────────
FROM node:20-alpine AS prod-deps

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

# ─────────────────────────────────────────────────────────────────────────────
# Stage 4 – Runtime  (final, minimal image)
# ─────────────────────────────────────────────────────────────────────────────
FROM node:20-alpine AS runtime

# Security hardening
RUN apk add --no-cache dumb-init \
 && addgroup -g 1001 -S nodejs \
 && adduser  -u 1001 -S nodeapp -G nodejs

WORKDIR /app

# Copy production node_modules from prod-deps stage
COPY --from=prod-deps --chown=nodeapp:nodejs /app/node_modules ./node_modules

# Copy application source
COPY --chown=nodeapp:nodejs src/ ./src/

# Copy package.json for version metadata
COPY --chown=nodeapp:nodejs package.json ./

# Drop to non-root user
USER nodeapp

# Expose app port
EXPOSE 3000

# Health check (Docker-native, also used by Compose/ECS)
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

# Use dumb-init to handle PID 1 / signal forwarding properly
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/server.js"]
