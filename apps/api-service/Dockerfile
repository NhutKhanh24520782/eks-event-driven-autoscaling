# ── Stage 1: Dependencies ──
FROM node:18-alpine AS deps
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev

# ── Stage 2: Runtime ──
FROM node:18-alpine AS runner
WORKDIR /app

# Install dumb-init for reliable PID 1 signal forwarding (SIGTERM / SIGINT)
RUN apk add --no-cache dumb-init

ENV NODE_ENV=production
ENV PORT=8080

# Run as non-root user for security best practices
USER node

# Copy dependencies and application source
COPY --chown=node:node --from=deps /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src/ ./src/

EXPOSE 8080

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/main.js"]
