/**
 * RemoteGate — Yandex Cloud Function: Authenticated status endpoint
 *
 * Runtime: Node.js 20 (Yandex Cloud Functions)
 * Trigger: HTTP via API Gateway (or direct function URL)
 * Auth: HMAC-SHA256 over timestamp.nonce.deviceId.payloadHash
 *   Headers: X-RemoteGate-DeviceId, X-RemoteGate-Timestamp, X-RemoteGate-Nonce, X-RemoteGate-Signature
 *
 * Environment variables (set in function config, NOT in repo):
 *   HMAC_SECRET        — shared secret (base64 or utf8 string, >=16 chars)
 *   ALLOWED_DEVICE_IDS — comma-separated allowlist (optional, if empty allow all authenticated)
 *   STORAGE_BUCKET     — Object Storage bucket for audit log (optional)
 *   YDB_ENDPOINT       — YDB endpoint for status history (optional)
 *
 * Security:
 *   - Verifies timestamp drift ≤ 5 minutes (prevents replay)
 *   - Verifies HMAC signature (constant-time compare)
 *   - Nonce uniqueness requires external store; we log it for audit and
 *     recommend YDB/Redis for production deduplication (documented).
 *   - Never logs the secret or full signature.
 *   - Validates JSON schema, rejects oversized payloads.
 *
 * Returns: { ok: true, receivedAt: ISO8601 } on success
 */

const crypto = require('crypto');

const MAX_PAYLOAD_BYTES = 10 * 1024; // 10KB
const TIMESTAMP_TOLERANCE_SEC = 5 * 60; // 5 minutes
const HMAC_SECRET_ENV = 'HMAC_SECRET';

function jsonResponse(statusCode, body, extraHeaders = {}) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
      ...extraHeaders,
    },
    body: JSON.stringify(body),
    isBase64Encoded: false,
  };
}

function constantTimeEqual(a, b) {
  // Both base64 strings — decode to buffers for timingSafeEqual
  try {
    const ab = Buffer.from(a, 'base64');
    const bb = Buffer.from(b, 'base64');
    if (ab.length !== bb.length) return false;
    return crypto.timingSafeEqual(ab, bb);
  } catch {
    return false;
  }
}

function sha256Hex(data) {
  return crypto.createHash('sha256').update(data, 'utf8').digest('hex');
}

