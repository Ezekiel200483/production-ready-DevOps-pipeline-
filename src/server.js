'use strict';

const app = require('./app');

const PORT = parseInt(process.env.PORT || '3000', 10);

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(JSON.stringify({
    level: 'info',
    message: `Server listening`,
    port: PORT,
    pid: process.pid,
    timestamp: new Date().toISOString(),
  }));
});

// Graceful shutdown
const shutdown = (signal) => {
  console.log(JSON.stringify({ level: 'info', message: `${signal} received – shutting down` }));
  server.close(() => {
    console.log(JSON.stringify({ level: 'info', message: 'HTTP server closed' }));
    process.exit(0);
  });

  // Force-exit after 10 s if graceful close stalls
  setTimeout(() => process.exit(1), 10_000).unref();
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));
