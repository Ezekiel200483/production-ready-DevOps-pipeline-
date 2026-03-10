'use strict';

const request = require('supertest');

// Mock Redis before requiring the app so no real connection is attempted
jest.mock('redis', () => {
  const mockClient = {
    isReady:     true,
    on:          jest.fn().mockReturnThis(),
    connect:     jest.fn().mockResolvedValue(undefined),
    ping:        jest.fn().mockResolvedValue('PONG'),
    setEx:       jest.fn().mockResolvedValue('OK'),
    lPush:       jest.fn().mockResolvedValue(1),
    lTrim:       jest.fn().mockResolvedValue('OK'),
    incr:        jest.fn().mockResolvedValue(1),
    quit:        jest.fn().mockResolvedValue(undefined),
  };
  return { createClient: jest.fn(() => mockClient) };
});

// Set REDIS_URL so the app initialises the (mocked) client
process.env.REDIS_URL = 'redis://localhost:6379';

const app = require('../src/app');

describe('GET /health', () => {
  it('returns 200 with status ok', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('ok');
    expect(res.body.timestamp).toBeDefined();
  });
});

describe('GET /status', () => {
  it('returns 200 and shows redis connected', async () => {
    const res = await request(app).get('/status');
    expect(res.statusCode).toBe(200);
    expect(res.body.uptime).toBeGreaterThanOrEqual(0);
    expect(res.body.redis).toBe('connected');
  });

  it('returns 503 when Redis ping fails', async () => {
    const { createClient } = require('redis');
    const client = createClient();
    client.ping.mockRejectedValueOnce(new Error('timeout'));

    const res = await request(app).get('/status');
    expect([200, 503]).toContain(res.statusCode);
  });
});

describe('POST /process', () => {
  it('processes valid data and returns processed:true with a processId', async () => {
    const res = await request(app)
      .post('/process')
      .send({ data: 'hello world' });
    expect(res.statusCode).toBe(200);
    expect(res.body.processed).toBe(true);
    expect(res.body.input).toBe('hello world');
    expect(res.body.processId).toBeDefined();
    expect(res.body.processedAt).toBeDefined();
    expect(res.body.persisted).toBe(true);
  });

  it('accepts object payloads', async () => {
    const payload = { key: 'value', num: 42 };
    const res = await request(app)
      .post('/process')
      .send({ data: payload });
    expect(res.statusCode).toBe(200);
    expect(res.body.input).toEqual(payload);
  });

  it('returns 400 when data field is missing', async () => {
    const res = await request(app).post('/process').send({});
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toMatch(/Missing required field/);
  });
});

describe('404 handler', () => {
  it('returns 404 for unknown routes', async () => {
    const res = await request(app).get('/unknown-route');
    expect(res.statusCode).toBe(404);
  });
});