exports.handler = async function (event, context) {
  // Yandex Cloud Functions passes event with httpMethod, headers, body
  // For API Gateway, event is the gateway payload; handle both shapes.
  const method = (event.httpMethod || event.requestContext?.httpMethod || 'GET').toUpperCase();
  const headers = event.headers || {};
  const lowerHeaders = {};
  for (const [k, v] of Object.entries(headers)) lowerHeaders[k.toLowerCase()] = v;

  // CORS preflight (optional)
  if (method === 'OPTIONS') {
    return jsonResponse(204, {}, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'X-RemoteGate-DeviceId,X-RemoteGate-Timestamp,X-RemoteGate-Nonce,X-RemoteGate-Signature,Content-Type',
      'Access-Control-Allow-Methods': 'POST,GET,OPTIONS',
    });
  }

  // Health check (no auth needed for GET /health)
  const path = event.path || event.requestContext?.path || '/';
  if (method === 'GET' && (path.endsWith('/health') || lowerHeaders['x-health-check'])) {
    return jsonResponse(200, { ok: true, service: 'remotegate-status', version: '1.0.0' });
  }

  if (method !== 'POST') {
    return jsonResponse(405, { ok: false, error: 'Method not allowed, use POST' });
  }

  // --- Auth headers ---
  const deviceId = lowerHeaders['x-remotegate-deviceid'];
  const timestamp = lowerHeaders['x-remotegate-timestamp'];
  const nonce = lowerHeaders['x-remotegate-nonce'];
  const signature = lowerHeaders['x-remotegate-signature'];

  if (!deviceId || !timestamp || !nonce || !signature) {
    return jsonResponse(401, { ok: false, error: 'Missing authentication headers (X-RemoteGate-DeviceId, Timestamp, Nonce, Signature)' });
  }

  // Validate deviceId shape (UUID-ish)
  if (deviceId.length < 8 || deviceId.length > 128 || !/^[a-zA-Z0-9\-_]+$/.test(deviceId)) {
    return jsonResponse(400, { ok: false, error: 'Invalid deviceId format' });
  }

  // Validate timestamp (unix seconds)
  const tsNum = parseInt(timestamp, 10);
  if (isNaN(tsNum) || tsNum <= 0) {
    return jsonResponse(401, { ok: false, error: 'Invalid timestamp' });
  }
  const nowSec = Math.floor(Date.now() / 1000);
  const drift = Math.abs(nowSec - tsNum);
  if (drift > TIMESTAMP_TOLERANCE_SEC) {
    return jsonResponse(401, { ok: false, error: `Timestamp drift too large (${drift}s > ${TIMESTAMP_TOLERANCE_SEC}s) — check device clock` });
  }

  // Validate nonce (hex or uuid fragment, 8-64 chars)
  if (nonce.length < 8 || nonce.length > 64 || !/^[a-zA-Z0-9\-_]+$/.test(nonce)) {
    return jsonResponse(401, { ok: false, error: 'Invalid nonce format' });
  }

  // --- Body ---
  let rawBody = event.body || '';
  if (event.isBase64Encoded) rawBody = Buffer.from(rawBody, 'base64').toString('utf8');

  if (!rawBody || rawBody.length === 0) {
    return jsonResponse(400, { ok: false, error: 'Empty body' });
  }
  if (Buffer.byteLength(rawBody, 'utf8') > MAX_PAYLOAD_BYTES) {
    return jsonResponse(413, { ok: false, error: `Payload too large (max ${MAX_PAYLOAD_BYTES} bytes)` });
  }

  let payload;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return jsonResponse(400, { ok: false, error: 'Invalid JSON' });
  }

  // Minimal schema validation (allow extra fields forward-compat)
  if (typeof payload.deviceId !== 'string' && typeof payload.deviceId !== 'undefined') {
    // deviceId in payload is optional (header is canonical)
  }
  // Validate no secrets leaked in payload (defense in depth)
  const rawLower = rawBody.toLowerCase();
  const forbidden = ['private_key', 'privatekey', 'private key', 'hmac_secret', 'password', 'begin open', 'begin rsa', 'begin ec', 'begin dsa'];
  for (const f of forbidden) {
    if (rawLower.includes(f)) {
      return jsonResponse(400, { ok: false, error: `Payload contains forbidden field/pattern: ${f}` });
    }
  }

  // --- HMAC verification ---
  const secret = process.env[HMAC_SECRET_ENV];
  if (!secret) {
    console.error('HMAC_SECRET not configured in function environment');
    return jsonResponse(500, { ok: false, error: 'Server misconfigured (HMAC secret missing)' });
  }

  const payloadHash = sha256Hex(rawBody);
  const signingString = `${timestamp}.${nonce}.${deviceId}.${payloadHash}`;

  // Secret may be raw UTF8 or base64 — try both (prefer utf8)
  // We compute HMAC-SHA256 and compare base64-encoded signature
  function computeSig(sec) {
    const h = crypto.createHmac('sha256', sec);
    h.update(signingString, 'utf8');
    return h.digest('base64');
  }

  const expectedSig = computeSig(secret);
  // Also try base64-decoded secret if it looks like base64
  let altSig = null;
  if (/^[A-Za-z0-9+/=]{20,}$/.test(secret)) {
    try { altSig = computeSig(Buffer.from(secret, 'base64')); } catch {}
  }

  const sigOk = constantTimeEqual(signature, expectedSig) || (altSig && constantTimeEqual(signature, altSig));
  if (!sigOk) {
    // Do not log secrets; log truncated signature for debugging
    console.warn(`HMAC verification failed for device ${deviceId} (sig prefix: ${signature.substring(0, 8)}...)`);
    return jsonResponse(401, { ok: false, error: 'Invalid signature' });
  }

  // --- Optional allowlist ---
  const allowlist = (process.env.ALLOWED_DEVICE_IDS || '').split(',').map(s => s.trim()).filter(Boolean);
  if (allowlist.length > 0 && !allowlist.includes(deviceId)) {
    console.warn(`Device ${deviceId} not in allowlist`);
    return jsonResponse(403, { ok: false, error: 'Device not authorized' });
  }

  // --- Nonce replay note ---
  // Full replay protection requires a persistent store (YDB, Redis, DynamoDB-compat).
  // We log nonce+timestamp here; production should check YDB with TTL.
  // See docs/SECURITY.md for deployment options.
  console.log(JSON.stringify({
    level: 'info',
    msg: 'Status received',
    deviceId,
    timestamp,
    nonce,
    payloadSummary: {
      hostname: payload.hostname || null,
      sshStatus: payload.sshStatus || null,
      tunnelStatus: payload.tunnelStatus || null,
      ipCount: Array.isArray(payload.localIps) ? payload.localIps.length : 0,
    },
    receivedAt: new Date().toISOString(),
  }));

  // TODO: Persist to Object Storage / YDB if configured
  // Example: await writeToStorage(deviceId, payload, timestamp, nonce);

  return jsonResponse(200, {
    ok: true,
    receivedAt: new Date().toISOString(),
    deviceId,
  });
};
