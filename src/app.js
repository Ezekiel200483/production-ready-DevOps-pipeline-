'use strict';

const express = require('express');
const { createClient } = require('redis');
const winston = require('winston');

// ── Logger ────────────────────────────────────────────────────────────────────
const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    winston.format.json()
  ),
  transports: [new winston.transports.Console()],
});

// ── Redis client (optional – gracefully degrades if not configured) ───────────
let redis = null;

if (process.env.REDIS_URL) {
  redis = createClient({ url: process.env.REDIS_URL });

  redis.on('error', (err) => logger.error('Redis client error', { err }));
  redis.on('connect', ()  => logger.info('Redis connected'));
  redis.on('reconnecting', () => logger.warn('Redis reconnecting'));

  // Connect async – app still starts if Redis is temporarily unavailable
  redis.connect().catch((err) => logger.error('Redis initial connect failed', { err }));
}

// ── App ───────────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());

// Request logging middleware
app.use((req, _res, next) => {
  logger.info('Incoming request', { method: req.method, path: req.path, ip: req.ip });
  next();
});

// GET /health  – liveness probe (always fast, no external deps)
app.get('/health', (_req, res) => {
  res.status(200).json({ status: 'ok', timestamp: new Date().toISOString() });
});

// GET /status  – readiness probe (checks Redis when configured)
app.get('/status', async (_req, res) => {
  const info = {
    status:    'ok',
    uptime:    process.uptime(),
    timestamp: new Date().toISOString(),
    version:   process.env.APP_VERSION || '1.0.0',
    redis:     'not_configured',
  };

  if (redis) {
    try {
      await redis.ping();
      info.redis = 'connected';
    } catch (err) {
      logger.error('Redis health check failed', { err });
      info.redis  = 'unreachable';
      info.status = 'degraded';
    }
  }

  res.status(info.status === 'ok' ? 200 : 503).json(info);
});

// POST /process – process payload and store result in Redis
app.post('/process', async (req, res) => {
  const { data } = req.body;

  if (data === undefined || data === null) {
    return res.status(400).json({ error: 'Missing required field: data' });
  }

  logger.info('Processing request', { dataType: typeof data });

  const processId  = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}`;
  const processedAt = new Date().toISOString();

  const result = {
    processed:   true,
    processId,
    input:       data,
    processedAt,
    persisted:   false,
  };

  if (redis?.isReady) {
    try {
      const entry = JSON.stringify({ processId, input: data, processedAt });

      await Promise.all([
        // Store individual result with 24 h TTL
        redis.setEx(`process:${processId}`, 86_400, entry),
        // Push to a capped list of recent jobs (newest first, keep last 100)
        redis.lPush('process:log', entry),
        redis.lTrim('process:log', 0, 99),
        // Increment a global counter
        redis.incr('process:total'),
      ]);

      result.persisted = true;
    } catch (err) {
      logger.warn('Could not persist to Redis', { err });
    }
  }

  return res.status(200).json(result);
});

// 404 handler
app.use((_req, res) => res.status(404).json({ error: 'Not found' }));

// Global error handler
app.use((err, _req, res, _next) => {
  logger.error('Unhandled error', { err });
  res.status(500).json({ error: 'Internal server error' });
});

// Graceful Redis disconnect on shutdown
app.close = async () => {
  if (redis) await redis.quit();
};

module.exports = app;
