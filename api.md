# API Reference

Base URL: `http://<gateway>:8000` (local stack `127.0.0.1:8100`; Kubernetes NodePort `30007`). Interactive OpenAPI docs: `/docs`.
All bodies are JSON. Every response carries `X-Request-ID` (also in logs) and `X-Process-Time`.

## Conventions

- **Versioning:** none yet; the API is unversioned.
- **Overload:** if no database connection frees up within `DB_POOL_TIMEOUT` (5 s) the gateway answers `503 {"detail":"Service busy, retry shortly"}` with `Retry-After: 1`. Clients should back off and retry (with the same `Idempotency-Key` for `POST /events`).
- **IDs:** events use opaque `evt_…` ids; webhooks and deliveries use integers scoped to your account (another account's id answers `404`).

## Authentication

`Authorization: Bearer <JWT>` on everything except `/register`, `/login`, `/`, `/healthz`, `/readyz`, `/metrics`.
Tokens are HS256, `sub` = user id, TTL `JWT_TTL_SECONDS` (default 3600). There is no refresh token and no revocation: a token is valid until it expires.
Missing/invalid/expired → `401` with `WWW-Authenticate: Bearer`.

## Rate limits

| Scope | Key | Default | Over limit |
|---|---|---|---|
| Authenticated routes | user id | burst 100, refill 50/s | `429` + `Retry-After` |
| `/register`, `/login` | client IP | burst 20, refill 2/s | `429` + `Retry-After` |

Both are Redis token buckets (atomic Lua); they fail **open** if Redis is unreachable.

## Auth

### `POST /register` → `201`
```json
{"email": "a@example.com", "password": "min-8-chars"}   →   {"id": 1, "email": "a@example.com"}
```
`409` if the email exists, `422` for a bad email or password < 8 chars.

### `POST /login` → `200`
```json
{"email": "a@example.com", "password": "…"}   →   {"access_token": "…", "token_type": "bearer", "expires_in": 3600}
```
`401` for unknown email or wrong password (identical response and timing).

## Webhooks

| Method & path | Notes |
|---|---|
| `POST /webhooks` → `201` | body `{url, event_type}`; response includes `secret` (`whsec_…`). `422` if the URL fails the SSRF guard |
| `GET /webhooks` | your webhooks (no secrets); cached in Redis 60 s, invalidated on change |
| `GET /webhooks/{id}` | includes `secret` |
| `PATCH /webhooks/{id}` | partial `{url?, event_type?}`; SSRF-checked |
| `DELETE /webhooks/{id}` → `204` | soft delete; pending/retrying deliveries become `cancelled` |

`event_type` is matched exactly against the event's `event_type` at **ingest time**.

## Events

### `POST /events` → `202`
Headers: `Idempotency-Key: <1–255 chars>` (optional, recommended).
```json
{"event_type": "order.created", "payload": {"id": 7}}
→ 202 {"event_id": "evt_6f1…", "status": "pending", "deliveries": 2}
```
- Same key + same body → `200`, header `Idempotent-Replayed: true`, original `event_id`, no new work.
- Same key + different body → `422`.
- `413` payload > 256 KiB (`MAX_PAYLOAD_BYTES`), `400` bad key length, `422` validation.
- `deliveries: 0`, `status: "no_subscribers"` when no webhook matched (the event is still stored).

### `GET /events?limit=50&before=<event_id>` 
Newest first, `limit` 1–100, `before` is an event-id cursor. Payload omitted from list items.

### `GET /events/{event_id}` 
Full event including payload. `404` if it is not yours.

## Deliveries and replay

### `GET /deliveries?status=&limit=&before_id=`
Your deliveries across events, newest first; `status` ∈ `pending|in_flight|success|retrying|dead_letter|cancelled`.

### `GET /deliveries/{event_id}`
```json
[{"id": 12, "event_id": "evt_…", "webhook_id": 3, "status": "success", "retries": 2,
  "response_code": 200, "latency_ms": 41, "attempted_at": "…", "next_retry_at": null,
  "attempts": [{"attempt": 1, "status": "failed",  "response_code": 500, "latency_ms": 12, "error_message": "HTTP 500", "attempted_at": "…"},
               {"attempt": 2, "status": "success", "response_code": 200, "latency_ms": 41, "attempted_at": "…"}]}]
```

### `POST /retry/{event_id}`  (alias `POST /events/{event_id}/replay`) → `202`
Re-queues every `dead_letter`/`failed` delivery of the event (resets attempts, writes outbox rows in one
transaction). Successful deliveries are never re-sent. → `{"event_id": "evt_…", "replayed_deliveries": 1}`
(`0` if there was nothing to replay).

## Operational endpoints (unauthenticated)

| Path | Purpose |
|---|---|
| `GET /healthz` | Liveness: process is serving. No dependency checks |
| `GET /readyz` | Readiness: `SELECT 1` against Postgres → `200`/`503`. Redis is not required |
| `GET /metrics` | Prometheus exposition |

Worker (port 8001): `/metrics`, `/healthz` (all loops heartbeating), `/readyz` (Postgres + Redis, false while shutting down).

## What a receiver gets

```
POST <your url>
Content-Type: application/json
User-Agent: Ferrum-Webhooks/1.0
webhook-id: evt_6f1…                 # stable per event: dedupe on this
webhook-timestamp: 1791457514        # unix seconds, refreshed every attempt
webhook-signature: v1,<base64 hmac>  # HMAC-SHA256(secret, "<id>.<timestamp>.<raw body>")

{"id":"evt_6f1…","type":"order.created","timestamp":"2026-10-08T…+00:00","data":{"id":7}}
```
Respond `2xx` within 5 s (connect 3 s) to acknowledge. Anything else (including 3xx — redirects are **not** followed — timeouts, DNS
and TLS errors) is a failure and is retried at ≈5 s, 10 s, 20 s, 40 s (±20%) and then dead-lettered after the 5th attempt.

Verify (Python, matches `worker/signing.py::verify`):
```python
import base64, hashlib, hmac, time
def verify(secret, headers, raw_body, tolerance=300):
    key = base64.b64decode(secret.removeprefix("whsec_"))
    ts = int(headers["webhook-timestamp"])
    if abs(time.time() - ts) > tolerance: return False            # replay protection
    signed = f'{headers["webhook-id"]}.{ts}.'.encode() + raw_body   # the RAW bytes, not re-serialised JSON
    expected = "v1," + base64.b64encode(hmac.new(key, signed, hashlib.sha256).digest()).decode()
    return any(hmac.compare_digest(expected, s) for s in headers["webhook-signature"].split(" "))
```

## Error shape
FastAPI default: `{"detail": "…"}` (or a list of field errors for `422`).
