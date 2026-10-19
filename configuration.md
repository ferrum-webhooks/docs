# Configuration reference

Every setting is an environment variable. The tables list **all** variables read by the code (extracted from the
source, not written from memory). Defaults are the values in the code; the Kubernetes ConfigMap and the Helm chart
override a few of them (noted).

## Gateway (`ferrum-webhook-gateway`)

### Required

| Variable | Default | Notes |
|---|---|---|
| `JWT_SECRET` | none | **The process refuses to start without it.** At least 32 characters. Signs all access tokens (HS256) |
| `DB_HOST` `DB_PORT` `DB_NAME` `DB_USER` `DB_PASSWORD` | `localhost` `5432` … | PostgreSQL. In Kubernetes `DB_PASSWORD` comes from a Secret, never from the ConfigMap |
| `REDIS_HOST` `REDIS_PORT` | `localhost` `6379` | Cache, rate-limit buckets. Not required for ingest (it fails open) |

### Database pool

| Variable | Default | Notes |
|---|---|---|
| `DB_POOL_SIZE` | `10` | Persistent connections per process |
| `DB_MAX_OVERFLOW` | `10` | Extra connections under burst |
| `DB_POOL_TIMEOUT` | `5` | Seconds to wait for a free connection before answering `503` + `Retry-After: 1` (SQLAlchemy's default of 30 s turns overload into a hang) |

Total connections to Postgres = `(pool + overflow) × processes × replicas`. Keep it below `max_connections`.

### Authentication and passwords

| Variable | Default | Notes |
|---|---|---|
| `JWT_TTL_SECONDS` | `3600` | Token lifetime |
| `ARGON2_MEMORY_COST_KIB` | `19456` | OWASP minimum (19 MiB). passlib's own default is 65536 and exhausts small pods under concurrent logins, see [the Argon2 write-up](engineering/04-argon2-memory.md) |
| `ARGON2_TIME_COST` | `2` | Iterations |
| `HASH_CONCURRENCY` | `4` | Maximum simultaneous password hashes per process; bounds memory at `HASH_CONCURRENCY × 19 MiB` |

### Limits

| Variable | Default | Notes |
|---|---|---|
| `RATE_LIMIT_ENABLED` | `true` | Per-user token bucket on authenticated routes |
| `RATE_LIMIT_CAPACITY` | `100` | Burst size |
| `RATE_LIMIT_REFILL_PER_SEC` | `50` | Sustained rate per user |
| `AUTH_RATE_LIMIT_CAPACITY` | `20` | Per client IP, `/register` and `/login` |
| `AUTH_RATE_LIMIT_REFILL_PER_SEC` | `2` | |
| `MAX_PAYLOAD_BYTES` | `262144` | Event body cap → `413` |

### Webhook target safety (also read by the worker)

| Variable | Default | Notes |
|---|---|---|
| `ALLOW_PRIVATE_WEBHOOK_TARGETS` | `false` | `true` **disables the SSRF guard**: local testing only |
| `ALLOW_INSECURE_WEBHOOKS` | `true` | `false` accepts `https://` targets only |

### Observability

| Variable | Default | Notes |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | e.g. `http://jaeger:4318`. Unset: spans exist (trace ids in logs, propagation works) but nothing is exported |
| `OTEL_TRACES_SAMPLER_RATIO` | `1.0` (Kubernetes/Helm: `0.1`) | Parent-based head sampling |

### Test-only

| Variable | Notes |
|---|---|
| `TESTING=true` | In-memory SQLite, no OTLP export, test JWT secret fallback. **Never set in production** (the migration Job sets it to `false` explicitly) |
| `TEST_DATABASE_URL` | With `TESTING=true`, run the suite against a real Postgres. The database name must contain `test`; its tables are dropped and recreated |

## Worker (`ferrum-webhook-worker`)

Shares `DB_*`, `REDIS_*`, `ALLOW_*`, `OTEL_*`, `TESTING`, `TEST_DATABASE_URL` with the gateway. Additionally:

### Delivery

| Variable | Default | Notes |
|---|---|---|
| `MAX_ATTEMPTS` | `5` | Attempts before a delivery is dead-lettered |
| `RETRY_BASE_SECONDS` | `5` | Backoff after failure *n* is `base × 2^(n-1)`: 5, 10, 20, 40 s |
| `RETRY_MAX_SECONDS` | `3600` | Backoff cap |
| `RETRY_JITTER` | `0.2` | ±20% to avoid synchronized retries |
| `HTTP_CONNECT_TIMEOUT` / `HTTP_READ_TIMEOUT` | `3` / `5` | Seconds, per attempt. Redirects are never followed |
| `WORKER_CONCURRENCY` | `8` | Simultaneous deliveries per worker process |
| `DB_POOL_SIZE` | `10` | Worker connection pool (+10 overflow) |

### Crash recovery (see [delivery pipeline](engineering/02-delivery-pipeline.md))

| Variable | Default | Notes |
|---|---|---|
| `LEASE_SECONDS` | `60` | An `in_flight` delivery whose lease expired may be taken over |
| `RECLAIM_IDLE_MS` | `90000` | Stream messages unacknowledged this long are reclaimed (`XAUTOCLAIM`). **Must exceed `LEASE_SECONDS × 1000`** |
| `RECLAIM_INTERVAL_SECONDS` | `15` | How often each worker looks for stale messages |
| `MAX_MESSAGE_DELIVERIES` | `10` | A message redelivered more often than this is moved to the DLQ stream as poison |
| `STALE_PENDING_SECONDS` | `900` | A `pending` delivery whose outbox row was published this long ago is re-enqueued (repairs Redis data loss) |

### Streams and loops

| Variable | Default | Notes |
|---|---|---|
| `STREAM_NAME` / `STREAM_GROUP` / `DLQ_STREAM_NAME` | `deliveries:stream` / `delivery-workers` / `deliveries:dlq` | Use different names to share one Redis safely |
| `RELAY_INTERVAL_SECONDS` / `RELAY_BATCH` | `0.2` / `200` | Outbox → stream polling |
| `SCHEDULER_INTERVAL_SECONDS` | `1` | Due-retry sweep |
| `OUTBOX_RETENTION_SECONDS` | `86400` | Published outbox rows are purged after this |
| `HEALTH_PORT` | `8001` | `/metrics`, `/healthz`, `/readyz` |
| `HEALTH_STALE_SECONDS` | `60` | `/healthz` fails if any loop has not beaten for this long |

## Where values are set

| Environment | Source |
|---|---|
| Local stack | `infra/bench/stack.sh` (exports sensible values; override by exporting before `up`) |
| Kubernetes (manifests) | `infra/k8s/config/ferrum-config.yaml` + Secrets `ferrum-secret`, `postgres-secret` |
| Kubernetes (Helm) | `infra/charts/ferrum/values.yaml` |
