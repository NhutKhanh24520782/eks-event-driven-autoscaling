# ── Stage 1: Dependencies ──
FROM node:18-alpine AS deps
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev

# ── Stage 2: Runtime ──
FROM node:18-alpine AS runner
WORKDIR /app

# Install dumb-init for reliable PID 1 signal forwarding (SIGTERM / SIGINT)
# Critical for K8s graceful shutdown: enables Worker to complete in-flight SQS jobs
RUN apk add --no-cache dumb-init

ENV NODE_ENV=production
ENV HEALTH_PORT=8081

# Run as non-root user
USER node

# Copy dependencies and application source
COPY --chown=node:node --from=deps /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src/ ./src/

# Expose port for Kubernetes liveness/readiness probe
EXPOSE 8081

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/main.js"]
