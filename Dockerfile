# ============================================
# ML Lifecycle Explorer - Production Dockerfile
# Multi-stage build for optimal image size
# ============================================

# Stage 1: Build
FROM node:20-alpine AS builder

WORKDIR /app

# Install dependencies first (cache layer)
COPY package.json package-lock.json* bun.lockb* ./
RUN npm ci --silent

# Copy source code
COPY . .

# Build the application
RUN npm run build

# Stage 2: Production (nginx)
FROM nginx:1.31-alpine AS production

# Remove default nginx config
RUN rm -rf /etc/nginx/conf.d/*

# Create nginx temp directories writable by non-root user (uid 101 = nginx)
RUN mkdir -p /var/cache/nginx /var/run /tmp/nginx && \
    chown -R 101:101 /var/cache/nginx /var/run /tmp/nginx /usr/share/nginx/html

# Copy custom nginx config
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy built assets from builder stage
COPY --from=builder --chown=101:101 /app/dist /usr/share/nginx/html

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:80/ || exit 1

# Run as non-root
USER 101

# Expose port 80
EXPOSE 80

# Start nginx
CMD ["nginx", "-g", "daemon off;"]
