/**
 * RemoteGate Cloud Function tests (Node.js)
 * Run: npm install --prefix cloud/functions
 *      node --test tests/cloud/function.test.js
 *
 * Unit tests — no Yandex account needed.
 * Mock the Yandex context/event shapes.
 */
const crypto = require('crypto');
const { describe, it, before } = require('node:test');
const assert = require('node:assert');

// We load the handler after setting env so we can test HMAC paths
const HMAC_SECRET = 'test-secret-1234567890-abcdefghij'; // >=16 chars

function sha256Hex(data) {
  return crypto.createHash('sha256').update(data, 'utf8').digest('hex');
}

function signRequest({ timestamp, nonce, deviceId, payloadJson, secret }) {
  const payloadHash = sha256Hex(payloadJson);
  const signingString = `${timestamp}.${nonce}.${deviceId}.${payloadHash}`;
  const h = crypto.createHmac('sha256', secret);
  h.update(signingString, 'utf8');
  return h.digest('base64');
}

describe('RemoteGate Cloud Function — HMAC verification', () => {
  let handler;

  before(() => {
    process.env.HMAC_SECRET = HMAC_SECRET;
    // Fresh require (Node cache)
    delete require.cache[require.resolve('../../cloud/functions/index.js')];
    handler = require('../../cloud/functions/index.js').handler;
  });

  function makeEvent({ payload, deviceId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890', timestampOffset = 0 }) {
    const payloadJson = JSON.stringify(payload);
    const timestamp = (Math.floor(Date.now() / 1000) + timestampOffset).toString();
    const nonce = 'abc123def456ghi7';
    const signature = signRequest({ timestamp, nonce, deviceId, payloadJson, secret: HMAC_SECRET });

    return {
      httpMethod: 'POST',
      path: '/status',
      headers: {
        'X-RemoteGate-DeviceId': deviceId,
        'X-RemoteGate-Timestamp': timestamp,
        'X-RemoteGate-Nonce': nonce,
        'X-RemoteGate-Signature': signature,
      },
      body: payloadJson,
    };
  }

  it('accepts valid HMAC-signed request', async () => {
    const event = makeEvent({ payload: { deviceId: 'test', sshStatus: 'Running', timestamp: new Date().toISOString() } });
    const res = await handler(event, {});
    assert.equal(res.statusCode, 200);
    assert.equal(JSON.parse(res.body).ok, true);
  });

  it('rejects missing auth headers (401)', async () => {
    const event = { httpMethod: 'POST', headers: {}, body: '{}', path: '/status' };
    const res = await handler(event, {});
    assert.equal(res.statusCode, 401);
  });

  it('rejects invalid signature (401)', async () => {
    const event = makeEvent({ payload: { test: 1 } });
    event.headers['X-RemoteGate-Signature'] = 'invalidbase64==';
    const res = await handler(event, {});
    assert.equal(res.statusCode, 401);
  });

  it('rejects expired timestamp (>5min drift)', async () => {
    const event = makeEvent({ payload: { test: 1 }, timestampOffset: -600 }); // 10 min ago
    const res = await handler(event, {});
    assert.equal(res.statusCode, 401);
    assert.match(JSON.parse(res.body).error, /drift/);
  });

  it('rejects oversized payload (413)', async () => {
    const large = { data: 'x'.repeat(11 * 1024) };
    const event = makeEvent({ payload: large });
    const res = await handler(event, {});
    // Check: our function checks rawBody byte length 10KB
    // Large string forces 413
    assert.equal(res.statusCode, 413);
  });

  it('rejects forbidden patterns (PRIVATE KEY in payload)', async () => {
    const event = makeEvent({ payload: { leaked: '-----BEGIN RSA PRIVATE KEY-----' } });
    const res = await handler(event, {});
    assert.equal(res.statusCode, 400);
  });

  it('health check GET /health returns 200 without auth', async () => {
    const event = { httpMethod: 'GET', path: '/health', headers: {}, body: '' };
    const res = await handler(event, {});
    assert.equal(res.statusCode, 200);
    assert.equal(JSON.parse(res.body).ok, true);
  });

  it('rejects empty body (400)', async () => {
    const event = {
      httpMethod: 'POST', path: '/status',
      headers: { 'X-RemoteGate-DeviceId': 'dev1', 'X-RemoteGate-Timestamp': Math.floor(Date.now() / 1000).toString(), 'X-RemoteGate-Nonce': 'abc12345', 'X-RemoteGate-Signature': 'abc=' },
      body: '',
    };
    const res = await handler(event, {});
    assert.equal(res.statusCode, 400);
  });

  it('rejects invalid JSON (400)', async () => {
    const payloadJson = 'not json {';
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const nonce = 'abc12345';
    const deviceId = 'dev1';
    const sig = signRequest({ timestamp, nonce, deviceId, payloadJson, secret: HMAC_SECRET });
    const event = {
      httpMethod: 'POST', path: '/status',
      headers: { 'X-RemoteGate-DeviceId': deviceId, 'X-RemoteGate-Timestamp': timestamp, 'X-RemoteGate-Nonce': nonce, 'X-RemoteGate-Signature': sig },
      body: 'not json {',
    };
    const res = await handler(event, {});
    assert.equal(res.statusCode, 400);
  });

  it('returns 500 if HMAC_SECRET not configured', async () => {
    const saved = process.env.HMAC_SECRET;
    delete process.env.HMAC_SECRET;
    delete require.cache[require.resolve('../../cloud/functions/index.js')];
    const handlerNoSecret = require('../../cloud/functions/index.js').handler;
    const event = makeEvent({ payload: { test: 1 } });
    const res = await handlerNoSecret(event, {});
    assert.equal(res.statusCode, 500);
    process.env.HMAC_SECRET = saved;
    delete require.cache[require.resolve('../../cloud/functions/index.js')];
  });
});
